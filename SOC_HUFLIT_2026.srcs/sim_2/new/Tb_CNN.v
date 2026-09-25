`timescale 1ns/1ps

// Verilog-only testbench for the AXI4-Lite CNN block.
// It sends a 32x32 RGB frame through the CNN AXI register interface,
// starts inference, waits for DONE, then reads CLASSIFICATION.
module tb_CNN;
    reg clk;
    reg rst_n;

    reg  [31:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;

    reg  [31:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    reg [23:0] human_pixels [0:1023];
    reg [23:0] nonhuman_pixels [0:1023];
    reg [31:0] tx_word;
    reg [31:0] rx_data;
    reg [31:0] status_data;
    wire dut_wready;
    integer i, j, byte_index, pixel_index, byte_in_pixel;
    integer pass_count, fail_count, timeout_count;
    reg [7:0] one_byte;

    CNN dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .S_AXI_AWADDR  (awaddr),
        .S_AXI_AWVALID (awvalid),
        .S_AXI_AWREADY (awready),
        .S_AXI_WDATA   (wdata),
        .S_AXI_WSTRB   (wstrb),
        .S_AXI_WVALID  (wvalid),
        .S_AXI_WREADY  (dut_wready),
        .S_AXI_BRESP   (bresp),
        .S_AXI_BVALID  (bvalid),
        .S_AXI_BREADY  (bready),
        .S_AXI_ARADDR  (araddr),
        .S_AXI_ARVALID (arvalid),
        .S_AXI_ARREADY (arready),
        .S_AXI_RDATA   (rdata),
        .S_AXI_RRESP   (rresp),
        .S_AXI_RVALID  (rvalid),
        .S_AXI_RREADY  (rready)
    );
    always #10 clk = ~clk;       // 50 MHz

    // Write one AXI4-Lite transaction. CNN accepts address and data
    // independently, so this task waits for both handshakes.
    task axi_write;
        input [31:0] address;
        input [31:0] data;
        begin
            @(posedge clk);
            awaddr  <= address;
            awvalid <= 1'b1;
            while (!awready) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;

            wdata   <= data;
            wstrb   <= 4'b1111;
            wvalid  <= 1'b1;
            while (!dut_wready) @(posedge clk);
            @(posedge clk);
            wvalid  <= 1'b0;

            while (!bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task axi_read;
        input  [31:0] address;
        output [31:0] data;
        begin
            @(posedge clk);
            araddr  <= address;
            arvalid <= 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(posedge clk);
        end
    endtask

    // Pack four consecutive RGB bytes into one 32-bit AXI word.
    // The packing matches dma32_to_rgb24 with MSB_FIRST=1.
    task make_word;
        input  integer word_number;
        input  integer which_frame;
        output [31:0] word_value;
        begin
            word_value = 32'd0;
            for (j = 0; j < 4; j = j + 1) begin
                byte_index = word_number * 4 + j;
                pixel_index = byte_index / 3;
                byte_in_pixel = byte_index % 3;
                if (which_frame == 1)
                    case (byte_in_pixel)
                        0: one_byte = human_pixels[pixel_index][23:16];
                        1: one_byte = human_pixels[pixel_index][15:8];
                        default: one_byte = human_pixels[pixel_index][7:0];
                    endcase
                else
                    case (byte_in_pixel)
                        0: one_byte = nonhuman_pixels[pixel_index][23:16];
                        1: one_byte = nonhuman_pixels[pixel_index][15:8];
                        default: one_byte = nonhuman_pixels[pixel_index][7:0];
                    endcase
                word_value = {word_value[23:0], one_byte};
            end
        end
    endtask

    task run_case;
        input integer case_number;
        input integer expected_value;
        begin
            $display("============================================================");
            if (case_number == 1)
                $display("[TB][CASE 1] HUMAN");
            else
                $display("[TB][CASE 2] NON-HUMAN");

            $display("[TB][INFO] writing 768 RGB words through AXI");
            for (i = 0; i < 768; i = i + 1) begin
                make_word(i, case_number, tx_word);
                axi_write(i * 4, tx_word);
            end
            $display("[TB][INPUT] transferred words: 768/768");

            axi_write(32'h00000FFC, 32'h00000001);
            timeout_count = 0;
            status_data = 0;
            while (!status_data[1] && timeout_count < 300000) begin
                axi_read(32'h00000FF8, status_data);
                timeout_count = timeout_count + 1;
            end

            if (timeout_count >= 300000) begin
                $display("[TB][FAIL] timeout waiting for CNN DONE");
                fail_count = fail_count + 1;
            end else begin
                axi_read(32'h00000FF4, rx_data);
                $display("[TB][RESULT] status=%h classification=%0d expected=%0d",
                         status_data, rx_data[0], expected_value);
                if (rx_data[0] == expected_value) begin
                    $display("[TB][PASS]");
                    pass_count = pass_count + 1;
                end else begin
                    $display("[TB][FAIL]");
                    fail_count = fail_count + 1;
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 1'b1;
        araddr = 0; arvalid = 0; rready = 1'b1;
        pass_count = 0;
        fail_count = 0;

        $readmemh("D:/LAB/custom_SOC/CNN_RTL/human_frame.mem", human_pixels);
        $readmemh("D:/LAB/custom_SOC/CNN_RTL/nonhuman_frame.mem", nonhuman_pixels);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_case(1, 1);          // 1 = human
        run_case(2, 0);          // 0 = non-human

        $display("============================================================");
        $display("[TB][SUMMARY] passed=%0d failed=%0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("[TB][SUMMARY] CNN AXI TEST PASS");
        else
            $display("[TB][SUMMARY] CNN AXI TEST FAIL");
        $finish;
    end
endmodule
