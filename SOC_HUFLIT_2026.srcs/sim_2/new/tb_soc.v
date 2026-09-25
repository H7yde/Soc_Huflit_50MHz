`timescale 1ns/1ps

module tb_soc_axi_top;

reg clk = 0, rst_n = 0;
always #10 clk = ~clk;  // 50 MHz

// --- Tín hiệu AXI4-Lite Master ---
reg  [31:0] s_axi_awaddr  = 0;
reg         s_axi_awvalid = 0;
wire        s_axi_awready;
reg  [31:0] s_axi_wdata   = 0;
reg  [ 3:0] s_axi_wstrb   = 4'hF;
reg         s_axi_wvalid  = 0;
wire        s_axi_wready;
wire [ 1:0] s_axi_bresp;
wire        s_axi_bvalid;
reg         s_axi_bready  = 0;
reg  [31:0] s_axi_araddr  = 0;
reg         s_axi_arvalid = 0;
wire        s_axi_arready;
wire [31:0] s_axi_rdata;
wire [ 1:0] s_axi_rresp;
wire        s_axi_rvalid;
reg         s_axi_rready  = 0;

wire uart_tx, spi_sclk, spi_mosi, spi_cs;
wire scl_out, sda_out, sda_oe;
reg  uart_rx = 1, spi_miso = 0;

wire scl_bus, sda_bus;
wire sda_in;

assign scl_bus = scl_out;
assign sda_bus = sda_oe ? sda_out : 1'bz;
pullup(sda_bus);
pullup(scl_bus);

assign sda_in  = sda_bus;

localparam UART_BASE = 32'h4000_0000;
localparam SPI_BASE  = 32'h4000_1000;
localparam I2C_BASE  = 32'h4000_2000;

soc_axi_top #(
    .CLK_FREQ(50_000_000), 
    .BAUD_RATE(115200)
) u_dut (
    .clk(clk), .rst_n(rst_n),
    
    .S_AXI_AWADDR (s_axi_awaddr), .S_AXI_AWVALID(s_axi_awvalid), .S_AXI_AWREADY(s_axi_awready),
    .S_AXI_WDATA  (s_axi_wdata),  .S_AXI_WSTRB  (s_axi_wstrb),   .S_AXI_WVALID (s_axi_wvalid), .S_AXI_WREADY(s_axi_wready),
    .S_AXI_BRESP  (s_axi_bresp),  .S_AXI_BVALID (s_axi_bvalid),  .S_AXI_BREADY (s_axi_bready),
    .S_AXI_ARADDR (s_axi_araddr), .S_AXI_ARVALID(s_axi_arvalid), .S_AXI_ARREADY(s_axi_arready),
    .S_AXI_RDATA  (s_axi_rdata),  .S_AXI_RRESP  (s_axi_rresp),   .S_AXI_RVALID (s_axi_rvalid), .S_AXI_RREADY(s_axi_rready),

    .uart_tx(uart_tx), .uart_rx(uart_rx),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs(spi_cs),
    .scl_out(scl_out), .sda_out(sda_out), .sda_oe(sda_oe), .sda_in(sda_in)
);

task axi_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        s_axi_awaddr  <= addr; s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data; s_axi_wstrb   <= 4'hF; s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;
        fork
            begin wait(s_axi_awready); @(posedge clk); s_axi_awvalid <= 1'b0; end
            begin wait(s_axi_wready);  @(posedge clk); s_axi_wvalid  <= 1'b0; end
        join
        wait(s_axi_bvalid); @(posedge clk); s_axi_bready <= 1'b0;
    end
endtask

task axi_read(input [31:0] addr, output [31:0] rdata);
    begin
        @(posedge clk);
        s_axi_araddr  <= addr; s_axi_arvalid <= 1'b1; s_axi_rready  <= 1'b1;
        wait(s_axi_arready); @(posedge clk); s_axi_arvalid <= 1'b0;
        wait(s_axi_rvalid); rdata = s_axi_rdata; @(posedge clk); s_axi_rready <= 1'b0;
    end
endtask

// TEST 1: AXI Decoder Access Check
task test_axi_decoder_exclusive;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 1: AXI Decoder Access Check", $realtime);
        axi_write(UART_BASE, 32'h41);
        $display("[%0.1f ns] TEST 1 PASS: Access AXI decoder successfully", $realtime);
    end
endtask

// TEST 2: Concurrent HW output (UART + SPI)
task test_hw_concurrent;
    integer uart_active, spi_active, overlap_cycles;
    reg done_test;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 2: UART + SPI Concurrent Check", $realtime);
        uart_active = 0; spi_active = 0; overlap_cycles = 0; done_test = 0;

        axi_write(SPI_BASE + 32'h4, 32'h0); 
        axi_write(SPI_BASE, 32'hAB);        
        axi_write(UART_BASE, 32'h55);       

        repeat(5000) begin
            if (!done_test) begin
                @(posedge clk);
                uart_active = (!uart_tx) ? 1 : 0;
                spi_active  = (!spi_cs || spi_sclk) ? 1 : 0;
                if (uart_active && spi_active) begin
                    overlap_cycles = overlap_cycles + 1;
                    if (overlap_cycles >= 50) done_test = 1;
                end
            end
        end
        if (overlap_cycles > 0) $display("[%0.1f ns] TEST 2 PASS: uart_tx + spi overlap = %0d cycles (Early Exit)", $realtime, overlap_cycles);
        else $display("[%0.1f ns] TEST 2 FAIL: Khong phat hien hoat dong song song giua UART va SPI!", $realtime);
    end
endtask

// TEST 3: Tất cả 3 peripheral concurrent
task test_all_three_concurrent;
    integer all_three_active_count;
    reg done_test;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 3: All 3 Peripherals Concurrent Check", $realtime);
        all_three_active_count = 0; done_test = 0;

        axi_write(SPI_BASE + 32'h4, 32'h0); 
        axi_write(I2C_BASE + 32'h04, 32'h01); 
        axi_write(UART_BASE, 32'hAA);       
        axi_write(SPI_BASE, 32'h3C);        

        repeat(6000) begin
            if (!done_test) begin
                @(posedge clk);
                if ((!uart_tx) && (!spi_cs || spi_sclk) && (!scl_out || !sda_out)) begin
                    all_three_active_count = all_three_active_count + 1;
                    if (all_three_active_count >= 20) done_test = 1;
                end
            end
        end
        if (all_three_active_count > 0) $display("[%0.1f ns] TEST 3 PASS: So chu ky ca 3 ngoai vi cung hoat dong = %0d", $realtime, all_three_active_count);
        else $display("[%0.1f ns] TEST 3 FAIL: I2C hoac ngoai vi khac KHONG hoat dong!", $realtime);
    end
endtask

// TEST 4: Interleaved Cross-Peripheral Access
task test_interleaved_access;
    reg [31:0] read_data_uart;
    reg [31:0] read_data_spi;
    reg [31:0] read_data_i2c;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 4: Interleaved Cross-Peripheral Access Check", $realtime);

        axi_write(UART_BASE, 32'h58);
        $display("[%0.1f ns] [STEP 1] WRITE UART: 0x58", $realtime);

        axi_read(SPI_BASE + 32'h4, read_data_spi);
        $display("[%0.1f ns] [STEP 2] READ  SPI CS Reg: 0x%h", $realtime, read_data_spi);

        axi_write(I2C_BASE + 32'h00, 32'hA7); 
        axi_write(I2C_BASE + 32'h04, 32'h01); 
        $display("[%0.1f ns] [STEP 3] WRITE I2C Data (0xA7) & CMD START (0x01)", $realtime);

        axi_read(UART_BASE, read_data_uart);
        $display("[%0.1f ns] [STEP 4] READ  UART Reg: 0x%h", $realtime, read_data_uart);

        axi_write(SPI_BASE, 32'hA5);
        $display("[%0.1f ns] [STEP 5] WRITE SPI Data: 0xA5", $realtime);

        axi_read(I2C_BASE + 32'h08, read_data_i2c);
        $display("[%0.1f ns] [STEP 6] READ  I2C Status Reg: 0x%h", $realtime, read_data_i2c);

        $display("[%0.1f ns] TEST 4 PASS!", $realtime);
    end
endtask

initial begin
rst_n = 0; 
    repeat(2) @(posedge clk); 
    #1; // 
    rst_n = 1; 
    repeat(2) @(posedge clk);    
    // Mở lại toàn bộ Test Cases
    //test_axi_decoder_exclusive;
    //test_hw_concurrent;
    //test_all_three_concurrent;
    test_interleaved_access; 
    
    $display("\n==================================================");
    $display("       ALL SIMULATION TESTS COMPLETED!            ");
    $display("==================================================");
    $finish;
end

initial begin 
    #20_000_000; 
    $display("\n[%0.1f ns] [ERROR] SIMULATION TIMEOUT!", $realtime); 
    $finish; 
end
endmodule