
#include "bilinear_reference.h"
#include <stdio.h>
#include <stdlib.h>

void save_hex(const char *filename, const uint8_t *data, int width, int height) {
    FILE *f = fopen(filename, "w");
    if (!f) {
        fprintf(stderr, "No se puede abrir %s\n", filename);
        exit(1);
    }
    for (int i = 0; i < width * height; i++) {
        fprintf(f, "%02X\n", data[i]);
    }
    fclose(f);
}

void generate_gradient(uint8_t *img, int width, int height) {
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            img[y * width + x] = ((x + y) * (256 / width)) & 0xFF;
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc != 6) {
        fprintf(stderr, "Uso: %s <in_w> <in_h> <out_w> <out_h> <basename>\n", argv[0]);
        return 1;
    }
    
    int in_w = atoi(argv[1]);
    int in_h = atoi(argv[2]);
    int out_w = atoi(argv[3]);
    int out_h = atoi(argv[4]);
    const char *basename = argv[5];
    
    uint8_t *input = malloc(in_w * in_h);
    uint8_t *output = malloc(out_w * out_h);
    
    generate_gradient(input, in_w, in_h);
    
    q8_8_t scale = (in_w << 8) / out_w;
    
    uint64_t flops, reads, writes;
    downscale_bilinear_sequential(input, output, in_w, in_h, out_w, out_h, 
                                   scale, &flops, &reads, &writes);
    
    char filename[256];
    snprintf(filename, sizeof(filename), "%s_input.hex", basename);
    save_hex(filename, input, in_w, in_h);
    
    snprintf(filename, sizeof(filename), "%s_expected.hex", basename);
    save_hex(filename, output, out_w, out_h);
    
    printf("Generado: %dx%d -> %dx%d (escala=%d)\n", in_w, in_h, out_w, out_h, scale);
    printf("  FLOPs: %llu, Lecturas: %llu, Escrituras: %llu\n", flops, reads, writes);
    
    free(input);
    free(output);
    return 0;
}
