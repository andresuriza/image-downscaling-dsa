/**
 * @file bilinear_reference.c
 * @brief Reference C implementation of bilinear interpolation downscaling
 * 
 * This implementation uses Q8.8 fixed-point arithmetic to match
 * the hardware implementation exactly for bit-accurate validation.
 */

#include "bilinear_reference.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/*===========================================================================
 * Downscaling Implementation - Sequential Mode
 *===========================================================================*/

void downscale_bilinear_sequential(
    const uint8_t *input,
    uint8_t *output,
    uint32_t in_width,
    uint32_t in_height,
    uint32_t out_width,
    uint32_t out_height,
    q8_8_t scale_q8_8,
    uint64_t *flops_count,
    uint64_t *mem_reads,
    uint64_t *mem_writes
) {
    uint64_t flops = 0, reads = 0, writes = 0;
    
    /* Inverse scale for mapping output to input coordinates */
    /* inv_scale = 1.0 / scale = 256 / scale_q8_8 (in Q8.8) */
    /* For better precision, we compute src = dst / scale directly */
    
    for (uint32_t out_y = 0; out_y < out_height; out_y++) {
        for (uint32_t out_x = 0; out_x < out_width; out_x++) {
            
            /* Calculate source coordinates in Q8.8 fixed-point */
            /* src_x = out_x / scale = out_x * (1/scale) */
            /* Using: src = out * 256 / scale_q8_8 */
            uint32_t src_x_q8 = ((uint32_t)out_x << 16) / scale_q8_8;
            uint32_t src_y_q8 = ((uint32_t)out_y << 16) / scale_q8_8;
            
            /* Extract integer and fractional parts */
            uint32_t src_x_int = src_x_q8 >> 8;
            uint32_t src_y_int = src_y_q8 >> 8;
            uint8_t frac_x = src_x_q8 & 0xFF;
            uint8_t frac_y = src_y_q8 & 0xFF;
            
            /* Clamp to valid range */
            uint32_t x0 = src_x_int;
            uint32_t y0 = src_y_int;
            uint32_t x1 = (x0 + 1 < in_width) ? x0 + 1 : in_width - 1;
            uint32_t y1 = (y0 + 1 < in_height) ? y0 + 1 : in_height - 1;
            
            /* Clamp coordinates to valid range */
            if (x0 >= in_width) x0 = in_width - 1;
            if (y0 >= in_height) y0 = in_height - 1;
            
            /* Fetch 4 neighbor pixels */
            uint8_t p00 = input[y0 * in_width + x0];
            uint8_t p01 = input[y0 * in_width + x1];
            uint8_t p10 = input[y1 * in_width + x0];
            uint8_t p11 = input[y1 * in_width + x1];
            reads += 4;
            
            /* Perform bilinear interpolation */
            uint8_t result = bilinear_interpolate(p00, p01, p10, p11, frac_x, frac_y);
            
            /* Count FLOPs: 4 multiplies for weights, 4 multiplies for weighted pixels, 3 adds */
            flops += 11;
            
            /* Write output pixel */
            output[out_y * out_width + out_x] = result;
            writes += 1;
        }
    }
    
    if (flops_count) *flops_count = flops;
    if (mem_reads) *mem_reads = reads;
    if (mem_writes) *mem_writes = writes;
}

/*===========================================================================
 * Downscaling Implementation - SIMD Mode
 *===========================================================================*/

void downscale_bilinear_simd(
    const uint8_t *input,
    uint8_t *output,
    uint32_t in_width,
    uint32_t in_height,
    uint32_t out_width,
    uint32_t out_height,
    q8_8_t scale_q8_8,
    uint32_t simd_lanes,
    uint64_t *flops_count,
    uint64_t *mem_reads,
    uint64_t *mem_writes
) {
    uint64_t flops = 0, reads = 0, writes = 0;
    
    /* Temporary arrays for SIMD processing */
    uint8_t p00[8], p01[8], p10[8], p11[8];
    uint8_t frac_x[8], frac_y[8];
    uint8_t results[8];
    
    for (uint32_t out_y = 0; out_y < out_height; out_y++) {
        /* Process SIMD_LANES pixels at a time in X direction */
        for (uint32_t out_x = 0; out_x < out_width; out_x += simd_lanes) {
            
            uint32_t lanes_this_iter = simd_lanes;
            if (out_x + lanes_this_iter > out_width) {
                lanes_this_iter = out_width - out_x;
            }
            
            /* Calculate source coordinates for all lanes */
            for (uint32_t lane = 0; lane < lanes_this_iter; lane++) {
                uint32_t ox = out_x + lane;
                
                uint32_t src_x_q8 = ((uint32_t)ox << 16) / scale_q8_8;
                uint32_t src_y_q8 = ((uint32_t)out_y << 16) / scale_q8_8;
                
                uint32_t src_x_int = src_x_q8 >> 8;
                uint32_t src_y_int = src_y_q8 >> 8;
                frac_x[lane] = src_x_q8 & 0xFF;
                frac_y[lane] = src_y_q8 & 0xFF;
                
                uint32_t x0 = src_x_int;
                uint32_t y0 = src_y_int;
                uint32_t x1 = (x0 + 1 < in_width) ? x0 + 1 : in_width - 1;
                uint32_t y1 = (y0 + 1 < in_height) ? y0 + 1 : in_height - 1;
                
                if (x0 >= in_width) x0 = in_width - 1;
                if (y0 >= in_height) y0 = in_height - 1;
                
                /* Fetch neighbor pixels */
                p00[lane] = input[y0 * in_width + x0];
                p01[lane] = input[y0 * in_width + x1];
                p10[lane] = input[y1 * in_width + x0];
                p11[lane] = input[y1 * in_width + x1];
            }
            reads += lanes_this_iter * 4;
            
            /* SIMD interpolation (all lanes in parallel) */
            for (uint32_t lane = 0; lane < lanes_this_iter; lane++) {
                results[lane] = bilinear_interpolate(
                    p00[lane], p01[lane], p10[lane], p11[lane],
                    frac_x[lane], frac_y[lane]
                );
            }
            flops += lanes_this_iter * 11;
            
            /* Write results */
            for (uint32_t lane = 0; lane < lanes_this_iter; lane++) {
                output[out_y * out_width + out_x + lane] = results[lane];
            }
            writes += lanes_this_iter;
        }
    }
    
    if (flops_count) *flops_count = flops;
    if (mem_reads) *mem_reads = reads;
    if (mem_writes) *mem_writes = writes;
}

