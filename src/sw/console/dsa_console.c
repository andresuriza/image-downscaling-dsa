/*
 * DSA Downscaler Console - Main Application
 * GDB-style interactive console for controlling image downscaling accelerator
 * 
 * Commands:
 *   connect                     - Connect to FPGA via JTAG
 *   disconnect                  - Close JTAG connection
 *   set <param> <value>         - Set configuration parameter
 *   show <what>                 - Show status/config/perf
 *   run                         - Start processing
 *   step                        - Execute one step
 *   continue                    - Continue from pause
 *   abort                       - Abort current operation
 *   load <file>                 - Load input image
 *   dump <file>                 - Dump output image
 *   compare <file>              - Compare output with reference
 *   help                        - Show this help
 *   quit/exit                   - Exit console
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>

#include "dsa_registers.h"
#include "jtag_comm.h"

/*===========================================================================
 * Console State
 *===========================================================================*/
typedef struct {
    jtag_ctx_t jtag;
    uint32_t img_width;
    uint32_t img_height;
    float scale;
    int mode;
    int simd_lanes;
    bool configured;
    uint8_t *input_image;
    uint8_t *output_image;
    size_t input_size;
    size_t output_size;
} console_state_t;

static console_state_t g_state = {0};

/*===========================================================================
 * Image I/O (Simple PGM format for grayscale)
 *===========================================================================*/

static int load_pgm_image(const char *filename, uint8_t **data, uint32_t *width, uint32_t *height) {
    FILE *fp = fopen(filename, "rb");
    if (!fp) {
        printf("Error: Cannot open file '%s'\n", filename);
        return -1;
    }

    char magic[3];
    int w, h, maxval;
    
    if (fscanf(fp, "%2s", magic) != 1 || strcmp(magic, "P5") != 0) {
        printf("Error: Not a valid PGM (P5) file\n");
        fclose(fp);
        return -1;
    }

    /* Skip comments */
    int c;
    while ((c = fgetc(fp)) == '#') {
        while (fgetc(fp) != '\n');
    }
    ungetc(c, fp);

    if (fscanf(fp, "%d %d %d", &w, &h, &maxval) != 3) {
        printf("Error: Invalid PGM header\n");
        fclose(fp);
        return -1;
    }
    fgetc(fp); /* Skip whitespace after header */

    if (w > MAX_IMAGE_SIZE || h > MAX_IMAGE_SIZE) {
        printf("Error: Image too large (%dx%d, max %d)\n", w, h, MAX_IMAGE_SIZE);
        fclose(fp);
        return -1;
    }

    size_t size = w * h;
    *data = (uint8_t*)malloc(size);
    if (!*data) {
        printf("Error: Out of memory\n");
        fclose(fp);
        return -1;
    }

    if (fread(*data, 1, size, fp) != size) {
        printf("Error: Failed to read image data\n");
        free(*data);
        *data = NULL;
        fclose(fp);
        return -1;
    }

    *width = w;
    *height = h;
    fclose(fp);
    return 0;
}

static int save_pgm_image(const char *filename, const uint8_t *data, uint32_t width, uint32_t height) {
    FILE *fp = fopen(filename, "wb");
    if (!fp) {
        printf("Error: Cannot create file '%s'\n", filename);
        return -1;
    }

    fprintf(fp, "P5\n%u %u\n255\n", width, height);
    fwrite(data, 1, width * height, fp);
    fclose(fp);
    return 0;
}

/*===========================================================================
 * DSA Operations
 *===========================================================================*/

static int dsa_read_csr(uint32_t offset, uint32_t *value) {
    return jtag_read_32(&g_state.jtag, CSR_ADDR(offset), value);
}

static int dsa_write_csr(uint32_t offset, uint32_t value) {
    return jtag_write_32(&g_state.jtag, CSR_ADDR(offset), value);
}

static void dsa_print_status(void) {
    uint32_t status, ctrl, progress;
    
    if (dsa_read_csr(CSR_STATUS, &status) != JTAG_OK ||
        dsa_read_csr(CSR_CTRL, &ctrl) != JTAG_OK ||
        dsa_read_csr(CSR_PROGRESS, &progress) != JTAG_OK) {
        printf("Error reading status\n");
        return;
    }

    printf("=== DSA Status ===\n");
    printf("CTRL:     0x%08X", ctrl);
    printf(" [%s%s%s%s]\n",
           (ctrl & CTRL_START) ? "START " : "",
           (ctrl & CTRL_RESET) ? "RESET " : "",
           (ctrl & CTRL_STEP_ENABLE) ? "STEP_EN " : "",
           (ctrl & CTRL_STEP_ONCE) ? "STEP " : "");
    
    printf("STATUS:   0x%08X", status);
    printf(" [%s%s]\n",
           (status & STATUS_BUSY) ? "BUSY " : "",
           (status & STATUS_DONE) ? "DONE " : "");
    
    printf("PROGRESS: %u%%\n", progress);
}

