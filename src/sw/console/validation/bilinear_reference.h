/**
 * @file bilinear_reference.h
 * @brief Reference C implementation of bilinear interpolation downscaling
 * 
 * This model uses Q8.8 fixed-point arithmetic identical to the hardware
 * implementation for bit-accurate validation.
 * 
 * Fixed-point format: Q8.8
 *   - 8 bits integer part
 *   - 8 bits fractional part
 *   - Range: 0.0 to 255.99609375
 */

#ifndef BILINEAR_REFERENCE_H
#define BILINEAR_REFERENCE_H

#include <stdint.h>
#include <stddef.h>

/*===========================================================================
 * Q8.8 Fixed-Point Arithmetic
 * Same format as hardware: 16-bit value with 8 fractional bits
 *===========================================================================*/

typedef uint16_t q8_8_t;    /* Q8.8 fixed-point type */
typedef uint32_t q16_16_t;  /* Q16.16 for intermediate calculations */

/* Q8.8 constants */
#define Q8_8_ONE        0x0100      /* 1.0 in Q8.8 */
#define Q8_8_HALF       0x0080      /* 0.5 in Q8.8 */
#define Q8_8_FRAC_MASK  0x00FF      /* Fractional part mask */
#define Q8_8_INT_MASK   0xFF00      /* Integer part mask */
#define Q8_8_SHIFT      8           /* Fractional bits */

/* Convert float to Q8.8 */
static inline q8_8_t float_to_q8_8(float f) {
    return (q8_8_t)(f * 256.0f + 0.5f);
}

/* Convert Q8.8 to float */
static inline float q8_8_to_float(q8_8_t q) {
    return (float)q / 256.0f;
}

/* Get integer part of Q8.8 */
static inline uint8_t q8_8_int(q8_8_t q) {
    return (uint8_t)(q >> Q8_8_SHIFT);
}

/* Get fractional part of Q8.8 (as 8-bit value 0-255) */
static inline uint8_t q8_8_frac(q8_8_t q) {
    return (uint8_t)(q & Q8_8_FRAC_MASK);
}

/* Multiply two Q8.8 values, result is Q8.8 */
static inline q8_8_t q8_8_mul(q8_8_t a, q8_8_t b) {
    q16_16_t result = (q16_16_t)a * (q16_16_t)b;
    return (q8_8_t)(result >> Q8_8_SHIFT);
}

/* Multiply Q8.8 by 8-bit pixel value, result is Q8.8 */
static inline q8_8_t q8_8_mul_u8(q8_8_t q, uint8_t pixel) {
    q16_16_t result = (q16_16_t)q * (q16_16_t)pixel;
    return (q8_8_t)(result >> Q8_8_SHIFT);
}

/*===========================================================================
 * Bilinear Interpolation - Hardware-Equivalent Algorithm
 *===========================================================================*/

/**
 * @brief Perform bilinear interpolation on 4 neighbor pixels
 * 
 * This function implements the exact same algorithm as the hardware:
 * 
 *   P00 -------- P01
 *    |     |      |
 *    |  fx |      |
 *    |-----|------|
 *    | fy  |  P   |
 *    |     |      |
 *   P10 -------- P11
 * 
 * Formula (hardware-equivalent):
 *   w00 = (1-fx) * (1-fy)
 *   w01 = fx * (1-fy)
 *   w10 = (1-fx) * fy
 *   w11 = fx * fy
 *   result = P00*w00 + P01*w01 + P10*w10 + P11*w11
 * 
 * @param p00 Top-left pixel
 * @param p01 Top-right pixel
 * @param p10 Bottom-left pixel
 * @param p11 Bottom-right pixel
 * @param frac_x Fractional X position (Q8.8, only lower 8 bits used)
 * @param frac_y Fractional Y position (Q8.8, only lower 8 bits used)
 * @return Interpolated pixel value (8-bit)
 */
