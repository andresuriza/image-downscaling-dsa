/**
 * @file generate_images.c
 * @brief Generador de imágenes de prueba para validación del DSA Downscaler
 * 
 * Genera varios patrones de prueba para validar el downscaler:
 * - Gradientes (diagonal, horizontal, vertical)
 * - Patrones de checkerboard
 * - Colores sólidos
 * - Ruido
 * - Círculos/Gradientes radiales
 * 
 * Uso:
 *   generate_images <output_dir> [--sizes 8,16,32,64,128,256,512]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

#include "bilinear_reference.h"

/*===========================================================================
 * Generadores de Patrones de Prueba
 *===========================================================================*/

/* Gradiente diagonal (esquina superior izquierda a inferior derecha) */
static void generate_gradient(uint8_t *img, uint32_t size) {
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            img[y * size + x] = (uint8_t)((x + y) * 255 / (2 * size - 2));
        }
    }
}

/* Gradiente horizontal (negro a blanco de izquierda a derecha) */
static void generate_hgradient(uint8_t *img, uint32_t size) {
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            img[y * size + x] = (uint8_t)(x * 255 / (size - 1));
        }
    }
}

/* Gradiente vertical (negro a blanco de arriba a abajo) */
static void generate_vgradient(uint8_t *img, uint32_t size) {
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            img[y * size + x] = (uint8_t)(y * 255 / (size - 1));
        }
    }
}

/* Patrón de tablero de ajedrez (bloques alternados blanco/negro) */
static void generate_checker(uint8_t *img, uint32_t size, uint32_t block_size) {
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            int bx = x / block_size;
            int by = y / block_size;
            img[y * size + x] = ((bx + by) % 2) ? 0 : 255;
        }
    }
}

/* Barras horizontales alternadas (8 barras) */
static void generate_hbars(uint8_t *img, uint32_t size) {
    uint32_t bar_height = size / 8;
    for (uint32_t y = 0; y < size; y++) {
        uint8_t val = ((y / bar_height) % 2) ? 0 : 255;
        for (uint32_t x = 0; x < size; x++) {
            img[y * size + x] = val;
        }
    }
}

/* Barras verticales alternadas (8 barras) */
static void generate_vbars(uint8_t *img, uint32_t size) {
    uint32_t bar_width = size / 8;
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            img[y * size + x] = ((x / bar_width) % 2) ? 0 : 255;
        }
    }
}

/* Radial gradient (circle) */
static void generate_circle(uint8_t *img, uint32_t size) {
    float center = size / 2.0f;
    float max_dist = center;
    
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            float dx = x - center;
            float dy = y - center;
            float dist = sqrtf(dx * dx + dy * dy);
            int val = (int)(255 - (dist / max_dist) * 255);
            img[y * size + x] = (uint8_t)(val < 0 ? 0 : (val > 255 ? 255 : val));
        }
    }
}

/* Random noise */
static void generate_noise(uint8_t *img, uint32_t size) {
    for (uint32_t i = 0; i < size * size; i++) {
        img[i] = (uint8_t)(rand() % 256);
    }
}

/* Four zones with different intensities */
static void generate_zones(uint8_t *img, uint32_t size) {
    uint32_t half = size / 2;
    for (uint32_t y = 0; y < size; y++) {
        for (uint32_t x = 0; x < size; x++) {
            if (y < half) {
                img[y * size + x] = (x < half) ? 64 : 128;
            } else {
                img[y * size + x] = (x < half) ? 192 : 255;
            }
        }
    }
}

/* Solid color */
static void generate_solid(uint8_t *img, uint32_t size, uint8_t value) {
    memset(img, value, size * size);
}

/*===========================================================================
 * Main
 *===========================================================================*/

int main(int argc, char *argv[]) {
    const char *output_dir = ".";
    
    /* Default sizes */
    uint32_t sizes[] = {8, 16, 32, 64, 128, 256, 512};
    int num_sizes = sizeof(sizes) / sizeof(sizes[0]);
    
    if (argc >= 2) {
        output_dir = argv[1];
    }
    
    srand(42);  /* Fixed seed for reproducibility */
    
    printf("=== DSA Downscaler Test Image Generator ===\n");
    printf("Output directory: %s\n\n", output_dir);
    
    /* Pattern generators */
    struct {
        const char *name;
        void (*generator)(uint8_t*, uint32_t);
    } patterns[] = {
        {"gradient", generate_gradient},
        {"hgradient", generate_hgradient},
        {"vgradient", generate_vgradient},
        {"hbars", generate_hbars},
        {"vbars", generate_vbars},
        {"circle", generate_circle},
        {"noise", generate_noise},
        {"zones", generate_zones},
    };
    int num_patterns = sizeof(patterns) / sizeof(patterns[0]);
    
    int total = 0;
    
    for (int s = 0; s < num_sizes; s++) {
        uint32_t size = sizes[s];
        uint8_t *img = (uint8_t*)malloc(size * size);
        if (!img) {
            fprintf(stderr, "Error: Out of memory\n");
            return 1;
        }
        
        /* Generate each pattern */
        for (int p = 0; p < num_patterns; p++) {
            patterns[p].generator(img, size);
            
            char filename[512];
            snprintf(filename, sizeof(filename), "%s/%s_%ux%u.pgm",
                     output_dir, patterns[p].name, size, size);
            
            if (save_pgm(filename, img, size, size) == 0) {
                printf("Created: %s\n", filename);
                total++;
            }
        }
        
        /* Checkerboard with size-dependent block size */
        uint32_t block = (size >= 64) ? size / 16 : 1;
        generate_checker(img, size, block);
        
        char filename[512];
        snprintf(filename, sizeof(filename), "%s/checker_%ux%u.pgm",
                 output_dir, size, size);
        
        if (save_pgm(filename, img, size, size) == 0) {
            printf("Created: %s\n", filename);
            total++;
        }
        
        /* Solid images for edge cases */
        generate_solid(img, size, 0);
        snprintf(filename, sizeof(filename), "%s/black_%ux%u.pgm",
                 output_dir, size, size);
        if (save_pgm(filename, img, size, size) == 0) {
            printf("Created: %s\n", filename);
            total++;
        }
        
        generate_solid(img, size, 255);
        snprintf(filename, sizeof(filename), "%s/white_%ux%u.pgm",
                 output_dir, size, size);
        if (save_pgm(filename, img, size, size) == 0) {
            printf("Created: %s\n", filename);
            total++;
        }
        
        generate_solid(img, size, 128);
        snprintf(filename, sizeof(filename), "%s/gray_%ux%u.pgm",
                 output_dir, size, size);
        if (save_pgm(filename, img, size, size) == 0) {
            printf("Created: %s\n", filename);
            total++;
        }
        
        free(img);
    }
    
    printf("\n=== Generated %d test images ===\n", total);
    
    /* Print summary for large images */
    printf("\n=== Large Images for SDRAM Testing ===\n");
    for (int s = 0; s < num_sizes; s++) {
        if (sizes[s] >= 256) {
            uint32_t pixels = sizes[s] * sizes[s];
            printf("  %ux%u: %u bytes (%.1f KB)\n", 
                   sizes[s], sizes[s], pixels, pixels / 1024.0f);
        }
    }
    
    return 0;
}
