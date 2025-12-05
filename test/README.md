# Test Directory

This directory contains all testbench-related files for verifying the downscaler implementations.

## Structure

```
test/
├── Makefile              # Test-specific Makefile
├── libbilinear_ref.so    # C reference library (compiled)
├── c_reference/          # C reference implementation (self-contained)
│   ├── bilinear_reference.c
│   ├── bilinear_reference.h
│   ├── generate_images.c
│   └── validate.c
├── rtl/                  # RTL modules used for testing
│   ├── simd_downscaler.sv
│   ├── downscaling_serial.sv
│   ├── pixel_fetch_fsm.sv
│   ├── accelerator_csr_bridge.sv
│   └── downscaler_top.sv
├── tb/                   # Testbenches
│   ├── simd_downscaler_tb.sv
│   ├── downscaling_tb.sv
│   ├── downscaling_serial_tb.sv
│   └── downscaler_top_tb.sv
└── scripts/              # Python test scripts
    ├── compare_implementations.py
    ├── validate_c_reference.py
    ├── generate_tests_from_c.py
    └── test_images/      # Generated test data (auto-created)
```

## Usage

All testing should be done from this directory:

```bash
cd test/
make test_all          # Run all tests
make sim_simd          # Test SIMD (LANES=4)
make sim_simd_lanes8   # Test SIMD (LANES=8)
make sim_top           # Test full integration
make sim_compare       # Compare all implementations
make validate_c_ref    # Validate against C reference
```

## Test Results

- **SIMD (LANES=4)**: 5/5 tests passed
- **SIMD (LANES=8)**: 7/7 tests passed  
- **Serial (via integration)**: 4/4 tests passed
  - CSR Register Access
  - 8x8 → 4x4 Basic Downscale (SIMD mode)
  - 16x16 → 8x8 Serial Module Test
  - 4x4 → 2x2 Stepping Mode

All implementations produce functionally equivalent results, validated bit-by-bit against the C reference.

## Notes

- **Self-Contained**: This directory has everything needed for testing - no external dependencies on src/
- The RTL files in `test/rtl/` are copies used for simulation only
- The C reference in `test/c_reference/` is included locally
- Production/FPGA files remain in `src/rtl/` (if present)
- Test artifacts (work/, transcript, etc.) are created in the test/ directory
- The test directory can work independently even if src/ is deleted or relocated
