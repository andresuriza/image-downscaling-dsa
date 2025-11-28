/**
 * Image Downscaler CSR Register Map
 * For use with JTAG-to-Avalon communication from PC
 * 
 * Base addresses (from Platform Designer):
 *   SDRAM:        0x0000_0000 - 0x03FF_FFFF (64 MB)
 *   Image Buffer: 0x0400_0000 - 0x0403_FFFF (256 KB)
 *   CSR RAM:      0x0404_0000 - 0x0404_0FFF (4 KB)
 */

#ifndef DOWNSCALER_REGS_H
#define DOWNSCALER_REGS_H

#include <stdint.h>

//=======================================================
// Base Addresses
//=======================================================
#define SDRAM_BASE          0x00000000
#define SDRAM_SIZE          0x04000000  // 64 MB

#define CSR_BASE            0x04000000  // downscaler_top.csr_slave
#define CSR_SIZE            0x00004000  // 16 KB

#define CSR_RAM_BASE        0x04004000  // csr_ram (general purpose)
#define CSR_RAM_SIZE        0x00001000  // 4 KB

//=======================================================
// CSR Register Offsets (relative to CSR_BASE)
//=======================================================

// Control/Configuration Registers (R/W)
#define CSR_CTRL            0x000   // Control register
#define CSR_STATUS          0x004   // Status register (read-only)
#define CSR_IN_WIDTH        0x008   // Input image width
#define CSR_IN_HEIGHT       0x00C   // Input image height
#define CSR_OUT_WIDTH       0x010   // Output image width
#define CSR_OUT_HEIGHT      0x014   // Output image height
#define CSR_SCALE_Q8_8      0x018   // Q8.8 scale factor
#define CSR_MODE            0x01C   // Mode configuration
#define CSR_PROGRESS        0x020   // Progress (pixels processed, read-only)
#define CSR_ERRORS          0x024   // Error count (read-only)

// Performance Counters (read-only, 64-bit split)
#define CSR_PERF_FLOPS_LO   0x040   // FLOP counter [31:0]
#define CSR_PERF_FLOPS_HI   0x044   // FLOP counter [63:32]
#define CSR_PERF_READS_LO   0x048   // Memory reads [31:0]
#define CSR_PERF_READS_HI   0x04C   // Memory reads [63:32]
#define CSR_PERF_WRITES_LO  0x050   // Memory writes [31:0]
#define CSR_PERF_WRITES_HI  0x054   // Memory writes [63:32]
#define CSR_PERF_CYCLES_LO  0x058   // Cycle counter [31:0]
#define CSR_PERF_CYCLES_HI  0x05C   // Cycle counter [63:32]

// DMA Configuration
#define CSR_IMG_IN_ADDR     0x080   // Input image SDRAM address
#define CSR_IMG_OUT_ADDR    0x084   // Output image SDRAM address

// Version
#define CSR_VERSION         0x0FC   // Version register (read-only)

//=======================================================
// Control Register Bits (CSR_CTRL @ 0x000)
//=======================================================
#define CTRL_START          (1 << 0)    // Start processing (auto-clears)
#define CTRL_RESET          (1 << 1)    // Reset accelerator
#define CTRL_STEP_ENABLE    (1 << 2)    // Enable step mode
#define CTRL_STEP_ONCE      (1 << 3)    // Execute single step (auto-clears)

//=======================================================
// Status Register Bits (CSR_STATUS @ 0x004)
//=======================================================
#define STATUS_BUSY         (1 << 0)    // Accelerator busy
#define STATUS_DONE         (1 << 1)    // Processing complete
#define STATUS_ERROR_MASK   (0xF << 4)  // Error code [7:4]

//=======================================================
// Mode Register Bits (CSR_MODE @ 0x01C)
//=======================================================
#define MODE_SIMD           0           // SIMD parallel mode
#define MODE_SERIAL         1           // Sequential mode
#define MODE_LANES_SHIFT    4           // SIMD lane count [7:4]

//=======================================================
// Helper Macros
//=======================================================

// Convert float scale (0.5-1.0) to Q8.8 fixed point
#define FLOAT_TO_Q8_8(f)    ((uint32_t)((f) * 256.0f))

// Convert Q8.8 to float
#define Q8_8_TO_FLOAT(q)    ((float)(q) / 256.0f)

// Calculate output dimension from input and scale
#define CALC_OUT_DIM(in_dim, scale_q8_8) \
    (((in_dim) * (scale_q8_8)) >> 8)

// Absolute address helpers
#define CSR_ADDR(offset)    (CSR_BASE + (offset))
#define SDRAM_ADDR(offset)  (SDRAM_BASE + (offset))
#define IMGBUF_ADDR(offset) (IMAGE_BUFFER_BASE + (offset))

//=======================================================
// Expected Version
//=======================================================
#define EXPECTED_VERSION    0x00010000  // v1.0

#endif // DOWNSCALER_REGS_H
