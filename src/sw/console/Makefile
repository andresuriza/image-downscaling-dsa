# DSA Console Makefile for Windows (MinGW/GCC)
# For Visual Studio, use the .sln or compile manually

# Quartus installation path
QUARTUS_PATH = C:/intelFPGA_lite/20.1/quartus

# Compiler settings
CC = gcc
CFLAGS = -Wall -O2 -I. -I./validation
LDFLAGS = 

# Output
TARGET = dsa_console.exe

# Source files
SRCS = dsa_console.c jtag_comm.c validation/bilinear_reference.c
OBJS = $(SRCS:.c=.o)

# Default target
all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LDFLAGS)
	@echo "Build complete: $(TARGET)"

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Clean
clean:
	rm -f *.o validation/*.o $(TARGET)

# Dependencies
dsa_console.o: dsa_console.c dsa_registers.h jtag_comm.h validation/bilinear_reference.h
jtag_comm.o: jtag_comm.c jtag_comm.h
validation/bilinear_reference.o: validation/bilinear_reference.c validation/bilinear_reference.h

# Run
run: $(TARGET)
	./$(TARGET)

.PHONY: all clean run
