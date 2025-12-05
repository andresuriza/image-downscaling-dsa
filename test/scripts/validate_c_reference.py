#!/usr/bin/env python3

import ctypes
import sys
from pathlib import Path

def compile_c_reference():
    # Compila la referencia en C como una biblioteca compartida
    src_dir = Path("../c_reference")
    lib_path = Path("../libbilinear_ref.so")
    
    print("Compiling C reference library...")
    cmd = [
        "gcc",
        "-shared",
        "-fPIC",
        "-o", str(lib_path),
        str(src_dir / "bilinear_reference.c"),
        "-I", str(src_dir),
        "-lm",
        "-O2"
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: Failed to compile C reference:")
        print(f"Command: {' '.join(cmd)}")
        print(f"stderr: {result.stderr}")
        print(f"stdout: {result.stdout}")
        sys.exit(1)
    
    if not lib_path.exists():
        print(f"ERROR: Library {lib_path} was not created!")
        sys.exit(1)
    
    print(f"✓ C reference library compiled: {lib_path}")
    return lib_path

def bilinear_interpolate_python(p00, p01, p10, p11, frac_x, frac_y):
    # Realiza la interpolación bilineal en Python
    inv_fx = 256 - frac_x
    inv_fy = 256 - frac_y
    
    w00 = inv_fx * inv_fy
    w01 = frac_x * inv_fy
    w10 = inv_fx * frac_y
    w11 = frac_x * frac_y
    
    sum_val = w00 * p00 + w01 * p01 + w10 * p10 + w11 * p11
    result = (sum_val + 0x8000) >> 16
    
    return result & 0xFF

def test_bilinear_interpolation():
    # Prueba la interpolación bilineal contra los resultados esperados
    print("\n" + "="*60)
    print("Testing Bilinear Interpolation: Python Reference")
    print("="*60)
    
    test_cases = [
        (100, 150, 120, 170, 0, 0, "Esquina superior izquierda", 100),
        (100, 150, 120, 170, 255, 0, "Esquina superior derecha", 150),
        (100, 150, 120, 170, 0, 255, "Esquina inferior izquierda", 120),
        (100, 150, 120, 170, 255, 255, "Esquina inferior derecha", 170),
        (100, 150, 120, 170, 128, 128, "Centro", 135),
        (0, 255, 0, 255, 128, 128, "Mezcla de negro/blanco", 128),
        (255, 255, 255, 255, 128, 128, "Todo blanco", 255),
        (0, 0, 0, 0, 128, 128, "Todo negro", 0),
    ]
    
    passed = 0
    failed = 0
    
    for *pixels_and_fracs, desc, expected in test_cases:
        p00, p01, p10, p11, fx, fy = pixels_and_fracs
        py_result = bilinear_interpolate_python(p00, p01, p10, p11, fx, fy)
        
        if abs(py_result - expected) <= 1:
            print(f"✓ PASS: {desc}")
            passed += 1
        else:
            print(f"✗ FAIL: {desc}")
            failed += 1
    
    print("\n" + "="*60)
    print(f"Results: {passed} passed, {failed} failed")
    print("="*60)
    
    return failed == 0

def test_downscale_small_image():
    # Prueba la reducción de escala completa en una imagen pequeña
    lib_path = compile_c_reference()
    c_lib = ctypes.CDLL(str(lib_path.absolute()))
    
    c_lib.downscale_bilinear_sequential.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_uint32, ctypes.c_uint32,
        ctypes.c_uint32, ctypes.c_uint32,
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint64),
        ctypes.POINTER(ctypes.c_uint64),
        ctypes.POINTER(ctypes.c_uint64),
    ]
    c_lib.downscale_bilinear_sequential.restype = None
    
    print("\n" + "="*60)
    print("Testing Full Downscaling: Python vs C")
    print("="*60)
    
    # Casos de prueba adicionales aquí

if __name__ == "__main__":
    test_bilinear_interpolation()
    test_downscale_small_image()