static void dsa_print_config(void) {
    uint32_t in_w, in_h, out_w, out_h, scale_q, mode, version;
    
    if (dsa_read_csr(CSR_IN_WIDTH, &in_w) != JTAG_OK ||
        dsa_read_csr(CSR_IN_HEIGHT, &in_h) != JTAG_OK ||
        dsa_read_csr(CSR_OUT_WIDTH, &out_w) != JTAG_OK ||
        dsa_read_csr(CSR_OUT_HEIGHT, &out_h) != JTAG_OK ||
        dsa_read_csr(CSR_SCALE_Q8_8, &scale_q) != JTAG_OK ||
        dsa_read_csr(CSR_MODE, &mode) != JTAG_OK ||
        dsa_read_csr(CSR_VERSION, &version) != JTAG_OK) {
        printf("Error reading config\n");
        return;
    }

    printf("=== DSA Configuration ===\n");
    printf("Version:     %d.%d\n", (version >> 16) & 0xFF, version & 0xFFFF);
    printf("Input:       %u x %u\n", in_w, in_h);
    printf("Output:      %u x %u\n", out_w, out_h);
    printf("Scale:       %.3f (Q8.8: 0x%04X)\n", Q8_8_TO_FLOAT(scale_q), scale_q);
    printf("Mode:        %s\n", (mode & 1) ? "SERIAL" : "SIMD");
    if ((mode & 1) == 0) {
        printf("SIMD Lanes:  %u\n", (mode >> MODE_LANES_SHIFT) & 0xF);
    }
}

static void dsa_print_perf(void) {
    uint32_t flops_lo, flops_hi, reads_lo, reads_hi;
    uint32_t writes_lo, writes_hi, cycles_lo, cycles_hi;

    if (dsa_read_csr(CSR_PERF_FLOPS_LO, &flops_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_FLOPS_HI, &flops_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_READS_LO, &reads_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_READS_HI, &reads_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_WRITES_LO, &writes_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_WRITES_HI, &writes_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_CYCLES_LO, &cycles_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_CYCLES_HI, &cycles_hi) != JTAG_OK) {
        printf("Error reading perf counters\n");
        return;
    }

    uint64_t flops = ((uint64_t)flops_hi << 32) | flops_lo;
    uint64_t reads = ((uint64_t)reads_hi << 32) | reads_lo;
    uint64_t writes = ((uint64_t)writes_hi << 32) | writes_lo;
    uint64_t cycles = ((uint64_t)cycles_hi << 32) | cycles_lo;

    printf("=== Performance Counters ===\n");
    printf("FLOPs:       %llu\n", (unsigned long long)flops);
    printf("Memory Reads:  %llu bytes\n", (unsigned long long)reads);
    printf("Memory Writes: %llu bytes\n", (unsigned long long)writes);
    printf("Cycles:      %llu\n", (unsigned long long)cycles);
    
    if (cycles > 0) {
        double flops_per_cycle = (double)flops / cycles;
        printf("FLOPs/Cycle: %.2f\n", flops_per_cycle);
    }
}

/*===========================================================================
 * Command Handlers
 *===========================================================================*/

static void cmd_help(void) {
    printf("\n=== DSA Downscaler Console ===\n\n");
    printf("Connection:\n");
    printf("  connect              Connect to FPGA via JTAG\n");
    printf("  disconnect           Close JTAG connection\n");
    printf("\nConfiguration:\n");
    printf("  set width <n>        Set input image width\n");
    printf("  set height <n>       Set input image height\n");
    printf("  set scale <f>        Set scale factor (0.5-1.0)\n");
    printf("  set mode <serial|simd>  Set processing mode\n");
    printf("  set lanes <n>        Set SIMD lanes (2,4,8)\n");
    printf("\nExecution:\n");
    printf("  run                  Start processing\n");
    printf("  step                 Execute one step (step mode)\n");
    printf("  continue             Continue from pause\n");
    printf("  abort                Abort current operation\n");
    printf("  reset                Reset accelerator\n");
    printf("\nImage I/O:\n");
    printf("  load <file.pgm>      Load input image\n");
    printf("  dump <file.pgm>      Dump output image\n");
    printf("  compare <file.pgm>   Compare with reference\n");
    printf("\nStatus:\n");
    printf("  show status          Show accelerator status\n");
    printf("  show config          Show configuration\n");
    printf("  show perf            Show performance counters\n");
    printf("  show all             Show everything\n");
    printf("  read <addr>          Read CSR at offset (hex)\n");
    printf("  write <addr> <val>   Write CSR (hex)\n");
    printf("\nGeneral:\n");
    printf("  verbose <0|1>        Set verbose mode\n");
    printf("  help                 Show this help\n");
    printf("  quit, exit           Exit console\n\n");
}

