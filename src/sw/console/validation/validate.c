/**
 * @file validate.c
 * @brief Herramienta de Validación del DSA Downscaler
 * 
 * Valida salida de FPGA contra modelo de referencia en C usando
 * interpolación bilineal bit-accurate con punto fijo Q8.8.
 * 
 * Uso:
 *   validate <input.pgm> <fpga_output.pgm> [-s scale] [-m mode] [-l lanes]
 *   validate --generate <input.pgm> <reference.pgm> [-s scale] [-m mode] [-l lanes]
 *   validate --batch <test_dir> <output_dir> [-s scale]
 * 
 * Opciones:
 *   -s, --scale <float>    Factor de escala (0.5-1.0), default: 0.5
 *   -m, --mode <mode>      Modo: sequential o simd, default: sequential
 *   -l, --lanes <n>        Lanes SIMD (2,4,8), default: 8
 *   -v, --verbose          Salida verbose
 *   -r, --reference <file> Guardar imagen de referencia
 *   -d, --diff <file>      Guardar imagen de diferencias
 *   --generate             Generar solo imagen de referencia
 *   --batch                Modo validación batch
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

#include "bilinear_reference.h"

/*===========================================================================
 * Configuración y Parámetros
 *===========================================================================*/

typedef struct {
    const char *input_file;
    const char *output_file;
    const char *reference_file;
    const char *diff_file;
    float scale;
    int mode;           /* 0 = sequential, 1 = simd */
    int simd_lanes;
    int verbose;
    int generate_only;  /* solo generar referencia */
    int batch_mode;
    const char *batch_dir;
} config_t;

/*===========================================================================
 * Funciones Auxiliares
 *===========================================================================*/

static void print_usage(const char *prog) {
    printf("DSA Downscaler Validation Tool\n");
    printf("Usage:\n");
    printf("  %s <input.pgm> <fpga_output.pgm> [options]\n", prog);
    printf("  %s --generate <input.pgm> <reference.pgm> [options]\n", prog);
    printf("\nOptions:\n");
    printf("  -s, --scale <float>    Scale factor (0.5-1.0), default: 0.5\n");
    printf("  -m, --mode <mode>      Mode: sequential or simd, default: sequential\n");
    printf("  -l, --lanes <n>        SIMD lanes (2,4,8), default: 8\n");
    printf("  -v, --verbose          Verbose output\n");
    printf("  -r, --reference <file> Save reference image to file\n");
    printf("  -d, --diff <file>      Save difference image to file\n");
    printf("  --generate             Generate reference image only\n");
    printf("\nExamples:\n");
    printf("  %s input.pgm fpga_out.pgm -s 0.5 -m sequential\n", prog);
    printf("  %s --generate input.pgm ref.pgm -s 0.5 -m simd -l 8\n", prog);
}

/*===========================================================================
 * Función de Validación Principal
 * 
 * Carga input, genera referencia con modelo C, compara con FPGA output,
 * calcula estadísticas de diferencias, y opcionalmente guarda imágenes.
 *===========================================================================*/

