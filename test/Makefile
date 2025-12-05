# Downscaler Testing Makefile
# Test-isolated version with all dependencies in test/ directory

.PHONY: all gen_images clean help sim_simd sim_serial sim_top setup

all: gen_images

# Setup work library
setup:
	@if [ ! -d "work" ]; then \
		echo "Creating work library..."; \
		vlib work; \
		vmap work work; \
	fi

# Generate test images from C reference
gen_images:
	@echo "Generating test images from C reference..."
	cd scripts && python3 generate_tests_from_c.py

# SIMD Downscaler Unit Test (LANES=4)
sim_simd: setup gen_images
	@echo "=== Running SIMD Downscaler Test (LANES=4) ==="
	vlog -sv rtl/simd_downscaler.sv
	vlog -sv tb/simd_downscaler_tb.sv
	vsim -c work.simd_downscaler_tb -do "run -all; quit -f"

# SIMD Downscaler with LANES=8
sim_simd_lanes8: setup gen_images
	@echo "=== Running SIMD Downscaler Test (LANES=8) ==="
	vlog -sv rtl/simd_downscaler.sv
	vlog -sv tb/downscaling_tb.sv
	vsim -c work.downscaling_tb -do "run -all; quit -f"

# Alias for compatibility
sim_serial: sim_simd_lanes8

# True Serial Downscaler (1 pixel/cycle, not SIMD)
sim_serial_true: setup gen_images
	@echo "=== Running True Serial Downscaler Test ==="
	vlog -sv rtl/downscaling_serial.sv
	vlog -sv tb/downscaling_serial_tb.sv
	vsim -c work.downscaling_serial_tb -do "run -all; quit -f"

# Validate Python/SystemVerilog reference against C reference (no file I/O)
validate_c_ref:
	@echo "=== Validating Python/SystemVerilog vs C Reference ==="
	@chmod +x scripts/validate_c_reference.py
	cd scripts && python3 validate_c_reference.py

# Top-level Integration Test
sim_top: setup gen_images
	@echo "=== Running Top-Level Integration Test ==="
	vlog -sv rtl/simd_downscaler.sv
	vlog -sv rtl/downscaling_serial.sv
	vlog -sv rtl/pixel_fetch_fsm.sv
	vlog -sv rtl/accelerator_csr_bridge.sv
	vlog -sv rtl/downscaler_top.sv
	vlog -sv tb/downscaler_top_tb.sv
	vsim -c work.downscaler_top_tb -L altera_mf_ver -do "run -all; quit -f"

# SIMD vs Serial Comparison Test
sim_compare: setup gen_images
	@echo "=== Comparing SIMD vs Serial Implementations ==="
	cd scripts && python3 compare_implementations.py

# Run all unit tests
test_units: sim_simd sim_simd_lanes8
	@echo ""
	@echo "========================================"
	@echo "All Unit Tests Complete!"
	@echo "========================================"
	@echo "Note: downscaling_serial tested via sim_top integration test"

# Run all tests
test_all: validate_c_ref test_units sim_top sim_compare

# Clean generated files
clean:
	rm -f transcript
	rm -f vsim.wlf
	rm -f sim_*.log
	rm -rf work/
	rm -f scripts/test_images/*.hex
	rm -f scripts/test_images/test_list.txt
	rm -f scripts/test_images/bilinear_ref
	rm -f scripts/test_images/gen_wrapper.c
	@echo "Cleaned simulation artifacts and test images"

# Help
help:
	@echo "Downscaler Testing Makefile (Test-Isolated Version)"
	@echo ""
	@echo "Unit Tests:"
	@echo "  make sim_simd          - SIMD downscaler (LANES=4, 5 tests)"
	@echo "  make sim_simd_lanes8   - SIMD downscaler (LANES=8, 7 tests)"
	@echo "  make sim_serial_true   - True serial downscaler (1 pixel/cycle)"
	@echo "  make test_units        - Run all unit tests"
	@echo ""
	@echo "Integration Tests:"
	@echo "  make sim_top           - Full system integration (3 tests)"
	@echo ""
	@echo "Validation:"
	@echo "  make validate_c_ref    - Validate Python/SV vs C reference"
	@echo "  make sim_compare       - Compare all implementations"
	@echo ""
	@echo "Complete:"
	@echo "  make test_all          - Run all tests sequentially"
	@echo ""
	@echo "Utilities:"
	@echo "  make gen_images        - Generate test images from C reference"
	@echo "  make setup             - Create work library"
	@echo "  make clean             - Remove generated files"
	@echo "  make help              - Show this help message"
	@echo ""
	@echo "Quick start:"
	@echo "  make sim_simd       # Test SIMD downscaler (working)"
	@echo "  make sim_top        # Test full integration"
	@echo ""
	@echo "For GUI debugging:"
	@echo "  make setup && make gen_images"
	@echo "  vlog -sv rtl/simd_downscaler.sv tb/simd_downscaler_tb.sv"
	@echo "  vsim -gui work.simd_downscaler_tb"
	@echo "  add wave -r /*"
	@echo "  run -all"