static void cmd_connect(void) {
    if (g_state.jtag.connected) {
        printf("Already connected.\n");
        return;
    }

    printf("Connecting to FPGA...\n");
    int ret = jtag_open(&g_state.jtag);
    if (ret == JTAG_OK) {
        printf("Connected successfully.\n");
        
        /* Read and verify version */
        uint32_t version;
        if (dsa_read_csr(CSR_VERSION, &version) == JTAG_OK) {
            printf("DSA Version: %d.%d\n", (version >> 16) & 0xFF, version & 0xFFFF);
        }
    } else {
        printf("Connection failed: %s\n", jtag_strerror(ret));
    }
}

static void cmd_disconnect(void) {
    if (!g_state.jtag.connected) {
        printf("Not connected.\n");
        return;
    }
    jtag_close(&g_state.jtag);
    printf("Disconnected.\n");
}

static void cmd_set(const char *param, const char *value) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected. Use 'connect' first.\n");
        return;
    }

    if (strcmp(param, "width") == 0) {
        uint32_t w = atoi(value);
        if (w == 0 || w > MAX_IMAGE_SIZE) {
            printf("Invalid width (1-%d)\n", MAX_IMAGE_SIZE);
            return;
        }
        g_state.img_width = w;
        dsa_write_csr(CSR_IN_WIDTH, w);
        
        /* Auto-calculate output width */
        uint32_t out_w = (uint32_t)(w * g_state.scale);
        dsa_write_csr(CSR_OUT_WIDTH, out_w);
        printf("Width set to %u (output: %u)\n", w, out_w);
        
    } else if (strcmp(param, "height") == 0) {
        uint32_t h = atoi(value);
        if (h == 0 || h > MAX_IMAGE_SIZE) {
            printf("Invalid height (1-%d)\n", MAX_IMAGE_SIZE);
            return;
        }
        g_state.img_height = h;
        dsa_write_csr(CSR_IN_HEIGHT, h);
        
        /* Auto-calculate output height */
        uint32_t out_h = (uint32_t)(h * g_state.scale);
        dsa_write_csr(CSR_OUT_HEIGHT, out_h);
        printf("Height set to %u (output: %u)\n", h, out_h);
        
    } else if (strcmp(param, "scale") == 0) {
        float s = atof(value);
        if (s < 0.5f || s > 1.0f) {
            printf("Invalid scale (0.5-1.0)\n");
            return;
        }
        g_state.scale = s;
        uint32_t scale_q = FLOAT_TO_Q8_8(s);
        dsa_write_csr(CSR_SCALE_Q8_8, scale_q);
        printf("Scale set to %.3f (Q8.8: 0x%04X)\n", s, scale_q);
        
    } else if (strcmp(param, "mode") == 0) {
        if (strcmp(value, "simd") == 0 || strcmp(value, "SIMD") == 0) {
            g_state.mode = MODE_SIMD;
            uint32_t mode_val = MODE_SIMD | (g_state.simd_lanes << MODE_LANES_SHIFT);
            dsa_write_csr(CSR_MODE, mode_val);
            printf("Mode set to SIMD (%d lanes)\n", g_state.simd_lanes);
        } else if (strcmp(value, "serial") == 0 || strcmp(value, "SERIAL") == 0) {
            g_state.mode = MODE_SERIAL;
            dsa_write_csr(CSR_MODE, MODE_SERIAL);
            printf("Mode set to SERIAL\n");
        } else {
            printf("Invalid mode. Use 'simd' or 'serial'\n");
        }
        
    } else if (strcmp(param, "lanes") == 0) {
        int lanes = atoi(value);
        if (lanes != 2 && lanes != 4 && lanes != 8) {
            printf("Invalid lanes (2, 4, or 8)\n");
            return;
        }
        g_state.simd_lanes = lanes;
        if (g_state.mode == MODE_SIMD) {
            uint32_t mode_val = MODE_SIMD | (lanes << MODE_LANES_SHIFT);
            dsa_write_csr(CSR_MODE, mode_val);
        }
        printf("SIMD lanes set to %d\n", lanes);
        
    } else {
        printf("Unknown parameter: %s\n", param);
    }
}

