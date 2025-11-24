module downscaling_tb;
    localparam LANES = 8;
    localparam Q = 8;

    logic clk = 0;
    logic rst = 0;

    always #5 clk = ~clk;

    logic start;
    // TODO: chequear si se puede usar menos de 32 bits
    logic [31:0] width, height;
    logic [31:0] out_w, out_h;
    logic [31:0] scale_q8_8;
    logic [1:0] mode;

    logic busy;
    logic [31:0] progress, errors;
    logic [63:0] flops, reads, writes;

    logic [LANES * 8 - 1:0] p00, p01, p10, p11;
    logic [LANES * Q - 1:0] fracx, fracy;
    logic [LANES * 8 - 1: 0] out_vec;
    logic out_valid;

    // Usar vectores lógicos de 8 bits (sin signo) para imagenes
    logic [7:0] img_in [0:511][0:511];
    logic [7:0] img_out [0:511][0:511];

    simd_downscaler #(.LANES(LANES), .Q(Q)) dut (
        .clk(clk), .rst_n(rst),
        .start(start),
        .in_width(width), .in_height(height),
        .out_width(out_w), .out_height(out_h),
        .scale_q8_8(scale_q8_8),
        .mode(mode),
        .busy(busy),
        .progress(progress),
        .errors(errors),
        .perf_flops(flops),
        .perf_mem_reads(reads),
        .perf_mem_writes(writes),
        .p00_packed(p00),
        .p01_packed(p01),
        .p10_packed(p10),
        .p11_packed(p11),
        .frac_x_packed(fracx),
        .frac_y_packed(fracy),
        .out_pixels_packed(out_vec),
        .out_valid(out_valid)
    );

    // Carga pixeles de imagen
    task load_image(input int w,h);
        int x,y;
//        for (y = 0; y < h; y++) begin
//            for (x = 0; x < w; x++)
//                img_in[y][x] = (x + y) & 8'hFF;
//        end
		  img_in[0][0] = 8'd0;   img_in[0][1] = 8'd64;
        img_in[0][2] = 8'd128; img_in[0][3] = 8'd192;

        img_in[1][0] = 8'd32;  img_in[1][1] = 8'd96;
        img_in[1][2] = 8'd160; img_in[1][3] = 8'd224;

        img_in[2][0] = 8'd64;  img_in[2][1] = 8'd128;
        img_in[2][2] = 8'd192; img_in[2][3] = 8'd255;

        img_in[3][0] = 8'd96;  img_in[3][1] = 8'd160;
        img_in[3][2] = 8'd224; img_in[3][3] = 8'd255;
    endtask

    function automatic void compute_coords(
        input int x, y,
        input real scale,
        output int x0, x1, y0, y1,
        output logic [7:0] fx, fy
    );
        real scaled_x = x * scale;
        real scaled_y = y * scale;

        x0 = int'($floor(scaled_x));
        y0 = int'($floor(scaled_y));
        x1 = (x0 + 1 < width) ? x0 + 1 : x0;
        // Usar altura para límite vertical
        y1 = (y0 + 1 < height) ? y0 + 1 : y0;

        fx = $rtoi((scaled_x - x0) * 255.0);
        fy = $rtoi((scaled_y - y0) * 255.0);

    endfunction
	 
	 // SIMD lane driver
    task drive_lanes(input int oy, ox_base);
        int lane, ox;
        int x0,x1,y0,y1;
        logic [7:0] fx, fy;

        for (lane = 0; lane < LANES; lane++) begin
            ox = ox_base + lane;

            if (ox < out_w) begin
                // Usar factor de escala basado en (in_dim-1)/(out_dim-1) para mapear extremos
                compute_coords(ox, oy, scale_r,
                               x0,x1,y0,y1,fx,fy);

                p00[8*lane +:8] = img_in[y0][x0];
                p01[8*lane +:8] = img_in[y0][x1];
                p10[8*lane +:8] = img_in[y1][x0];
                p11[8*lane +:8] = img_in[y1][x1];

                fracx[lane*Q +:Q] = fx;
                fracy[lane*Q +:Q] = fy;
            end
            else begin
                p00[8*lane +:8] = 0;
                p01[8*lane +:8] = 0;
                p10[8*lane +:8] = 0;
                p11[8*lane +:8] = 0;
                fracx[lane*Q +:Q] = 0;
                fracy[lane*Q +:Q] = 0;
            end
        end
    endtask
	 
	 int oy, ox;
	 int lane;
	 
    // Capture output pixels
    int out_count = 0;
    always_ff @(posedge clk) begin
        if (out_valid) begin
            automatic int ox_temp = out_count % out_w;
            automatic int oy_temp = out_count / out_w;

            for (int lane = 0; lane < LANES; lane++) begin
                if (ox_temp < out_w && oy_temp < out_h) begin
                    img_out[oy_temp][ox_temp] = out_vec[8*lane +: 8];
                    ox_temp++;
                    if (ox_temp >= out_w) begin
                        ox_temp = 0;
                        oy_temp++;
                    end
                end
            end
            out_count += LANES;
        end
    end	 // Print numeric array
    task print_image_int(input int w, h);
        int y,x;
        for (y=0;y<h;y++) begin
            for (x=0;x<w;x++) begin
                $write("%0d ", img_out[y][x]);
            end
            $write("\n");
        end
    endtask
	 
	 real scale_r;
	 int oy_lanes, ox_lanes;

	 
	 // Test procedure
    initial begin
        rst = 0;
        start = 0;

        #40 rst = 1;

        width  = 4;
        height  = 4;
        out_w = 2;
        out_h = 2;

        load_image(width, height);

        // Factor de escala correcto: (W_in-1)/(W_out-1) para que último pixel de salida apunte al último de entrada.
        if (out_w > 1)
            scale_r = real'(width - 1)/real'(out_w - 1);
        else
            scale_r = 0.0; // trivial caso
        scale_q8_8   = int'(scale_r * 256.0);

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Drive all output pixels in a single cycle (out_w*out_h = 4 pixels, LANES=8)
        // Lane 0: (ox=0,oy=0), Lane 1: (ox=1,oy=0), Lane 2: (ox=0,oy=1), Lane 3: (ox=1,oy=1)
        for (int lane = 0; lane < LANES; lane++) begin
            automatic int ox = lane % out_w;
            automatic int oy = lane / out_w;
            automatic int x0, x1, y0, y1;
            automatic logic [7:0] fx, fy;

            if (ox < out_w && oy < out_h) begin
                compute_coords(ox, oy, scale_r, x0, x1, y0, y1, fx, fy);

                p00[8*lane +:8] = img_in[y0][x0];
                p01[8*lane +:8] = img_in[y0][x1];
                p10[8*lane +:8] = img_in[y1][x0];
                p11[8*lane +:8] = img_in[y1][x1];

                fracx[lane*Q +:Q] = fx;
                fracy[lane*Q +:Q] = fy;
            end else begin
                p00[8*lane +:8] = 0;
                p01[8*lane +:8] = 0;
                p10[8*lane +:8] = 0;
                p11[8*lane +:8] = 0;
                fracx[lane*Q +:Q] = 0;
                fracy[lane*Q +:Q] = 0;
            end
        end
        @(posedge clk);

        // Wait a few extra cycles for pipeline to flush
        repeat(3) @(posedge clk);

        wait (!busy);

        $display("\n=== INTEGER IMAGE OUTPUT (%0dx%0d) ===", out_w, out_h);
        print_image_int(out_w, out_h);

        $finish;
    end

endmodule