static inline uint8_t bilinear_interpolate(
    uint8_t p00, uint8_t p01,
    uint8_t p10, uint8_t p11,
    uint8_t frac_x, uint8_t frac_y
) {
    /* Calculate weights in Q8.8 format */
    /* (1 - frac) = 256 - frac when frac is 0-255 scaled to Q8.8 */
    uint16_t fx = frac_x;           /* 0-255 representing 0.0-0.996 */
    uint16_t fy = frac_y;
    uint16_t inv_fx = 256 - fx;     /* (1.0 - fx) in same scale */
    uint16_t inv_fy = 256 - fy;
    
    /* Calculate weights (result is 0-65536 range, representing Q16.16) */
    uint32_t w00 = (uint32_t)inv_fx * inv_fy;   /* (1-fx)(1-fy) */
    uint32_t w01 = (uint32_t)fx * inv_fy;       /* fx(1-fy) */
    uint32_t w10 = (uint32_t)inv_fx * fy;       /* (1-fx)fy */
    uint32_t w11 = (uint32_t)fx * fy;           /* fx*fy */
    
    /* Weighted sum: multiply each pixel by its weight */
    /* Result is in Q16.16 + 8 = Q24.16 effectively */
    uint32_t sum = w00 * p00 + w01 * p01 + w10 * p10 + w11 * p11;
    
    /* Normalize: divide by 65536 (shift right by 16) with rounding */
    /* Add 0x8000 (0.5 in Q16) before shift for proper rounding */
    uint8_t result = (uint8_t)((sum + 0x8000) >> 16);
    
    return result;
}

/*===========================================================================
 * Downscaling Functions
 *===========================================================================*/

/**
 * @brief Downscale an image using bilinear interpolation (sequential mode)
 * 
 * @param input Input image buffer (row-major, 8bpp grayscale)
 * @param output Output image buffer (must be pre-allocated)
 * @param in_width Input image width
 * @param in_height Input image height
 * @param out_width Output image width
 * @param out_height Output image height
 * @param scale_q8_8 Scale factor in Q8.8 format
 * @param flops_count Pointer to FLOP counter (can be NULL)
 * @param mem_reads Pointer to memory read counter (can be NULL)
 * @param mem_writes Pointer to memory write counter (can be NULL)
 */
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
);

/**
 * @brief Downscale an image using bilinear interpolation (SIMD mode)
 * 
 * Processes multiple pixels per iteration to simulate hardware SIMD.
 * 
 * @param input Input image buffer
 * @param output Output image buffer
 * @param in_width Input image width
 * @param in_height Input image height
 * @param out_width Output image width
 * @param out_height Output image height
 * @param scale_q8_8 Scale factor in Q8.8 format
 * @param simd_lanes Number of SIMD lanes (2, 4, or 8)
 * @param flops_count Pointer to FLOP counter
 * @param mem_reads Pointer to memory read counter
 * @param mem_writes Pointer to memory write counter
 */
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
);

/**
 * @brief Compare two images and report differences
 * 
 * @param img1 First image
 * @param img2 Second image
 * @param width Image width
 * @param height Image height
 * @param max_diff Output: maximum pixel difference
 * @param diff_count Output: number of differing pixels
 * @param first_diff_x Output: X coordinate of first difference
 * @param first_diff_y Output: Y coordinate of first difference
 * @return 0 if images match exactly, 1 otherwise
 */
int compare_images(
    const uint8_t *img1,
    const uint8_t *img2,
    uint32_t width,
    uint32_t height,
    uint32_t *max_diff,
    uint32_t *diff_count,
    uint32_t *first_diff_x,
    uint32_t *first_diff_y
);

/*===========================================================================
 * Image I/O
 *===========================================================================*/

/**
 * @brief Load a PGM image (P2 or P5 format)
 * 
 * @param filename Path to PGM file
 * @param width Output: image width
 * @param height Output: image height
 * @return Allocated buffer with image data, or NULL on error
 */
uint8_t* load_pgm(const char *filename, uint32_t *width, uint32_t *height);

/**
 * @brief Save a PGM image (P5 binary format)
 * 
 * @param filename Path to output file
 * @param data Image data buffer
 * @param width Image width
 * @param height Image height
 * @return 0 on success, -1 on error
 */
int save_pgm(const char *filename, const uint8_t *data, uint32_t width, uint32_t height);

#endif /* BILINEAR_REFERENCE_H */