static void cmd_run(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    /* Reset first, then start */
    dsa_write_csr(CSR_CTRL, CTRL_RESET);
    dsa_write_csr(CSR_CTRL, 0);
    dsa_write_csr(CSR_CTRL, CTRL_START);
    printf("Started processing...\n");
}

static void cmd_step(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    /* Enable step mode and trigger one step */
    dsa_write_csr(CSR_CTRL, CTRL_STEP_ENABLE | CTRL_STEP_ONCE);
    printf("Stepped.\n");
    dsa_print_status();
}

static void cmd_abort(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    dsa_write_csr(CSR_CTRL, CTRL_RESET);
    dsa_write_csr(CSR_CTRL, 0);
    printf("Aborted.\n");
}

static void cmd_load(const char *filename) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    uint32_t w, h;
    uint8_t *data;
    
    if (load_pgm_image(filename, &data, &w, &h) != 0) {
        return;
    }

    printf("Loaded image: %ux%u\n", w, h);

    /* Update dimensions in accelerator */
    g_state.img_width = w;
    g_state.img_height = h;
    dsa_write_csr(CSR_IN_WIDTH, w);
    dsa_write_csr(CSR_IN_HEIGHT, h);

    uint32_t out_w = (uint32_t)(w * g_state.scale);
    uint32_t out_h = (uint32_t)(h * g_state.scale);
    dsa_write_csr(CSR_OUT_WIDTH, out_w);
    dsa_write_csr(CSR_OUT_HEIGHT, out_h);

    /* Write to SDRAM */
    printf("Uploading to FPGA SDRAM at 0x%08X...\n", DEFAULT_IMG_IN_ADDR);
    size_t size = w * h;
    int ret = jtag_write_block(&g_state.jtag, DEFAULT_IMG_IN_ADDR, data, size);
    
    if (ret == JTAG_OK) {
        printf("Upload complete (%zu bytes)\n", size);
        free(g_state.input_image);
        g_state.input_image = data;
        g_state.input_size = size;
    } else {
        printf("Upload failed: %s\n", jtag_strerror(ret));
        free(data);
    }
}

static void cmd_dump(const char *filename) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    if (g_state.img_width == 0 || g_state.img_height == 0) {
        printf("Error: Image dimensions not set.\n");
        return;
    }

    uint32_t out_w = (uint32_t)(g_state.img_width * g_state.scale);
    uint32_t out_h = (uint32_t)(g_state.img_height * g_state.scale);
    size_t size = out_w * out_h;

    uint8_t *data = (uint8_t*)malloc(size);
    if (!data) {
        printf("Error: Out of memory\n");
        return;
    }

    printf("Downloading from FPGA SDRAM at 0x%08X...\n", DEFAULT_IMG_OUT_ADDR);
    int ret = jtag_read_block(&g_state.jtag, DEFAULT_IMG_OUT_ADDR, data, size);

    if (ret == JTAG_OK) {
        printf("Download complete (%zu bytes)\n", size);
        if (save_pgm_image(filename, data, out_w, out_h) == 0) {
            printf("Saved to '%s'\n", filename);
        }
        free(g_state.output_image);
        g_state.output_image = data;
        g_state.output_size = size;
    } else {
        printf("Download failed: %s\n", jtag_strerror(ret));
        free(data);
    }
}

static void cmd_show(const char *what) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    if (strcmp(what, "status") == 0) {
        dsa_print_status();
    } else if (strcmp(what, "config") == 0) {
        dsa_print_config();
    } else if (strcmp(what, "perf") == 0) {
        dsa_print_perf();
    } else if (strcmp(what, "all") == 0) {
        dsa_print_config();
        printf("\n");
        dsa_print_status();
        printf("\n");
        dsa_print_perf();
    } else {
        printf("Unknown: %s (use status, config, perf, all)\n", what);
    }
}

static void cmd_read(const char *addr_str) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    uint32_t offset = strtoul(addr_str, NULL, 0);
    uint32_t value;
    
    if (dsa_read_csr(offset, &value) == JTAG_OK) {
        printf("[0x%03X] = 0x%08X (%u)\n", offset, value, value);
    } else {
        printf("Read failed\n");
    }
}

