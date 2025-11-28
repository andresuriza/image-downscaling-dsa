/*
 * JTAG Communication Layer
 * Uses Intel Quartus system-console via subprocess (for simplicity)
 * Alternative: Link directly with jtag_atlantic library
 */

#ifndef JTAG_COMM_H
#define JTAG_COMM_H

#include <stdint.h>
#include <stdbool.h>

/* Return codes */
#define JTAG_OK             0
#define JTAG_ERR_OPEN       -1
#define JTAG_ERR_WRITE      -2
#define JTAG_ERR_READ       -3
#define JTAG_ERR_TIMEOUT    -4
#define JTAG_ERR_NOT_OPEN   -5

/* Master path for DE1-SoC Cyclone V */
#define DEFAULT_MASTER_PATH "/devices/5CSE(BA5|MA5)|5CSTFD5D5|..@2#USB-1#DE-SoC/(link)/JTAG/(110:132 v1 #0)/phy_0/master"

/* Quartus installation path */
#ifndef QUARTUS_PATH
#define QUARTUS_PATH "C:\\intelFPGA_lite\\20.1\\quartus"
#endif

/* JTAG context structure */
typedef struct {
    bool connected;
    char master_path[512];
    char quartus_path[512];
    int verbose;
} jtag_ctx_t;

/* Connection management */
int jtag_open(jtag_ctx_t *ctx);
void jtag_close(jtag_ctx_t *ctx);
bool jtag_is_connected(jtag_ctx_t *ctx);

/* Read/Write operations */
int jtag_read_32(jtag_ctx_t *ctx, uint32_t addr, uint32_t *value);
int jtag_write_32(jtag_ctx_t *ctx, uint32_t addr, uint32_t value);

/* Bulk operations for images */
int jtag_read_block(jtag_ctx_t *ctx, uint32_t addr, uint8_t *data, size_t len);
int jtag_write_block(jtag_ctx_t *ctx, uint32_t addr, const uint8_t *data, size_t len);

/* Utility */
const char* jtag_strerror(int err);
void jtag_set_verbose(jtag_ctx_t *ctx, int level);

#endif /* JTAG_COMM_H */