static int validate_images(config_t *cfg) {
    /* Cargar imagen de entrada */
    uint32_t in_width, in_height;
    uint8_t *input = load_pgm(cfg->input_file, &in_width, &in_height);
    if (!input) {
        return 1;
    }
    
    if (cfg->verbose) {
        printf("Input image: %s (%ux%u)\n", cfg->input_file, in_width, in_height);
    }
    
    /* Calculate output dimensions */
    uint32_t out_width = (uint32_t)(in_width * cfg->scale);
    uint32_t out_height = (uint32_t)(in_height * cfg->scale);
    q8_8_t scale_q8_8 = float_to_q8_8(cfg->scale);
    
    if (cfg->verbose) {
        printf("Output dimensions: %ux%u\n", out_width, out_height);
        printf("Scale: %.4f (Q8.8: 0x%04X)\n", cfg->scale, scale_q8_8);
        printf("Mode: %s", cfg->mode ? "SIMD" : "Sequential");
        if (cfg->mode) printf(" (%d lanes)", cfg->simd_lanes);
        printf("\n");
    }
    
    /* Allocate reference output */
    size_t out_size = (size_t)out_width * out_height;
    uint8_t *reference = (uint8_t*)malloc(out_size);
    if (!reference) {
        fprintf(stderr, "Error: Out of memory\n");
        free(input);
        return 1;
    }
    
    /* Generate reference using C model */
    clock_t start = clock();
    
    if (cfg->mode == 0) {
        downscale_bilinear_sequential(
            input, reference,
            in_width, in_height,
            out_width, out_height,
            scale_q8_8,
            NULL, NULL, NULL
        );
    } else {
        downscale_bilinear_simd(
            input, reference,
            in_width, in_height,
            out_width, out_height,
            scale_q8_8,
            cfg->simd_lanes,
            NULL, NULL, NULL
        );
    }
    
    clock_t end = clock();
    double elapsed_ms = (double)(end - start) / CLOCKS_PER_SEC * 1000.0;
    
    if (cfg->verbose) {
        printf("Reference generated in %.2f ms\n", elapsed_ms);
    }
    
    /* Save reference if requested */
    if (cfg->reference_file) {
        if (save_pgm(cfg->reference_file, reference, out_width, out_height) == 0) {
            printf("Reference saved to: %s\n", cfg->reference_file);
        }
    }
    
    /* If generate-only mode, we're done */
    if (cfg->generate_only) {
        /* In generate mode, output_file is the destination */
        if (save_pgm(cfg->output_file, reference, out_width, out_height) == 0) {
            printf("Generated reference: %s (%ux%u)\n", cfg->output_file, out_width, out_height);
        }
        free(input);
        free(reference);
        return 0;
    }
    
    /* Load FPGA output */
    uint32_t fpga_width, fpga_height;
    uint8_t *fpga_output = load_pgm(cfg->output_file, &fpga_width, &fpga_height);
    if (!fpga_output) {
        free(input);
        free(reference);
        return 1;
    }
    
    if (cfg->verbose) {
        printf("FPGA output: %s (%ux%u)\n", cfg->output_file, fpga_width, fpga_height);
    }
    
    /* Check dimensions */
    if (fpga_width != out_width || fpga_height != out_height) {
        fprintf(stderr, "Error: Dimension mismatch!\n");
        fprintf(stderr, "  Expected: %ux%u\n", out_width, out_height);
        fprintf(stderr, "  Got: %ux%u\n", fpga_width, fpga_height);
        free(input);
        free(reference);
        free(fpga_output);
        return 1;
    }
    
    /* Compare images */
    uint32_t diff_count, first_x, first_y;
    int mismatch = compare_images(
        reference, fpga_output,
        out_width, out_height,
        NULL, &diff_count, &first_x, &first_y
    );
    
    /* Print results */
    printf("\n=== DSA Downscaler Validation ===\n");
    printf("Input:       %s (%ux%u)\n", cfg->input_file, in_width, in_height);
    printf("FPGA Output: %s (%ux%u)\n", cfg->output_file, fpga_width, fpga_height);
    printf("Scale:       %.4f (Q8.8: 0x%04X)\n", cfg->scale, scale_q8_8);
    printf("\n");
    
    if (!mismatch) {
        printf("Result: PASS - Bit-exact match!\n");
    } else {
        printf("Result: FAIL\n");
        printf("  Pixels differ: %u / %zu\n", diff_count, out_size);
        printf("  First diff at: (%u, %u)\n", first_x, first_y);
        
        size_t idx = first_y * out_width + first_x;
        printf("    Expected: %u\n", reference[idx]);
        printf("    Got:      %u\n", fpga_output[idx]);
    }
    
    /* Save difference image if requested */
    if (cfg->diff_file && mismatch) {
        uint8_t *diff_img = (uint8_t*)malloc(out_size);
        if (diff_img) {
            for (size_t i = 0; i < out_size; i++) {
                int d = abs((int)reference[i] - (int)fpga_output[i]);
                /* Amplify differences for visibility */
                diff_img[i] = (uint8_t)(d > 25 ? 255 : d * 10);
            }
            if (save_pgm(cfg->diff_file, diff_img, out_width, out_height) == 0) {
                printf("Difference image saved to: %s\n", cfg->diff_file);
            }
            free(diff_img);
        }
    }
    
    free(input);
    free(reference);
    free(fpga_output);
    
    return mismatch ? 1 : 0;
}

/*===========================================================================
 * Main
 *===========================================================================*/

int main(int argc, char *argv[]) {
    config_t cfg = {
        .input_file = NULL,
        .output_file = NULL,
        .reference_file = NULL,
        .diff_file = NULL,
        .scale = 0.5f,
        .mode = 0,          /* sequential */
        .simd_lanes = 8,
        .verbose = 0,
        .generate_only = 0,
        .batch_mode = 0,
        .batch_dir = NULL
    };
    
    /* Parse arguments */
    int positional = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
            cfg.verbose = 1;
        } else if (strcmp(argv[i], "--generate") == 0) {
            cfg.generate_only = 1;
        } else if (strcmp(argv[i], "-s") == 0 || strcmp(argv[i], "--scale") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -s requires a value\n");
                return 1;
            }
            cfg.scale = atof(argv[i]);
            if (cfg.scale < 0.1f || cfg.scale > 1.0f) {
                fprintf(stderr, "Error: Scale must be between 0.1 and 1.0\n");
                return 1;
            }
        } else if (strcmp(argv[i], "-m") == 0 || strcmp(argv[i], "--mode") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -m requires a value\n");
                return 1;
            }
            if (strcmp(argv[i], "sequential") == 0 || strcmp(argv[i], "seq") == 0) {
                cfg.mode = 0;
            } else if (strcmp(argv[i], "simd") == 0) {
                cfg.mode = 1;
            } else {
                fprintf(stderr, "Error: Unknown mode '%s'\n", argv[i]);
                return 1;
            }
        } else if (strcmp(argv[i], "-l") == 0 || strcmp(argv[i], "--lanes") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -l requires a value\n");
                return 1;
            }
            cfg.simd_lanes = atoi(argv[i]);
            if (cfg.simd_lanes != 2 && cfg.simd_lanes != 4 && cfg.simd_lanes != 8) {
                fprintf(stderr, "Error: SIMD lanes must be 2, 4, or 8\n");
                return 1;
            }
        } else if (strcmp(argv[i], "-r") == 0 || strcmp(argv[i], "--reference") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -r requires a filename\n");
                return 1;
            }
            cfg.reference_file = argv[i];
        } else if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--diff") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -d requires a filename\n");
                return 1;
            }
            cfg.diff_file = argv[i];
        } else if (argv[i][0] != '-') {
            /* Positional argument */
            if (positional == 0) {
                cfg.input_file = argv[i];
            } else if (positional == 1) {
                cfg.output_file = argv[i];
            }
            positional++;
        } else {
            fprintf(stderr, "Error: Unknown option '%s'\n", argv[i]);
            return 1;
        }
    }
    
    /* Validate required arguments */
    if (!cfg.input_file || !cfg.output_file) {
        fprintf(stderr, "Error: Input and output files are required\n");
        print_usage(argv[0]);
        return 1;
    }
    
    return validate_images(&cfg);
}