static void cmd_write(const char *addr_str, const char *val_str) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    uint32_t offset = strtoul(addr_str, NULL, 0);
    uint32_t value = strtoul(val_str, NULL, 0);
    
    if (dsa_write_csr(offset, value) == JTAG_OK) {
        printf("[0x%03X] <- 0x%08X\n", offset, value);
    } else {
        printf("Write failed\n");
    }
}

/*===========================================================================
 * Command Parser
 *===========================================================================*/

static void trim(char *str) {
    char *start = str;
    while (*start && isspace(*start)) start++;
    if (start != str) memmove(str, start, strlen(start) + 1);
    
    char *end = str + strlen(str) - 1;
    while (end > str && isspace(*end)) *end-- = '\0';
}

static void process_command(char *line) {
    trim(line);
    if (line[0] == '\0' || line[0] == '#') return;

    char cmd[64] = "", arg1[256] = "", arg2[256] = "";
    sscanf(line, "%63s %255s %255s", cmd, arg1, arg2);

    /* Convert command to lowercase */
    for (char *p = cmd; *p; p++) *p = tolower(*p);

    if (strcmp(cmd, "help") == 0 || strcmp(cmd, "?") == 0) {
        cmd_help();
    } else if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "exit") == 0 || strcmp(cmd, "q") == 0) {
        cmd_disconnect();
        exit(0);
    } else if (strcmp(cmd, "connect") == 0) {
        cmd_connect();
    } else if (strcmp(cmd, "disconnect") == 0) {
        cmd_disconnect();
    } else if (strcmp(cmd, "set") == 0) {
        if (arg1[0] && arg2[0]) {
            cmd_set(arg1, arg2);
        } else {
            printf("Usage: set <param> <value>\n");
        }
    } else if (strcmp(cmd, "show") == 0) {
        if (arg1[0]) {
            cmd_show(arg1);
        } else {
            cmd_show("all");
        }
    } else if (strcmp(cmd, "run") == 0 || strcmp(cmd, "r") == 0) {
        cmd_run();
    } else if (strcmp(cmd, "step") == 0 || strcmp(cmd, "s") == 0) {
        cmd_step();
    } else if (strcmp(cmd, "continue") == 0 || strcmp(cmd, "c") == 0) {
        if (g_state.jtag.connected) {
            dsa_write_csr(CSR_CTRL, CTRL_START);
            printf("Continuing...\n");
        }
    } else if (strcmp(cmd, "abort") == 0) {
        cmd_abort();
    } else if (strcmp(cmd, "reset") == 0) {
        if (g_state.jtag.connected) {
            dsa_write_csr(CSR_CTRL, CTRL_RESET);
            dsa_write_csr(CSR_CTRL, 0);
            printf("Reset complete.\n");
        }
    } else if (strcmp(cmd, "load") == 0) {
        if (arg1[0]) {
            cmd_load(arg1);
        } else {
            printf("Usage: load <filename.pgm>\n");
        }
    } else if (strcmp(cmd, "dump") == 0) {
        if (arg1[0]) {
            cmd_dump(arg1);
        } else {
            printf("Usage: dump <filename.pgm>\n");
        }
    } else if (strcmp(cmd, "read") == 0) {
        if (arg1[0]) {
            cmd_read(arg1);
        } else {
            printf("Usage: read <offset_hex>\n");
        }
    } else if (strcmp(cmd, "write") == 0) {
        if (arg1[0] && arg2[0]) {
            cmd_write(arg1, arg2);
        } else {
            printf("Usage: write <offset_hex> <value_hex>\n");
        }
    } else if (strcmp(cmd, "verbose") == 0) {
        int v = atoi(arg1);
        jtag_set_verbose(&g_state.jtag, v);
        printf("Verbose mode: %s\n", v ? "ON" : "OFF");
    } else {
        printf("Unknown command: '%s'. Type 'help' for available commands.\n", cmd);
    }
}

/*===========================================================================
 * Main
 *===========================================================================*/

int main(int argc, char *argv[]) {
    printf("=== DSA Downscaler Console v1.0 ===\n");
    printf("Type 'help' for available commands.\n\n");

    /* Initialize defaults */
    g_state.scale = 0.5f;
    g_state.mode = MODE_SIMD;
    g_state.simd_lanes = DEFAULT_SIMD_LANES;

    /* Interactive loop */
    char line[512];
    while (1) {
        printf("dsa> ");
        fflush(stdout);

        if (fgets(line, sizeof(line), stdin) == NULL) {
            printf("\n");
            break;
        }

        process_command(line);
    }

    cmd_disconnect();
    free(g_state.input_image);
    free(g_state.output_image);

    return 0;
}
