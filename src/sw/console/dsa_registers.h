/*
 * DSA Downscaler Console - GDB-style interface
 * Communicates with FPGA via JTAG using Intel's jtag_atlantic library
 * 
 * Build: See Makefile or compile with:
 *   gcc -o dsa_console dsa_console.c jtag_comm.c -I%QUARTUS_ROOTDIR%/include 
 *       -L%QUARTUS_ROOTDIR%/lib64 -ljtag_client
 */

#ifndef DSA_REGISTERS_H
#define DSA_REGISTERS_H

#include <stdint.h>

/*===========================================================================
 * Base Addresses
 *===========================================================================*/
#define SDRAM_BASE          0x00000000
#define SDRAM_SIZE          0x04000000  /* 64 MB */

#define CSR_BASE            0x04000000
#define CSR_SIZE            0x00004000  /* 16 KB */

/*===========================================================================
 * CSR Register Offsets
 *===========================================================================*/

/* Control/Configuration Registers */
#define CSR_CTRL            0x000   /* Control register */
#define CSR_STATUS          0x004   /* Status register (RO) */
#define CSR_IN_WIDTH        0x008   /* Input image width */
#define CSR_IN_HEIGHT       0x00C   /* Input image height */
#define CSR_OUT_WIDTH       0x010   /* Output image width */
#define CSR_OUT_HEIGHT      0x014   /* Output image height */
#define CSR_SCALE_Q8_8      0x018   /* Q8.8 scale factor */
#define CSR_MODE            0x020   /* Mode configuration */
#define CSR_PROGRESS        0x024   /* Progress (RO) */

/* Performance Counters (simplified - cycles only) */
#define CSR_PERF_CYCLES_LO  0x058
#define CSR_PERF_CYCLES_HI  0x05C

/* DMA Configuration */
#define CSR_IMG_IN_ADDR     0x080
#define CSR_IMG_OUT_ADDR    0x084

/* Debug Registers (read-only) */
#define CSR_DBG_FSM         0x0F0   /* [19:16]=FSM state, [15:0]=out_x */
#define CSR_DBG_OUT_Y       0x0E0   /* [15:0]=out_y */
#define CSR_DBG_COORD       0x0F4   /* [31:16]=src_y_int, [15:0]=src_x_int */
#define CSR_DBG_FRAC        0x0F8   /* [19:16]=lane, [15:8]=frac_y, [7:0]=frac_x */
#define CSR_DBG_PIXELS      0x0E4   /* [31:24]=p11, [23:16]=p10, [15:8]=p01, [7:0]=p00 */

/* Version */
#define CSR_VERSION         0x0FC

/*===========================================================================
 * Control Register Bits
 *===========================================================================*/
#define CTRL_START          (1 << 0)
#define CTRL_RESET          (1 << 1)
#define CTRL_STEP_ENABLE    (1 << 2)
#define CTRL_STEP_ONCE      (1 << 3)

/*===========================================================================
 * Status Register Bits
 *===========================================================================*/
#define STATUS_BUSY         (1 << 0)
#define STATUS_DONE         (1 << 1)
#define STATUS_ERROR_MASK   (0xF << 4)

/*===========================================================================
 * Mode Register - Simplified: only mode bit used
 * [0] = 0: SIMD (4 lanes), 1: Serial (1 pixel/cycle)
 *===========================================================================*/
#define MODE_SIMD           0
#define MODE_SERIAL         1
#define SIMD_LANES          4   /* Fixed at 4 lanes */

/*===========================================================================
 * Constants
 *===========================================================================*/
#define EXPECTED_VERSION    0x00010000
#define MAX_IMAGE_SIZE      2048
#define MIN_SCALE_Q8_8      0x0080  /* 0.5 */
#define MAX_SCALE_Q8_8      0x0100  /* 1.0 */

#define DEFAULT_IMG_IN_ADDR  0x00000000
#define DEFAULT_IMG_OUT_ADDR 0x00100000

/*===========================================================================
 * Helper Macros
 *===========================================================================*/
#define FLOAT_TO_Q8_8(f)    ((uint32_t)((f) * 256.0f))
#define Q8_8_TO_FLOAT(q)    ((float)(q) / 256.0f)
#define CSR_ADDR(offset)    (CSR_BASE + (offset))

#endif /* DSA_REGISTERS_H */
