# Image downscaling hardware accelerator

A hardware acclerator designed to be synthesized on a De1-SoC FPGA for the purpose of applying an image downscaling algorithm with a SIMD processor architecture. It is part of a team project made for the class: Arquitectura de Computadores II.

## Technologies

- `SystemVerilog`
- `C++`
- `Python`
- `ModelSim`

## Features

You will find various tools like:

- **Accelerator CPU**: with this CPU that runs on the FPGA you will be able to apply downscaling to an image to your desired resolution, using sequential or parallel mode.
  
- **Testbenches**: you will be able to extensively test the functionality of the design to verify that it functions properly, as well as try out various input image scenarios.
  
- **Reference model to visualize results**: tool available if you don't have a ready FPGA and just want to preview the resulting image or have a reference before you apply the algorithm using the accelerator.

## The process

Understanding the bilinear downscaling algorithm and replicating it using Python, as well as testing some images to preview how the final result should look like.

Serial processing was implemented first to make sure that the algorithm works properly in SystemVerilog and that the FPGA can properly read and write images.

SIMD lanes were then described in theory and later defined as registers.

Fixed point arithmetic was implemented and tested.

A series of ModelSim testbenches were developed with the purpose of debugging.

## What I learned

## How can it be improved?

## Running the project

## Pictures

### JTAG console response

<img width="1115" height="628" alt="Image" src="https://github.com/user-attachments/assets/cbaf112f-ab7d-4523-9135-7a7843518a61" />

### Block diagram

<img width="589" height="248" alt="Image" src="https://github.com/user-attachments/assets/ffd3167d-edb9-498b-b554-922847aabd73" />

### Test results

<img width="649" height="752" alt="Image" src="https://github.com/user-attachments/assets/69872f83-6b98-4899-81c3-e2c571d0add8" />

## Acknowledgements

Made in collaboration with Daniel Cob Beirute and Sergio Rios Campos.