/*===========================================================================
 * Image Comparison
 *===========================================================================*/

int compare_images(
    const uint8_t *img1,
    const uint8_t *img2,
    uint32_t width,
    uint32_t height,
    uint32_t *max_diff,
    uint32_t *diff_count,
    uint32_t *first_diff_x,
    uint32_t *first_diff_y
) {
    uint32_t max_d = 0;
    uint32_t count = 0;
    uint32_t first_x = 0, first_y = 0;
    int found_first = 0;
    
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            uint32_t idx = y * width + x;
            int diff = abs((int)img1[idx] - (int)img2[idx]);
            
            if (diff > 0) {
                count++;
                if (!found_first) {
                    first_x = x;
                    first_y = y;
                    found_first = 1;
                }
                if ((uint32_t)diff > max_d) {
                    max_d = diff;
                }
            }
        }
    }
    
    if (max_diff) *max_diff = max_d;
    if (diff_count) *diff_count = count;
    if (first_diff_x) *first_diff_x = first_x;
    if (first_diff_y) *first_diff_y = first_y;
    
    return (count > 0) ? 1 : 0;
}

/*===========================================================================
 * Image I/O
 *===========================================================================*/

/* Skip whitespace and comments in PGM file */
static void skip_whitespace_comments(FILE *fp) {
    int c;
    while ((c = fgetc(fp)) != EOF) {
        if (c == '#') {
            /* Skip comment line */
            while ((c = fgetc(fp)) != EOF && c != '\n');
        } else if (!isspace(c)) {
            ungetc(c, fp);
            break;
        }
    }
}

uint8_t* load_pgm(const char *filename, uint32_t *width, uint32_t *height) {
    FILE *fp = fopen(filename, "rb");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open file '%s'\n", filename);
        return NULL;
    }
    
    char magic[3];
    if (fscanf(fp, "%2s", magic) != 1) {
        fprintf(stderr, "Error: Cannot read PGM magic number\n");
        fclose(fp);
        return NULL;
    }
    
    int is_binary;
    if (strcmp(magic, "P5") == 0) {
        is_binary = 1;
    } else if (strcmp(magic, "P2") == 0) {
        is_binary = 0;
    } else {
        fprintf(stderr, "Error: Not a valid PGM file (expected P2 or P5, got %s)\n", magic);
        fclose(fp);
        return NULL;
    }
    
    skip_whitespace_comments(fp);
    
    int w, h, maxval;
    if (fscanf(fp, "%d", &w) != 1) {
        fprintf(stderr, "Error: Cannot read width\n");
        fclose(fp);
        return NULL;
    }
    
    skip_whitespace_comments(fp);
    
    if (fscanf(fp, "%d", &h) != 1) {
        fprintf(stderr, "Error: Cannot read height\n");
        fclose(fp);
        return NULL;
    }
    
    skip_whitespace_comments(fp);
    
    if (fscanf(fp, "%d", &maxval) != 1) {
        fprintf(stderr, "Error: Cannot read maxval\n");
        fclose(fp);
        return NULL;
    }
    
    /* Skip single whitespace after header */
    fgetc(fp);
    
    size_t size = (size_t)w * h;
    uint8_t *data = (uint8_t*)malloc(size);
    if (!data) {
        fprintf(stderr, "Error: Out of memory\n");
        fclose(fp);
        return NULL;
    }
    
    if (is_binary) {
        if (fread(data, 1, size, fp) != size) {
            fprintf(stderr, "Error: Failed to read image data\n");
            free(data);
            fclose(fp);
            return NULL;
        }
    } else {
        for (size_t i = 0; i < size; i++) {
            int val;
            if (fscanf(fp, "%d", &val) != 1) {
                fprintf(stderr, "Error: Failed to read pixel %zu\n", i);
                free(data);
                fclose(fp);
                return NULL;
            }
            data[i] = (uint8_t)(val > 255 ? 255 : (val < 0 ? 0 : val));
        }
    }
    
    *width = w;
    *height = h;
    fclose(fp);
    return data;
}

int save_pgm(const char *filename, const uint8_t *data, uint32_t width, uint32_t height) {
    FILE *fp = fopen(filename, "wb");
    if (!fp) {
        fprintf(stderr, "Error: Cannot create file '%s'\n", filename);
        return -1;
    }
    
    fprintf(fp, "P5\n%u %u\n255\n", width, height);
    fwrite(data, 1, (size_t)width * height, fp);
    fclose(fp);
    return 0;
}
