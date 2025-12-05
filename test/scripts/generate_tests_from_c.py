#!/usr/bin/env python3

import subprocess
import sys
import os
import numpy as np

def compile_c_reference():
    # Compila la implementación de referencia en C
    c_file = "../c_reference/bilinear_reference.c"
    h_file = "../c_reference/bilinear_reference.h"
    exe_file = "test_images/bilinear_ref"
    
    if not os.path.exists(c_file):
        print(f"ERROR: {c_file} no encontrado")
        return None
    
    wrapper_c = """
#include "bilinear_reference.h"
#include <stdio.h>
#include <stdlib.h>

void save_hex(const char *filename, const uint8_t *data, int width, int height) {
    FILE *f = fopen(filename, "w");
    if (!f) {
        fprintf(stderr, "No se puede abrir %s\\n", filename);
        exit(1);
    }
    for (int i = 0; i < width * height; i++) {
        fprintf(f, "%02X\\n", data[i]);
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
        fprintf(stderr, "Uso: %s <in_w> <in_h> <out_w> <out_h> <basename>\\n", argv[0]);
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
    
    printf("Generado: %dx%d -> %dx%d (escala=%d)\\n", in_w, in_h, out_w, out_h, scale);
    printf("  FLOPs: %llu, Lecturas: %llu, Escrituras: %llu\\n", flops, reads, writes);
    
    free(input);
    free(output);
    return 0;
}
"""
    
    wrapper_file = "test_images/gen_wrapper.c"
    with open(wrapper_file, 'w') as f:
        f.write(wrapper_c)
    
    cmd = [
        'gcc', '-O2', '-Wall',
        '-I', '../c_reference',
        wrapper_file,
        c_file,
        '-o', exe_file
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print("La compilación falló:")
        print(result.stderr)
        return None
    
    print(f"Compilado: {exe_file}")
    return exe_file

def generate_test_cases(exe_file):
    # Genera todos los casos de prueba usando la referencia en C
    test_cases = [
        (8, 8, 4, 4, "gradient_8x8_to_4x4"),
        (16, 16, 8, 8, "gradient_16x16_to_8x8"),
        (32, 32, 16, 16, "gradient_32x32_to_16x16"),
        (64, 64, 32, 32, "gradient_64x64_to_32x32"),
        (128, 128, 64, 64, "gradient_128x128_to_64x64"),
        (256, 256, 128, 128, "gradient_256x256_to_128x128"),
        (512, 512, 256, 256, "gradient_512x512_to_256x256"),
        (320, 240, 160, 120, "gradient_320x240_to_160x120"),
    ]
    
    os.chdir("test_images")
    
    for in_w, in_h, out_w, out_h, name in test_cases:
        cmd = [f"../{exe_file}", str(in_w), str(in_h), str(out_w), str(out_h), name]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error al generar {name}:")
            print(result.stderr)
        else:
            print(result.stdout.strip())
    
    os.chdir("..")

if __name__ == "__main__":
    print("Generando imágenes de prueba usando la implementación de referencia en C")
    print("=" * 60)
    
    exe = compile_c_reference()
    if exe:
        generate_test_cases(exe)
        print("=" * 60)
        print("¡Hecho! Imágenes de prueba generadas en test_images/")
