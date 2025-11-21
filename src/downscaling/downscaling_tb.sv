`timescale 1ns/1ps

module downscaling_tb;

    localparam int IMG_W = 4;
    localparam int IMG_H = 4;
	localparam ratio = 0.5;
    localparam int local_out_w = IMG_W * ratio;
    localparam int local_out_h = IMG_H * ratio;

    logic clk;
    logic rst_n;
    logic done;
	 
	integer i, j;

    // Instancia del módulo
    downscaling_serial #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H),
		.ratio(ratio)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .done(done)
    );

    // Generación de reloj
    initial clk = 0;
    always #5 clk = ~clk;

    // Estímulo
    initial begin
        rst_n = 0;
        #20;
        rst_n = 1;

        // Imagen de prueba 4x4 con gradiente simple
        dut.img_in[0][0] = 8'd0;   dut.img_in[0][1] = 8'd64;
        dut.img_in[0][2] = 8'd128; dut.img_in[0][3] = 8'd192;

        dut.img_in[1][0] = 8'd32;  dut.img_in[1][1] = 8'd96;
        dut.img_in[1][2] = 8'd160; dut.img_in[1][3] = 8'd224;

        dut.img_in[2][0] = 8'd64;  dut.img_in[2][1] = 8'd128;
        dut.img_in[2][2] = 8'd192; dut.img_in[2][3] = 8'd255;

        dut.img_in[3][0] = 8'd96;  dut.img_in[3][1] = 8'd160;
        dut.img_in[3][2] = 8'd224; dut.img_in[3][3] = 8'd255;

        // Esperar hasta que el módulo termine
        wait (done == 1);
        @(posedge clk);

        // Mostrar la imagen reducida

        $display("\nImagen de salida (%0dx%0d):", local_out_w, local_out_h);
        for (i = 0; i < local_out_w; i++) begin
            for (j = 0; j < local_out_h; j++) begin
                $write("%4d ", dut.img_out[i][j]);
            end
            $write("\n");
        end

        $display("\nProcesamiento terminado correctamente.");
        $finish;
    end

endmodule