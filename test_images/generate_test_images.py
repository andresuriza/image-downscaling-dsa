#!/usr/bin/env python3
"""
Generate test images and expected outputs for downscaler verification.
Creates .hex files that can be loaded by ModelSim $readmemh.
"""

import numpy as np
import sys

def bilinear_interpolate_q8_8(p00, p01, p10, p11, frac_x, frac_y, Q=8):
    """Reference bilinear interpolation matching RTL (Q8.8 fixed-point)."""
    ONE_Q = 1 << Q  # 256 for Q=8
    
    # Use int for intermediate calculations
    w00 = int((ONE_Q - frac_x) * (ONE_Q - frac_y))
    w01 = int(frac_x * (ONE_Q - frac_y))
    w10 = int((ONE_Q - frac_x) * frac_y)
    w11 = int(frac_x * frac_y)
    
    sum_val = int((w00 * int(p00)) + (w01 * int(p01)) + (w10 * int(p10)) + (w11 * int(p11)))
    
    # Round to nearest (add half before shift)
    result = (sum_val + (1 << (2*Q - 1))) >> (2*Q)
    
    # Clamp to [0, 255]
    return int(np.clip(result, 0, 255))

def downscale_image(img_in, out_width, out_height, Q=8):
    """Downscale image using bilinear interpolation (Q8.8 fixed-point)."""
    in_height, in_width = img_in.shape
    img_out = np.zeros((out_height, out_width), dtype=np.uint8)
    
    scale_q8_8 = (in_width << Q) // out_width
    
    for out_y in range(out_height):
        for out_x in range(out_width):
            # Calculate source position in Q8.8
            src_x_q8 = out_x * scale_q8_8
            src_y_q8 = out_y * scale_q8_8
            
            # Extract integer and fractional parts
            src_x_int = src_x_q8 >> Q
            src_y_int = src_y_q8 >> Q
            frac_x = src_x_q8 & ((1 << Q) - 1)
            frac_y = src_y_q8 & ((1 << Q) - 1)
            
            # Get neighbor coordinates with clamping
            x0, y0 = src_x_int, src_y_int
            x1 = min(src_x_int + 1, in_width - 1)
            y1 = min(src_y_int + 1, in_height - 1)
            
            # Fetch 4 neighbors
            p00 = img_in[y0, x0]
            p01 = img_in[y0, x1]
            p10 = img_in[y1, x0]
            p11 = img_in[y1, x1]
            
            # Interpolate
            img_out[out_y, out_x] = bilinear_interpolate_q8_8(
                p00, p01, p10, p11, frac_x, frac_y, Q
            )
    
    return img_out

def save_image_hex(img, filename):
    """Save image as hex file (one byte per line) for $readmemh."""
    height, width = img.shape
    with open(filename, 'w') as f:
        for y in range(height):
            for x in range(width):
                f.write(f"{img[y, x]:02X}\n")
    print(f"Saved {filename}: {width}x{height} = {width*height} bytes")

def generate_gradient(width, height):
    """Generate gradient test pattern."""
    img = np.zeros((height, width), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            img[y, x] = ((x + y) * (256 // width)) & 0xFF
    return img

def generate_checkerboard(width, height, square_size=8):
    """Generate checkerboard pattern."""
    img = np.zeros((height, width), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            if ((x // square_size) + (y // square_size)) % 2 == 0:
                img[y, x] = 255
    return img

def generate_horizontal_stripes(width, height, stripe_height=16):
    """Generate horizontal stripes."""
    img = np.zeros((height, width), dtype=np.uint8)
    for y in range(height):
        img[y, :] = 255 if (y // stripe_height) % 2 == 0 else 0
    return img

def generate_ramp(width, height):
    """Generate horizontal brightness ramp."""
    img = np.zeros((height, width), dtype=np.uint8)
    for x in range(width):
        img[:, x] = int((x / width) * 255)
    return img

def main():
    test_cases = [
        # (in_width, in_height, out_width, out_height, pattern_func, name)
        (8, 8, 4, 4, generate_gradient, "gradient_8x8_to_4x4"),
        (16, 16, 8, 8, generate_gradient, "gradient_16x16_to_8x8"),
        (32, 32, 16, 16, generate_gradient, "gradient_32x32_to_16x16"),
        (64, 64, 32, 32, generate_gradient, "gradient_64x64_to_32x32"),
        (128, 128, 64, 64, generate_gradient, "gradient_128x128_to_64x64"),
        (256, 256, 128, 128, generate_gradient, "gradient_256x256_to_128x128"),
        (512, 512, 256, 256, generate_gradient, "gradient_512x512_to_256x256"),
        (320, 240, 160, 120, generate_gradient, "gradient_320x240_to_160x120"),
        
        # Checkerboard patterns
        (64, 64, 32, 32, generate_checkerboard, "checkerboard_64x64_to_32x32"),
        (128, 128, 64, 64, generate_checkerboard, "checkerboard_128x128_to_64x64"),
        
        # Stripe patterns
        (64, 64, 32, 32, generate_horizontal_stripes, "stripes_64x64_to_32x32"),
        
        # Ramp patterns
        (128, 128, 64, 64, generate_ramp, "ramp_128x128_to_64x64"),
    ]
    
    print("Generating test images and expected outputs...")
    print("=" * 60)
    
    for in_w, in_h, out_w, out_h, pattern_func, name in test_cases:
        # Generate input image
        img_in = pattern_func(in_w, in_h)
        
        # Generate expected output
        img_out = downscale_image(img_in, out_w, out_h)
        
        # Save as hex files
        save_image_hex(img_in, f"{name}_input.hex")
        save_image_hex(img_out, f"{name}_expected.hex")
        
        print(f"  {name}: {in_w}x{in_h} -> {out_w}x{out_h}")
    
    print("=" * 60)
    print(f"Generated {len(test_cases)} test cases")
    
    # Create test list file
    with open("test_list.txt", 'w') as f:
        for in_w, in_h, out_w, out_h, _, name in test_cases:
            f.write(f"{in_w} {in_h} {out_w} {out_h} {name}\n")
    print("Created test_list.txt")

if __name__ == "__main__":
    main()
