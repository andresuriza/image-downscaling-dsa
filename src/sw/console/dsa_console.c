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

#ifdef _WIN32
#include <windows.h>
#include <conio.h>  /* For _kbhit() */
#else
#include <unistd.h>
#include <sys/select.h>
#endif

#include "dsa_registers.h"
#include "jtag_comm.h"
#include "validation/bilinear_reference.h"

/*===========================================================================
 * Console State
 *===========================================================================*/
typedef struct {
    jtag_ctx_t jtag;
    uint32_t img_width;
    uint32_t img_height;
    float scale;
    int mode;           // 0=SIMD (4 lanes), 1=Serial
    bool configured;
    bool stepping_active; // Stepping mode is active
    uint32_t step_delay_us; // Delay between steps in microseconds (0 = use normal clock)
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
    int is_binary;
    
    if (fscanf(fp, "%2s", magic) != 1) {
        printf("Error: Cannot read PGM magic number\n");
        fclose(fp);
        return -1;
    }
    
    if (strcmp(magic, "P5") == 0) {
        is_binary = 1;
    } else if (strcmp(magic, "P2") == 0) {
        is_binary = 0;
    } else {
        printf("Error: Not a valid PGM file (expected P2 or P5, got %s)\n", magic);
        fclose(fp);
        return -1;
    }

    /* Skip whitespace and comments until we get to width */
    int c;
    for (;;) {
        /* Skip whitespace */
        while ((c = fgetc(fp)) != EOF && (c == ' ' || c == '\t' || c == '\n' || c == '\r'));
        if (c == EOF) break;
        
        if (c == '#') {
            /* Skip comment line */
            while ((c = fgetc(fp)) != EOF && c != '\n');
        } else {
            /* Found a non-comment character, put it back */
            ungetc(c, fp);
            break;
        }
    }

    if (fscanf(fp, "%d %d", &w, &h) != 2) {
        printf("Error: Invalid PGM header (width/height)\n");
        fclose(fp);
        return -1;
    }
    
    /* Skip whitespace and comments before maxval */
    for (;;) {
        while ((c = fgetc(fp)) != EOF && (c == ' ' || c == '\t' || c == '\n' || c == '\r'));
        if (c == EOF) break;
        
        if (c == '#') {
            while ((c = fgetc(fp)) != EOF && c != '\n');
        } else {
            ungetc(c, fp);
            break;
        }
    }
    
    if (fscanf(fp, "%d", &maxval) != 1) {
        printf("Error: Invalid PGM header (maxval)\n");
        fclose(fp);
        return -1;
    }
    
    /* Skip single whitespace after header (for P5) or any whitespace (for P2) */
    c = fgetc(fp);
    if (!is_binary) {
        while (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            c = fgetc(fp);
        }
        ungetc(c, fp);
    }

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

    if (is_binary) {
        /* P5: Binary format - read raw bytes */
        if (fread(*data, 1, size, fp) != size) {
            printf("Error: Failed to read image data\n");
            free(*data);
            *data = NULL;
            fclose(fp);
            return -1;
        }
    } else {
        /* P2: ASCII format - read decimal values */
        for (size_t i = 0; i < size; i++) {
            int val;
            if (fscanf(fp, "%d", &val) != 1) {
                printf("Error: Failed to read pixel %zu of %zu\n", i, size);
                free(*data);
                *data = NULL;
                fclose(fp);
                return -1;
            }
            (*data)[i] = (uint8_t)(val > 255 ? 255 : (val < 0 ? 0 : val));
        }
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

    printf("=== Configuration ===\n");
    printf("Version:  %d.%d\n", (version >> 24) & 0xFF, (version >> 16) & 0xFF);
    printf("Input:    %u x %u\n", in_w, in_h);
    printf("Output:   %u x %u\n", out_w, out_h);
    printf("Scale:    %.2f\n", Q8_8_TO_FLOAT(scale_q));
    printf("Mode:     %s\n", (mode & 1) ? "Serial" : "SIMD (4 lanes)");
}

static void dsa_print_perf(void) {
    uint32_t cycles_lo, cycles_hi, progress;
    uint32_t mem_rd_lo, mem_rd_hi, mem_wr_lo, mem_wr_hi;
    uint32_t flops_lo, flops_hi;

    if (dsa_read_csr(CSR_PERF_CYCLES_LO, &cycles_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_CYCLES_HI, &cycles_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_MEM_RD_LO, &mem_rd_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_MEM_RD_HI, &mem_rd_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_MEM_WR_LO, &mem_wr_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_MEM_WR_HI, &mem_wr_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_FLOPS_LO, &flops_lo) != JTAG_OK ||
        dsa_read_csr(CSR_PERF_FLOPS_HI, &flops_hi) != JTAG_OK ||
        dsa_read_csr(CSR_PROGRESS, &progress) != JTAG_OK) {
        printf("Error reading perf\n");
        return;
    }

    uint64_t cycles = ((uint64_t)cycles_hi << 32) | cycles_lo;
    uint64_t mem_reads = ((uint64_t)mem_rd_hi << 32) | mem_rd_lo;
    uint64_t mem_writes = ((uint64_t)mem_wr_hi << 32) | mem_wr_lo;
    uint64_t flops = ((uint64_t)flops_hi << 32) | flops_lo;
    
    uint32_t out_w = (uint32_t)(g_state.img_width * g_state.scale);
    uint32_t out_h = (uint32_t)(g_state.img_height * g_state.scale);
    uint32_t total = out_w * out_h;

    printf("=== Performance ===\n");
    printf("Cycles:      %llu\n", (unsigned long long)cycles);
    if (progress > 0) {
        printf("Cycles/px:   %.2f\n", (double)cycles / progress);
    }
    printf("FLOPs:       %llu", (unsigned long long)flops);
    if (cycles > 0) {
        printf(" (%.2f FLOPs/cycle)", (double)flops / cycles);
    }
    printf("\n");
    printf("Mem reads:   %llu\n", (unsigned long long)mem_reads);
    printf("Mem writes:  %llu\n", (unsigned long long)mem_writes);
    if (progress > 0) {
        double savings = 100.0 * (1.0 - (double)mem_reads / ((uint64_t)progress * 4));
        printf("Cache hit:   %.1f%%\n", savings);
    }
    if (progress > 0 && total > 0) {
        double est_ms = ((double)cycles / progress * total) / 50000.0;
        printf("Est. time:   %.2f ms @50MHz\n", est_ms);
    }
}

static const char* fsm_state_name(uint32_t state) {
    static const char* names[] = {
        "IDLE",       // 0 - S_IDLE
        "COMPUTE",    // 1 - S_COMPUTE (compute source coords)
        "FETCH",      // 2 - S_FETCH (fetch 4 neighbor pixels)
        "PROCESS",    // 3 - S_PROCESS (wait for downscaler)
        "WRITE",      // 4 - S_WRITE (write result)
        "NEXT",       // 5 - S_NEXT (advance to next pixel)
        "DONE",       // 6 - S_DONE
        "WAIT_STEP"   // 7 - S_WAIT_STEP (stepping mode pause)
    };
    if (state < sizeof(names)/sizeof(names[0])) {
        return names[state];
    }
    return "UNKNOWN";
}

static void dsa_print_debug(void) {
    if (!g_state.jtag.connected) {
        printf("Not connected\n");
        return;
    }
    
    uint32_t dbg_fsm = 0, dbg_out_y_reg = 0, status = 0, progress = 0, out_w = 0, out_h = 0;
    
    dsa_read_csr(CSR_STATUS, &status);
    dsa_read_csr(CSR_PROGRESS, &progress);
    dsa_read_csr(CSR_OUT_WIDTH, &out_w);
    dsa_read_csr(CSR_OUT_HEIGHT, &out_h);
    dsa_read_csr(CSR_DBG_FSM, &dbg_fsm);
    dsa_read_csr(CSR_DBG_OUT_Y, &dbg_out_y_reg);
    
    /* Read per-lane debug info */
    uint32_t lane_coord[4], lane_frac[4], lane_pix[4];
    dsa_read_csr(CSR_DBG_COORD, &lane_coord[0]);
    dsa_read_csr(CSR_DBG_FRAC, &lane_frac[0]);
    dsa_read_csr(CSR_DBG_PIXELS, &lane_pix[0]);
    dsa_read_csr(CSR_DBG_LANE1_COORD, &lane_coord[1]);
    dsa_read_csr(CSR_DBG_LANE1_FRAC, &lane_frac[1]);
    dsa_read_csr(CSR_DBG_LANE1_PIX, &lane_pix[1]);
    dsa_read_csr(CSR_DBG_LANE2_COORD, &lane_coord[2]);
    dsa_read_csr(CSR_DBG_LANE2_FRAC, &lane_frac[2]);
    dsa_read_csr(CSR_DBG_LANE2_PIX, &lane_pix[2]);
    dsa_read_csr(CSR_DBG_LANE3_COORD, &lane_coord[3]);
    dsa_read_csr(CSR_DBG_LANE3_FRAC, &lane_frac[3]);
    dsa_read_csr(CSR_DBG_LANE3_PIX, &lane_pix[3]);
    
    uint32_t total = out_w * out_h;
    uint32_t fsm = (dbg_fsm >> 16) & 0xF;
    uint32_t out_x = dbg_fsm & 0xFFFF;
    uint32_t out_y = dbg_out_y_reg & 0xFFFF;
    uint32_t num_lanes = (g_state.mode == MODE_SIMD) ? 4 : 1;
    float pct = (total > 0) ? (100.0f * progress / total) : 0.0f;
    
    printf("=== Debug ===\n");
    printf("Progress:  %u / %u (%.1f%%)\n", progress, total, pct);
    printf("Status:    %s%s\n", 
           fsm_state_name(fsm),
           (status & STATUS_DONE) ? " [DONE]" : ((status & STATUS_BUSY) ? " [BUSY]" : " [IDLE]"));
    printf("Output:    (%u, %u)\n", out_x, out_y);
    
    /* Print per-lane details */
    printf("Lanes:\n");
    for (uint32_t i = 0; i < num_lanes; i++) {
        uint32_t src_x = lane_coord[i] & 0xFFFF;
        uint32_t src_y = (lane_coord[i] >> 16) & 0xFFFF;
        uint32_t fx = lane_frac[i] & 0xFF;
        uint32_t fy = (lane_frac[i] >> 8) & 0xFF;
        uint32_t p00 = lane_pix[i] & 0xFF;
        uint32_t p01 = (lane_pix[i] >> 8) & 0xFF;
        uint32_t p10 = (lane_pix[i] >> 16) & 0xFF;
        uint32_t p11 = (lane_pix[i] >> 24) & 0xFF;
        
        printf("  L%u: src(%u,%u) frac(.%02X,.%02X) px[%3u %3u %3u %3u]\n",
               i, src_x, src_y, fx, fy, p00, p01, p10, p11);
    }
}

/*===========================================================================
 * Command Handlers
 *===========================================================================*/

static void cmd_help(void) {
    printf("\n=== DSA Console ===\n");
    printf("  connect / disconnect   JTAG connection\n");
    printf("  load <file.pgm>        Load input image\n");
    printf("  set scale <0.5-1.0>    Scale factor\n");
    printf("  set mode <simd|serial> Processing mode\n");
    printf("  set delay <us>         Step delay (0=fast clock)\n");
    printf("  run                    Start processing\n");
    printf("  step (s)               Single step\n");
    printf("  continue (c)           Continue stepping\n");
    printf("  reset                  Reset accelerator\n");
    printf("  dump <file.pgm>        Save output\n");
    printf("  compare [ref.pgm]      Validate vs C model\n");
    printf("  show config|perf|debug Show status\n");
    printf("  help / quit\n\n");
}

static void cmd_connect(void) {
    if (g_state.jtag.connected) {
        printf("Already connected\n");
        return;
    }

    printf("Connecting...\n");
    int ret = jtag_open(&g_state.jtag);
    if (ret == JTAG_OK) {
        uint32_t version;
        if (dsa_read_csr(CSR_VERSION, &version) == JTAG_OK) {
            printf("Connected (DSA v%d.%d)\n", 
                   (version >> 24) & 0xFF, (version >> 16) & 0xFF);
        } else {
            printf("Connected\n");
        }
    } else {
        printf("Failed: %s\n", jtag_strerror(ret));
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

    if (strcmp(param, "scale") == 0) {
        float s = atof(value);
        if (s < 0.5f || s > 1.0f) {
            printf("Invalid scale (0.5-1.0)\n");
            return;
        }
        
        /* Round to nearest 0.05 step */
        s = ((int)(s * 20 + 0.5f)) / 20.0f;
        
        /* Clamp after rounding */
        if (s < 0.5f) s = 0.5f;
        if (s > 1.0f) s = 1.0f;
        
        g_state.scale = s;
        uint32_t scale_q = FLOAT_TO_Q8_8(s);
        dsa_write_csr(CSR_SCALE_Q8_8, scale_q);
        
        /* Recalculate output dimensions when scale changes */
        uint32_t out_w = (uint32_t)(g_state.img_width * s);
        uint32_t out_h = (uint32_t)(g_state.img_height * s);
        dsa_write_csr(CSR_OUT_WIDTH, out_w);
        dsa_write_csr(CSR_OUT_HEIGHT, out_h);
        printf("Scale: %.2f -> %ux%u\n", s, out_w, out_h);
        
    } else if (strcmp(param, "mode") == 0) {
        if (strcmp(value, "simd") == 0 || strcmp(value, "SIMD") == 0) {
            g_state.mode = MODE_SIMD;
            dsa_write_csr(CSR_MODE, MODE_SIMD);
            printf("Mode: SIMD\n");
        } else if (strcmp(value, "serial") == 0 || strcmp(value, "SERIAL") == 0) {
            g_state.mode = MODE_SERIAL;
            dsa_write_csr(CSR_MODE, MODE_SERIAL);
            printf("Mode: Serial\n");
        } else {
            printf("Use 'simd' or 'serial'\n");
        }
        
    } else if (strcmp(param, "step_delay") == 0 || strcmp(param, "delay") == 0) {
        int delay = atoi(value);
        if (delay < 0) {
            printf("Invalid delay\n");
            return;
        }
        g_state.step_delay_us = (uint32_t)delay;
        printf("Delay: %uus %s\n", g_state.step_delay_us, delay ? "(stepping)" : "(fast clock)");
        
    } else {
        printf("Unknown parameter: %s\n", param);
    }
}

/* Cross-platform sleep function (microseconds) */
static void sleep_us(uint32_t us) {
#ifdef _WIN32
    /* Windows doesn't have usleep, use busy-wait for short delays */
    if (us == 0) return;
    if (us >= 1000) {
        Sleep(us / 1000);
    } else {
        /* For sub-millisecond, use QueryPerformanceCounter busy-wait */
        LARGE_INTEGER freq, start, now;
        QueryPerformanceFrequency(&freq);
        QueryPerformanceCounter(&start);
        double target = (double)us / 1000000.0 * freq.QuadPart;
        do {
            QueryPerformanceCounter(&now);
        } while ((now.QuadPart - start.QuadPart) < target);
    }
#else
    usleep(us);
#endif
}

/* Check if a key was pressed (non-blocking) */
static int key_pressed(void) {
#ifdef _WIN32
    return _kbhit();
#else
    struct timeval tv = {0, 0};
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(0, &fds);
    return select(1, &fds, NULL, NULL, &tv) > 0;
#endif
}

/* Run stepping loop until done or user abort */
static void stepping_loop(void) {
    uint32_t out_w = 0, out_h = 0, progress = 0, status = 0;
    dsa_read_csr(CSR_OUT_WIDTH, &out_w);
    dsa_read_csr(CSR_OUT_HEIGHT, &out_h);
    uint32_t total_pixels = out_w * out_h;
    uint32_t last_progress = 0;
    uint32_t step_count = 0;
    
    uint32_t batch_size = (g_state.step_delay_us >= 1000) ? 1 : 100;
    uint32_t status_check_interval = 100;
    
    while (1) {
        /* Send batch of step pulses */
        for (uint32_t i = 0; i < batch_size; i++) {
            dsa_write_csr(CSR_CTRL, CTRL_STEP_ENABLE | CTRL_STEP_ONCE);
            step_count++;
            
            if (g_state.step_delay_us >= 1000) {
                sleep_us(g_state.step_delay_us);
            }
        }
        
        /* Check status periodically */
        if (step_count % status_check_interval == 0 || step_count < 10) {
            dsa_read_csr(CSR_STATUS, &status);
            dsa_read_csr(CSR_PROGRESS, &progress);
            
            if (progress != last_progress) {
                float pct = (total_pixels > 0) ? (100.0f * progress / total_pixels) : 0.0f;
                printf("\rProgress: %u/%u (%.1f%%) - %u steps  ", 
                       progress, total_pixels, pct, step_count);
                fflush(stdout);
                last_progress = progress;
            }
            
            if (status & STATUS_DONE) {
                printf("\nComplete! %u steps\n", step_count);
                g_state.stepping_active = false;
                break;
            }
            
            if (key_pressed()) {
#ifdef _WIN32
                (void)_getch();
#else
                (void)getchar();
#endif
                printf("\nPaused at step %u (progress: %u/%u)\n", 
                       step_count, progress, total_pixels);
                break;
            }
        }
    }
}

static void cmd_run(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    /* Reset first */
    dsa_write_csr(CSR_CTRL, CTRL_RESET);
    dsa_write_csr(CSR_CTRL, 0);
    
    /* If step_delay is configured, use controlled stepping to avoid metastability */
    if (g_state.step_delay_us > 0) {
        printf("Running (stepping mode, press key to pause)...\n");
        
        /* Start in stepping mode */
        dsa_write_csr(CSR_CTRL, CTRL_START | CTRL_STEP_ENABLE);
        g_state.stepping_active = true;
        
        stepping_loop();
    } else {
        /* Normal run with system clock (use 'step' command for stepping mode) */
        dsa_write_csr(CSR_CTRL, CTRL_START);
        g_state.stepping_active = false;
        printf("Started processing (normal clock mode)...\n");
    }
}

static void cmd_step(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    /* Check if stepping is active */
    if (!g_state.stepping_active) {
        /* Not in stepping mode - start in stepping mode */
        dsa_write_csr(CSR_CTRL, CTRL_RESET);
        dsa_write_csr(CSR_CTRL, 0);
        dsa_write_csr(CSR_CTRL, CTRL_START | CTRL_STEP_ENABLE);
        g_state.stepping_active = true;
        printf("Stepping mode started.\n");
    } else {
        /* Already in stepping mode - send step pulse */
        dsa_write_csr(CSR_CTRL, CTRL_STEP_ENABLE | CTRL_STEP_ONCE);
    }
    
    /* Read essential debug info */
    uint32_t dbg_fsm = 0, dbg_out_y_reg = 0, progress = 0, out_w = 0, out_h = 0, status = 0;
    
    dsa_read_csr(CSR_STATUS, &status);
    dsa_read_csr(CSR_PROGRESS, &progress);
    dsa_read_csr(CSR_OUT_WIDTH, &out_w);
    dsa_read_csr(CSR_OUT_HEIGHT, &out_h);
    dsa_read_csr(CSR_DBG_FSM, &dbg_fsm);
    dsa_read_csr(CSR_DBG_OUT_Y, &dbg_out_y_reg);
    
    /* Read per-lane debug info */
    uint32_t lane_coord[4], lane_frac[4], lane_pix[4];
    dsa_read_csr(CSR_DBG_COORD, &lane_coord[0]);
    dsa_read_csr(CSR_DBG_FRAC, &lane_frac[0]);
    dsa_read_csr(CSR_DBG_PIXELS, &lane_pix[0]);
    dsa_read_csr(CSR_DBG_LANE1_COORD, &lane_coord[1]);
    dsa_read_csr(CSR_DBG_LANE1_FRAC, &lane_frac[1]);
    dsa_read_csr(CSR_DBG_LANE1_PIX, &lane_pix[1]);
    dsa_read_csr(CSR_DBG_LANE2_COORD, &lane_coord[2]);
    dsa_read_csr(CSR_DBG_LANE2_FRAC, &lane_frac[2]);
    dsa_read_csr(CSR_DBG_LANE2_PIX, &lane_pix[2]);
    dsa_read_csr(CSR_DBG_LANE3_COORD, &lane_coord[3]);
    dsa_read_csr(CSR_DBG_LANE3_FRAC, &lane_frac[3]);
    dsa_read_csr(CSR_DBG_LANE3_PIX, &lane_pix[3]);
    
    uint32_t total_pixels = out_w * out_h;
    uint32_t fsm_state = (dbg_fsm >> 16) & 0xF;
    uint32_t out_x = dbg_fsm & 0xFFFF;
    uint32_t out_y = dbg_out_y_reg & 0xFFFF;
    uint32_t num_lanes = (g_state.mode == MODE_SIMD) ? 4 : 1;
    
    /* Print header with progress, output coords */
    printf("[%u/%u] out(%u,%u) | %s\n",
           progress, total_pixels, out_x, out_y, fsm_state_name(fsm_state));
    
    /* Print per-lane details */
    for (uint32_t i = 0; i < num_lanes; i++) {
        uint32_t src_x = lane_coord[i] & 0xFFFF;
        uint32_t src_y = (lane_coord[i] >> 16) & 0xFFFF;
        uint32_t frac_x = lane_frac[i] & 0xFF;
        uint32_t frac_y = (lane_frac[i] >> 8) & 0xFF;
        uint32_t p00 = lane_pix[i] & 0xFF;
        uint32_t p01 = (lane_pix[i] >> 8) & 0xFF;
        uint32_t p10 = (lane_pix[i] >> 16) & 0xFF;
        uint32_t p11 = (lane_pix[i] >> 24) & 0xFF;
        
        printf("  L%u: src(%u,%u)+(.%02X,.%02X) p[%3u %3u %3u %3u]\n",
               i, src_x, src_y, frac_x, frac_y, p00, p01, p10, p11);
    }
    
    /* Check if done */
    if (status & STATUS_DONE) {
        printf("Done!\n");
        g_state.stepping_active = false;
    }
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

    /* Write scale */
    uint32_t scale_q = FLOAT_TO_Q8_8(g_state.scale);
    dsa_write_csr(CSR_SCALE_Q8_8, scale_q);

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

static void cmd_verify(void) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    if (!g_state.input_image || g_state.input_size == 0) {
        printf("Error: No input image loaded. Use 'load <file>' first.\n");
        return;
    }

    size_t size = g_state.input_size;
    uint8_t *readback = (uint8_t*)malloc(size);
    if (!readback) {
        printf("Error: Out of memory\n");
        return;
    }

    printf("Reading back from FPGA SDRAM at 0x%08X...\n", DEFAULT_IMG_IN_ADDR);
    int ret = jtag_read_block(&g_state.jtag, DEFAULT_IMG_IN_ADDR, readback, size);

    if (ret != JTAG_OK) {
        printf("Read failed: %s\n", jtag_strerror(ret));
        free(readback);
        return;
    }

    /* Compare byte by byte */
    uint32_t mismatch_count = 0;
    uint32_t first_mismatch_idx = 0;
    uint8_t first_expected = 0, first_got = 0;

    for (size_t i = 0; i < size; i++) {
        if (g_state.input_image[i] != readback[i]) {
            if (mismatch_count == 0) {
                first_mismatch_idx = (uint32_t)i;
                first_expected = g_state.input_image[i];
                first_got = readback[i];
            }
            mismatch_count++;
        }
    }

    printf("\n=== SDRAM Verification Results ===\n");
    printf("Image size:    %zu bytes\n", size);
    printf("Dimensions:    %u x %u\n", g_state.img_width, g_state.img_height);

    if (mismatch_count == 0) {
        printf("Result:        \033[32mPASS\033[0m - All bytes match!\n");
    } else {
        printf("Result:        \033[31mFAIL\033[0m\n");
        printf("Mismatches:    %u / %zu (%.2f%%)\n", 
               mismatch_count, size, 100.0 * mismatch_count / size);
        printf("First error at byte %u: expected 0x%02X, got 0x%02X\n",
               first_mismatch_idx, first_expected, first_got);
        
        /* Show first few mismatches */
        printf("\nFirst mismatches:\n");
        int shown = 0;
        for (size_t i = 0; i < size && shown < 5; i++) {
            if (g_state.input_image[i] != readback[i]) {
                uint32_t x = (uint32_t)(i % g_state.img_width);
                uint32_t y = (uint32_t)(i / g_state.img_width);
                printf("  [%u,%u] (byte %zu): expected %u, got %u\n",
                       x, y, i, g_state.input_image[i], readback[i]);
                shown++;
            }
        }
    }

    free(readback);
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

static void cmd_compare(const char *reference_file) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    if (g_state.img_width == 0 || g_state.img_height == 0) {
        printf("Error: Image dimensions not set. Load an image first.\n");
        return;
    }

    if (!g_state.input_image) {
        printf("Error: No input image loaded. Use 'load <file>' first.\n");
        return;
    }

    /* Calculate output dimensions */
    uint32_t out_w = (uint32_t)(g_state.img_width * g_state.scale);
    uint32_t out_h = (uint32_t)(g_state.img_height * g_state.scale);
    size_t out_size = out_w * out_h;

    /* Download FPGA output from SDRAM */
    uint8_t *fpga_output = (uint8_t*)malloc(out_size);
    if (!fpga_output) {
        printf("Error: Out of memory\n");
        return;
    }

    printf("Downloading FPGA output from SDRAM at 0x%08X...\n", DEFAULT_IMG_OUT_ADDR);
    int ret = jtag_read_block(&g_state.jtag, DEFAULT_IMG_OUT_ADDR, fpga_output, out_size);
    if (ret != JTAG_OK) {
        printf("Download failed: %s\n", jtag_strerror(ret));
        free(fpga_output);
        return;
    }
    printf("Download complete (%zu bytes)\n", out_size);

    /* Generate reference image using C model */
    uint8_t *reference = (uint8_t*)malloc(out_size);
    if (!reference) {
        printf("Error: Out of memory\n");
        free(fpga_output);
        return;
    }

    printf("Generating reference image using C model...\n");
    q8_8_t scale_q8_8 = float_to_q8_8(g_state.scale);
    
    uint64_t flops = 0, mem_reads = 0, mem_writes = 0;
    
    if (g_state.mode == MODE_SIMD) {
        downscale_bilinear_simd(
            g_state.input_image, reference,
            g_state.img_width, g_state.img_height,
            out_w, out_h,
            scale_q8_8,
            SIMD_LANES,  /* Fixed at 4 lanes */
            &flops, &mem_reads, &mem_writes
        );
    } else {
        downscale_bilinear_sequential(
            g_state.input_image, reference,
            g_state.img_width, g_state.img_height,
            out_w, out_h,
            scale_q8_8,
            &flops, &mem_reads, &mem_writes
        );
    }

    /* Save reference image if filename provided */
    if (reference_file && strlen(reference_file) > 0) {
        if (save_pgm_image(reference_file, reference, out_w, out_h) == 0) {
            printf("Reference saved to: %s\n", reference_file);
        }
    }

    /* Compare images */
    uint32_t max_diff = 0, diff_count = 0, first_x = 0, first_y = 0;
    int mismatch = compare_images(
        reference, fpga_output,
        out_w, out_h,
        &max_diff, &diff_count, &first_x, &first_y
    );

    /* Print results */
    printf("\n=== DSA Validation Results ===\n");
    printf("Input:       %u x %u\n", g_state.img_width, g_state.img_height);
    printf("Output:      %u x %u\n", out_w, out_h);
    printf("Scale:       %.4f (Q8.8: 0x%04X)\n", g_state.scale, scale_q8_8);
    printf("Mode:        %s", g_state.mode == MODE_SIMD ? "SIMD" : "Sequential");
    if (g_state.mode == MODE_SIMD) {
        printf(" (%d lanes)", SIMD_LANES);
    }
    printf("\n\n");

    if (!mismatch) {
        printf("Result: \033[32mPASS\033[0m - Bit-exact match!\n");
    } else {
        printf("Result: \033[31mFAIL\033[0m\n");
        printf("  Differing pixels: %u / %u (%.2f%%)\n", 
               diff_count, out_w * out_h,
               100.0 * diff_count / (out_w * out_h));
        printf("  Maximum difference: %u\n", max_diff);
        printf("  First difference at: (%u, %u)\n", first_x, first_y);
        
        /* Show first few differing pixels */
        printf("\nFirst differences:\n");
        int shown = 0;
        for (uint32_t y = 0; y < out_h && shown < 5; y++) {
            for (uint32_t x = 0; x < out_w && shown < 5; x++) {
                uint32_t idx = y * out_w + x;
                if (reference[idx] != fpga_output[idx]) {
                    printf("  [%u,%u]: ref=%u, fpga=%u, diff=%d\n",
                           x, y, reference[idx], fpga_output[idx],
                           (int)fpga_output[idx] - (int)reference[idx]);
                    shown++;
                }
            }
        }
    }

    /* Reference model stats */
    printf("\nReference model stats:\n");
    printf("  FLOPs:        %llu\n", (unsigned long long)flops);
    printf("  Memory reads: %llu\n", (unsigned long long)mem_reads);
    printf("  Memory writes: %llu\n", (unsigned long long)mem_writes);

    free(reference);
    free(fpga_output);
}

static void cmd_show(const char *what) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    if (strcmp(what, "config") == 0) {
        dsa_print_config();
    } else if (strcmp(what, "perf") == 0) {
        dsa_print_perf();
    } else if (strcmp(what, "debug") == 0) {
        dsa_print_debug();
    } else if (strcmp(what, "all") == 0) {
        dsa_print_config();
        printf("\n");
        dsa_print_perf();
        printf("\n");
        dsa_print_debug();
    } else {
        printf("Unknown: %s (use config, perf, debug, all)\n", what);
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

static void cmd_mem(const char *addr_str, const char *count_str) {
    if (!g_state.jtag.connected) {
        printf("Error: Not connected.\n");
        return;
    }

    uint32_t addr = strtoul(addr_str, NULL, 0);
    uint32_t count = count_str[0] ? strtoul(count_str, NULL, 0) : 16;
    
    /* Limit count to reasonable value */
    if (count > 256) count = 256;
    if (count == 0) count = 16;
    
    uint8_t *data = (uint8_t*)malloc(count);
    if (!data) {
        printf("Error: Out of memory\n");
        return;
    }
    
    int ret = jtag_read_block(&g_state.jtag, addr, data, count);
    if (ret != JTAG_OK) {
        printf("Read failed: %s\n", jtag_strerror(ret));
        free(data);
        return;
    }
    
    /* Print hex dump */
    printf("Memory at 0x%08X (%u bytes):\n", addr, count);
    for (uint32_t i = 0; i < count; i += 16) {
        printf("  %08X: ", addr + i);
        
        /* Hex bytes */
        for (uint32_t j = 0; j < 16 && (i + j) < count; j++) {
            printf("%02X ", data[i + j]);
            if (j == 7) printf(" ");
        }
        
        /* Padding if last line is incomplete */
        for (uint32_t j = count - i; j < 16; j++) {
            printf("   ");
            if (j == 7) printf(" ");
        }
        
        /* ASCII */
        printf(" |");
        for (uint32_t j = 0; j < 16 && (i + j) < count; j++) {
            char c = data[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
    
    free(data);
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
        if (g_state.jtag.connected && g_state.stepping_active) {
            printf("Continuing (press key to pause)...\n");
            stepping_loop();
        } else if (g_state.jtag.connected) {
            printf("Not in stepping mode. Use 'run' to start.\n");
        }
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
    } else if (strcmp(cmd, "verify") == 0) {
        cmd_verify();
    } else if (strcmp(cmd, "dump") == 0) {
        if (arg1[0]) {
            cmd_dump(arg1);
        } else {
            printf("Usage: dump <filename.pgm>\n");
        }
    } else if (strcmp(cmd, "compare") == 0) {
        /* arg1 is optional - if provided, saves reference to that file */
        cmd_compare(arg1[0] ? arg1 : NULL);
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
    } else if (strcmp(cmd, "mem") == 0) {
        if (arg1[0]) {
            cmd_mem(arg1, arg2);
        } else {
            printf("Usage: mem <address> [count]\n");
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
    (void)argc;
    (void)argv;
    
    printf("DSA Console v1.0 - Type 'help' for commands\n");

    /* Initialize defaults */
    g_state.scale = 0.5f;
    g_state.mode = MODE_SIMD;
    g_state.step_delay_us = 1;  /* Default: 1us (JTAG overhead dominates, this just enables stepping mode) */

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
