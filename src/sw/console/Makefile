# DSA Console & Validation Tools Makefile for Windows (MinGW/GCC)
# Builds: dsa_console.exe, validate.exe, generate_images.exe

# Quartus installation path
QUARTUS_PATH = C:/intelFPGA_lite/20.1/quartus

# Compiler settings
CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c11 -I. -I./validation
LDFLAGS = -lm

# Output executables
CONSOLE_EXE = dsa_console.exe
VALIDATE_EXE = validation/validate.exe
GENERATE_EXE = validation/generate_images.exe

# Console source files
CONSOLE_SRCS = dsa_console.c jtag_comm.c validation/bilinear_reference.c
CONSOLE_OBJS = $(CONSOLE_SRCS:.c=.o)

# Validation tool source files
VALIDATE_SRCS = validation/validate.c validation/bilinear_reference.c
VALIDATE_OBJS = $(VALIDATE_SRCS:.c=.o)

# Image generator source files
GENERATE_SRCS = validation/generate_images.c validation/bilinear_reference.c
GENERATE_OBJS = $(GENERATE_SRCS:.c=.o)

# Default target - build everything
all: $(CONSOLE_EXE) $(VALIDATE_EXE) $(GENERATE_EXE)

# Console application
console: $(CONSOLE_EXE)

$(CONSOLE_EXE): $(CONSOLE_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: $(CONSOLE_EXE)"

# Validation tool
validate: $(VALIDATE_EXE)

$(VALIDATE_EXE): $(VALIDATE_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: $(VALIDATE_EXE)"

# Image generator
generate: $(GENERATE_EXE)

$(GENERATE_EXE): $(GENERATE_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: $(GENERATE_EXE)"

# Object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Dependencies
dsa_console.o: dsa_console.c dsa_registers.h jtag_comm.h validation/bilinear_reference.h
jtag_comm.o: jtag_comm.c jtag_comm.h
validation/bilinear_reference.o: validation/bilinear_reference.c validation/bilinear_reference.h
validation/validate.o: validation/validate.c validation/bilinear_reference.h
validation/generate_images.o: validation/generate_images.c validation/bilinear_reference.h

# Clean
clean:
	rm -f *.o validation/*.o $(CONSOLE_EXE) $(VALIDATE_EXE) $(GENERATE_EXE)

# Run console
run: $(CONSOLE_EXE)
	./$(CONSOLE_EXE)

# Clean generated images (test inputs and outputs)
clean-images:
	rm -f test_images/*.pgm test_results/*.pgm

# Generate test images and run validation
test: $(GENERATE_EXE) $(VALIDATE_EXE)
	@mkdir -p test_images test_results
	@echo "=== Generating test images in test_images/ ==="
	./$(GENERATE_EXE) test_images
	@echo ""
	@echo "=== Running validation (results in test_results/) ==="
	@for img in test_images/*.pgm; do \
		base=$$(basename $$img .pgm); \
		echo "Processing: $$base"; \
		./$(VALIDATE_EXE) --generate "$$img" "test_results/$${base}_ref.pgm" -s 0.5 -m sequential; \
	done
	@echo ""
	@echo "=== Test complete ==="

.PHONY: all console validate generate clean clean-images run test
