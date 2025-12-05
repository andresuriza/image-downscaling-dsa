# Test Images for Downscaler Verification

This directory contains test images and expected outputs for verifying the downscaler accelerator.

## Generate Test Images

Run the Python script to generate all test cases:

```bash
cd test_images
python3 generate_test_images.py
```

This creates:
- `*_input.hex` - Input images in hexadecimal format (one byte per line)
- `*_expected.hex` - Expected output images after downscaling
- `test_list.txt` - List of all test cases

## Test Patterns

1. **Gradient**: Smooth gradient pattern `(x+y) * scale`
2. **Checkerboard**: Alternating black/white squares
3. **Stripes**: Horizontal brightness stripes
4. **Ramp**: Linear horizontal brightness ramp

## File Format

Hex files contain one byte per line in hexadecimal format:
```
FF
00
7F
...
```

## Usage in Testbench

The testbench loads these files using `$fopen` and `$fscanf`:
```systemverilog
load_image_from_file("gradient_64x64_to_32x32_input.hex", 64, 64, input_image);
```

## Test Cases

| Input Size | Output Size | Pattern | Name |
|------------|-------------|---------|------|
| 8x8 | 4x4 | Gradient | gradient_8x8_to_4x4 |
| 16x16 | 8x8 | Gradient | gradient_16x16_to_8x8 |
| 32x32 | 16x16 | Gradient | gradient_32x32_to_16x16 |
| 64x64 | 32x32 | Gradient | gradient_64x64_to_32x32 |
| 128x128 | 64x64 | Gradient | gradient_128x128_to_64x64 |
| 256x256 | 128x128 | Gradient | gradient_256x256_to_128x128 |
| 512x512 | 256x256 | Gradient | gradient_512x512_to_256x256 |
| 320x240 | 160x120 | Gradient | gradient_320x240_to_160x120 |
| 64x64 | 32x32 | Checkerboard | checkerboard_64x64_to_32x32 |
| 128x128 | 64x64 | Checkerboard | checkerboard_128x128_to_64x64 |
| 64x64 | 32x32 | Stripes | stripes_64x64_to_32x32 |
| 128x128 | 64x64 | Ramp | ramp_128x128_to_64x64 |
