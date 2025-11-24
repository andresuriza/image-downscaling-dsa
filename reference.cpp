#include <iostream>
#include <vector>
#include <cstdint>
#include <cmath>

#define STB_IMAGE_WRITE_IMPLEMENTATION
// Reference lib used to save images as PNG files
// https://github.com/nothings/stb/blob/master/stb_image_write.h
#include "stb_image_write.h"

std::vector<std::vector<uint8_t>>
downscale_q88(const std::vector<std::vector<uint8_t>>& image, float scale)
 {
    int H = image.size();
    int W = image[0].size();

    int outH = static_cast<int>(H * scale);
    int outW = static_cast<int>(W * scale);

    std::vector<std::vector<uint8_t>> out(outH, std::vector<uint8_t>(outW));

    // Ratios en Q8.8
    const int Q = 8;
    const int ONE_Q = (1 << Q);

    int x_ratio_q = ((W - 1) << Q) / (outW - 1);
    int y_ratio_q = ((H - 1) << Q) / (outH - 1);

    for (int oy = 0; oy < outH; oy++) {
        for (int ox = 0; ox < outW; ox++) {

            // Coordenadas fuente en Q8.8
            int32_t x_q = ox * x_ratio_q; // Q8.8
            int32_t y_q = oy * y_ratio_q; // Q8.8

            // Parte entera
            int x_l = x_q >> Q;
            int y_l = y_q >> Q;

            if (x_l < 0) x_l = 0;
            if (y_l < 0) y_l = 0;
            if (x_l > W - 1) x_l = W - 1;
            if (y_l > H - 1) y_l = H - 1;

            int x_h = (x_l == W - 1) ? W - 1 : x_l + 1;
            int y_h = (y_l == H - 1) ? H - 1 : y_l + 1;

            // Partes fraccionales Q8.8
            int fx_q = x_q & 0xFF;
            int fy_q = y_q & 0xFF;

            int one_fx = ONE_Q - fx_q;
            int one_fy = ONE_Q - fy_q;

            // Pesos Q8.8
            int w00 = (one_fx * one_fy) >> Q;
            int w10 = (fx_q   * one_fy) >> Q;
            int w01 = (one_fx * fy_q  ) >> Q;
            int w11 = (fx_q   * fy_q  ) >> Q;

            // Cuatro vecinos
            uint8_t a = image[y_l][x_l];
            uint8_t b = image[y_l][x_h];
            uint8_t c = image[y_h][x_l];
            uint8_t d = image[y_h][x_h];

            // Productos (peso * pixel)
            int pa = w00 * a;
            int pb = w10 * b;
            int pc = w01 * c;
            int pd = w11 * d;

            // Suma
            int sum = pa + pb + pc + pd;

            // Redondeo Q8.8
            sum += (1 << (Q - 1)); // Round
            int pix = sum >> Q;

            if (pix > 255) pix = 255;

            out[oy][ox] = static_cast<uint8_t>(pix);
        }
    }

    return out;
}

void save_png(
    const std::vector<std::vector<uint8_t>>& img,
    const char* filename
) {
    int H = img.size();
    int W = img[0].size();

    std::vector<uint8_t> buffer(W * H);

    // Copiar 2D → 1D
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            buffer[y * W + x] = img[y][x];

    // Guardar como PNG (escala de grises)
    stbi_write_png(filename, W, H, 1, buffer.data(), W);
}


int main() {
    std::vector<std::vector<uint8_t>> img_4x4;
    std::vector<std::vector<uint8_t>> img_8x8;
    std::vector<std::vector<uint8_t>> img_16x16;

    
    img_4x4.resize(4);

    for (int y = 0; y < 4; y++) {
        img_4x4[y].resize(4);
    }

    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            img_4x4[y][x] = ((x * 64 + y * 32) & 0xFF);
        }
    }

    img_8x8.resize(8);

    for (int y = 0; y < 8; y++) {
        img_8x8[y].resize(8);
    }

    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            img_8x8[y][x] = ((x * 64 + y * 32) & 0xFF);
        }
    }

    img_16x16.resize(16);

    for (int y = 0; y < 16; y++) {
        img_16x16[y].resize(16);
    }

    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            img_16x16[y][x] = ((x * 64 + y * 32) & 0xFF);
        }
    }


    float scale = 0.5f;

    auto out = downscale_q88(img_4x4, scale);

    save_png(img_4x4,  "test-images/in.png");
    save_png(out,  "test-images/out.png");

    std::cout << "Imagen reducida (" << out.size() << "x" << out[0].size() << "):\n";
    for (auto& row : out) {
        for (auto v : row) std::cout << (int)v << " ";
        std::cout << "\n";
    }
    

    out = downscale_q88(img_8x8, scale);
    save_png(img_8x8,  "test-images/in.png");
    save_png(out,  "test-images/out.png");
    std::cout << "Imagen reducida (" << out.size() << "x" << out[0].size() << "):\n";
    for (auto& row : out) {
        for (auto v : row) std::cout << (int)v << " ";
        std::cout << "\n";
    }

    out = downscale_q88(img_16x16, scale);
    save_png(img_16x16,  "test-images/in.png");
    save_png(out,  "test-images/out.png");
    std::cout << "Imagen reducida (" << out.size() << "x" << out[0].size() << "):\n";
    for (auto& row : out) {
        for (auto v : row) std::cout << (int)v << " ";
        std::cout << "\n";
    }


    return 0;
}
