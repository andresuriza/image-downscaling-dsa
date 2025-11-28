/**
 * Image Downscaler JTAG Test Application
 * Tests communication with FPGA accelerator via JTAG-to-Avalon bridge
 * 
 * Usage with Quartus System Console:
 *   This file shows the Tcl commands and C logic for testing.
 *   Run the Tcl commands in System Console or integrate with
 *   a C application using the Intel FPGA JTAG libraries.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "downscaler_regs.h"

//=======================================================
// JTAG Communication Stubs
// Replace with actual JTAG library calls (e.g., Intel FPGA SDK)
//=======================================================

// Placeholder - implement with actual JTAG library
uint32_t jtag_read32(uint32_t address) {
    // TODO: Implement using Intel FPGA JTAG library
    // Example: return alt_avalon_jtag_read_32(master, address);
    printf("JTAG READ:  0x%08X\n", address);
    return 0;
}

void jtag_write32(uint32_t address, uint32_t data) {
    // TODO: Implement using Intel FPGA JTAG library
    printf("JTAG WRITE: 0x%08X = 0x%08X\n", address, data);
}

void jtag_write_burst(uint32_t address, const uint8_t* data, uint32_t length) {
    // TODO: Implement burst write for image data
    printf("JTAG BURST WRITE: 0x%08X, %u bytes\n", address, length);
}

void jtag_read_burst(uint32_t address, uint8_t* data, uint32_t length) {
    // TODO: Implement burst read for image data
    printf("JTAG BURST READ: 0x%08X, %u bytes\n", address, length);
}

//=======================================================
// Downscaler API Functions
//=======================================================

int downscaler_check_version(void) {
    uint32_t version = jtag_read32(CSR_ADDR(CSR_VERSION));
    printf("Accelerator version: 0x%08X\n", version);
    
    if (version != EXPECTED_VERSION) {
        printf("WARNING: Version mismatch! Expected 0x%08X\n", EXPECTED_VERSION);
        return -1;
    }
    return 0;
}

void downscaler_reset(void) {
    jtag_write32(CSR_ADDR(CSR_CTRL), CTRL_RESET);
    // Wait a bit for reset to complete
    // usleep(1000);
    jtag_write32(CSR_ADDR(CSR_CTRL), 0);
}

void downscaler_configure(uint32_t in_width, uint32_t in_height,
                          uint32_t out_width, uint32_t out_height,
                          float scale, int simd_mode) {
    
    uint32_t scale_q8_8 = FLOAT_TO_Q8_8(scale);
    uint32_t mode = simd_mode ? MODE_SIMD : MODE_SERIAL;
    
    printf("Configuring downscaler:\n");
    printf("  Input:  %u x %u\n", in_width, in_height);
    printf("  Output: %u x %u\n", out_width, out_height);
    printf("  Scale:  %.2f (Q8.8 = 0x%04X)\n", scale, scale_q8_8);
    printf("  Mode:   %s\n", simd_mode ? "SIMD" : "Serial");
    
    jtag_write32(CSR_ADDR(CSR_IN_WIDTH), in_width);
    jtag_write32(CSR_ADDR(CSR_IN_HEIGHT), in_height);
    jtag_write32(CSR_ADDR(CSR_OUT_WIDTH), out_width);
    jtag_write32(CSR_ADDR(CSR_OUT_HEIGHT), out_height);
    jtag_write32(CSR_ADDR(CSR_SCALE_Q8_8), scale_q8_8);
    jtag_write32(CSR_ADDR(CSR_MODE), mode);
}

void downscaler_load_image(const uint8_t* image, uint32_t width, uint32_t height) {
    uint32_t size = width * height;
    
    printf("Loading image (%u x %u = %u bytes) to image buffer...\n", 
           width, height, size);
    
    // Write to on-chip image buffer
    jtag_write_burst(IMAGE_BUFFER_BASE, image, size);
}

void downscaler_start(void) {
    printf("Starting accelerator...\n");
    jtag_write32(CSR_ADDR(CSR_CTRL), CTRL_START);
}

int downscaler_wait_done(uint32_t timeout_ms) {
    printf("Waiting for completion...\n");
    
    for (uint32_t i = 0; i < timeout_ms; i++) {
        uint32_t status = jtag_read32(CSR_ADDR(CSR_STATUS));
        
        if (status & STATUS_DONE) {
            printf("Processing complete!\n");
            return 0;
        }
        
        if (!(status & STATUS_BUSY)) {
            printf("Accelerator idle but not done - error?\n");
            return -1;
        }
        
        // Print progress periodically
        if (i % 100 == 0) {
            uint32_t progress = jtag_read32(CSR_ADDR(CSR_PROGRESS));
            printf("  Progress: %u pixels\n", progress);
        }
        
        // usleep(1000);  // 1ms delay
    }
    
    printf("Timeout waiting for completion!\n");
    return -1;
}

void downscaler_step(void) {
    printf("Executing single step...\n");
    
    // Enable stepping mode
    jtag_write32(CSR_ADDR(CSR_CTRL), CTRL_STEP_ENABLE);
    
    // Trigger one step
    jtag_write32(CSR_ADDR(CSR_CTRL), CTRL_STEP_ENABLE | CTRL_STEP_ONCE);
    
    // Read status
    uint32_t status = jtag_read32(CSR_ADDR(CSR_STATUS));
    uint32_t progress = jtag_read32(CSR_ADDR(CSR_PROGRESS));
    printf("  Status: 0x%08X, Progress: %u\n", status, progress);
}

void downscaler_read_output(uint8_t* image, uint32_t width, uint32_t height) {
    uint32_t size = width * height;
    
    printf("Reading output image (%u x %u = %u bytes)...\n", 
           width, height, size);
    
    // Calculate output offset in image buffer
    // Assuming output is stored after input in the buffer
    uint32_t out_offset = 512 * 512;  // Max input size
    
    jtag_read_burst(IMAGE_BUFFER_BASE + out_offset, image, size);
}

void downscaler_print_counters(void) {
    uint64_t flops, reads, writes, cycles;
    
    flops  = jtag_read32(CSR_ADDR(CSR_PERF_FLOPS_LO));
    flops |= ((uint64_t)jtag_read32(CSR_ADDR(CSR_PERF_FLOPS_HI))) << 32;
    
    reads  = jtag_read32(CSR_ADDR(CSR_PERF_READS_LO));
    reads |= ((uint64_t)jtag_read32(CSR_ADDR(CSR_PERF_READS_HI))) << 32;
    
    writes  = jtag_read32(CSR_ADDR(CSR_PERF_WRITES_LO));
    writes |= ((uint64_t)jtag_read32(CSR_ADDR(CSR_PERF_WRITES_HI))) << 32;
    
    cycles  = jtag_read32(CSR_ADDR(CSR_PERF_CYCLES_LO));
    cycles |= ((uint64_t)jtag_read32(CSR_ADDR(CSR_PERF_CYCLES_HI))) << 32;
    
    printf("\nPerformance Counters:\n");
    printf("  FLOPs:        %llu\n", (unsigned long long)flops);
    printf("  Mem Reads:    %llu\n", (unsigned long long)reads);
    printf("  Mem Writes:   %llu\n", (unsigned long long)writes);
    printf("  Cycles:       %llu\n", (unsigned long long)cycles);
    
    if (cycles > 0) {
        double mflops = (double)flops / (double)cycles * 100.0;  // Assuming 100 MHz
        printf("  Throughput:   %.2f MFLOPS\n", mflops);
    }
}

//=======================================================
// Main Test
//=======================================================

int main(int argc, char* argv[]) {
    printf("===================================\n");
    printf("Image Downscaler JTAG Test\n");
    printf("===================================\n\n");
    
    // Check version
    if (downscaler_check_version() < 0) {
        return 1;
    }
    
    // Reset accelerator
    downscaler_reset();
    
    // Configure for 512x512 -> 256x256 (0.5 scale)
    downscaler_configure(512, 512, 256, 256, 0.5f, 1);
    
    // Create test image (gradient)
    uint8_t* test_image = (uint8_t*)malloc(512 * 512);
    for (int y = 0; y < 512; y++) {
        for (int x = 0; x < 512; x++) {
            test_image[y * 512 + x] = (uint8_t)((x + y) / 4);
        }
    }
    
    // Load image
    downscaler_load_image(test_image, 512, 512);
    
    // Start processing
    downscaler_start();
    
    // Wait for completion
    if (downscaler_wait_done(5000) < 0) {
        printf("Processing failed!\n");
        free(test_image);
        return 1;
    }
    
    // Read output
    uint8_t* output_image = (uint8_t*)malloc(256 * 256);
    downscaler_read_output(output_image, 256, 256);
    
    // Print counters
    downscaler_print_counters();
    
    // Cleanup
    free(test_image);
    free(output_image);
    
    printf("\nTest complete!\n");
    return 0;
}
