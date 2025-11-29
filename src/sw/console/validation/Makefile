# Makefile for DSA Downscaler Validation Tools
# Compiles C reference model and validation tool

CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c11
LDFLAGS = -lm

# Source files
VALIDATE_SRCS = validate.c bilinear_reference.c
VALIDATE_OBJS = $(VALIDATE_SRCS:.c=.o)
VALIDATE_EXE = validate.exe

GENERATE_SRCS = generate_images.c bilinear_reference.c
GENERATE_OBJS = $(GENERATE_SRCS:.c=.o)
GENERATE_EXE = generate_images.exe

# Default target
all: $(VALIDATE_EXE) $(GENERATE_EXE)

# Validation tool
$(VALIDATE_EXE): $(VALIDATE_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: $(VALIDATE_EXE)"

# Image generator
$(GENERATE_EXE): $(GENERATE_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: $(GENERATE_EXE)"

# Object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Dependencies
validate.o: validate.c bilinear_reference.h
bilinear_reference.o: bilinear_reference.c bilinear_reference.h
generate_images.o: generate_images.c bilinear_reference.h

# Clean
clean:
	rm -f *.o $(VALIDATE_EXE) $(GENERATE_EXE)

# Test - generate reference images and run validation
test: $(VALIDATE_EXE)
	@echo "=== Generating reference image ==="
	./$(VALIDATE_EXE) --generate ../test_images/gradient_8x8.pgm reference_8x8.pgm -s 0.5 -v
	@echo ""
	@echo "=== Running validation test ==="
	./$(VALIDATE_EXE) ../test_images/gradient_8x8.pgm reference_8x8.pgm -s 0.5 -v

.PHONY: all clean test
