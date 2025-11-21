`timescale 1ns/1ps

module downscaling_tb;

    localparam int WIDTH  = 4;
    localparam int HEIGHT = 4;
    localparam SCALE  = 0.5;
    localparam LANES  = 4;

    localparam int OUT_W  = WIDTH  * SCALE;
    localparam int OUT_H  = HEIGHT * SCALE;

    logic clk = 0;
    logic rst = 1;

    logic [7:0] bank_mem[LANES-1:0][HEIGHT-1:0][(WIDTH+LANES-1)/LANES - 1:0];
    logic [7:0] pixel_out[LANES-1:0];


    always #5 clk = ~clk;

    downscaling_simd #(
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT),
        .SCALE(SCALE),
        .LANES(LANES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .bank_mem(bank_mem),
        .pixel_out(pixel_out)
    );
	 
	 int real_x;


    logic [7:0] image[HEIGHT-1:0][WIDTH-1:0];

	// Imagen de prueba 4x4 con gradiente simple
	initial begin
        image[0][0] = 8'd0;   image[0][1] = 8'd64;
        image[0][2] = 8'd128; image[0][3] = 8'd192;

        image[1][0] = 8'd32;  image[1][1] = 8'd96;
        image[1][2] = 8'd160; image[1][3] = 8'd224;

        image[2][0] = 8'd64;  image[2][1] = 8'd128;
        image[2][2] = 8'd192; image[2][3] = 8'd255;

        image[3][0] = 8'd96;  image[3][1] = 8'd160;
        image[3][2] = 8'd224; image[3][3] = 8'd255;
	end

	 int pack_width;
	 int x;
	 int y;

// Imagen arreglo 2D a 3D con lanes
task pack_image_into_banks();
    pack_width = (WIDTH+LANES-1)/LANES;
    

    for (int lane = 0; lane < LANES; lane++) begin
        for (int y = 0; y < HEIGHT; y++) begin
            for (int px = 0; px < pack_width; px++) begin

                real_x = px * LANES + lane;

                if (real_x < WIDTH)
                    bank_mem[lane][y][px] = image[y][real_x];
                else
                    bank_mem[lane][y][px] = 8'h00;

            end
        end
    end
endtask

int total_cycles;

// Reconstruir imagen de salida de nuevo a 2D
task reconstruct_output_image(
    output logic [7:0] out_image[OUT_H-1:0][OUT_W-1:0]
);
    total_cycles = (OUT_W + LANES - 1) / LANES * OUT_H;

    for (int cycle = 0; cycle < total_cycles; cycle++) begin
        @(posedge clk);

        for (int lane = 0; lane < LANES; lane++) begin
            if (x < OUT_W) begin
                out_image[y][x] = pixel_out[lane];
                x++;
            end
        end

        if (x >= OUT_W) begin
            x = 0;
            y++;
        end
    end
endtask

// Imprimir imagen para verificar
task print_output_image(
    input logic [7:0] out_image[OUT_H-1:0][OUT_W-1:0]
);
    $display("\n---- Downscaled Output %0dx%0d ----", OUT_W, OUT_H);
    for (int yy = 0; yy < OUT_H; yy++) begin
        $write("[ ");
        for (int xx = 0; xx < OUT_W; xx++)
            $write("%0d ", out_image[yy][xx]);
        $write("]\n");
    end
endtask

logic [7:0] out_image[OUT_H-1:0][OUT_W-1:0];

initial begin
    pack_image_into_banks();
    rst = 1;
    #20;
    rst = 0;

    reconstruct_output_image(out_image);
    print_output_image(out_image);

    $finish;
end

	 
endmodule
