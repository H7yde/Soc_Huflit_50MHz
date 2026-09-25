`timescale 1ns/1ps

module tb_spi;
    localparam CLK_PERIOD_NS = 20;

    reg clk = 0;
    reg rst_n = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

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

    wire        spi_sclk, spi_mosi, spi_cs;
    reg         spi_miso = 1'b0;

    integer test_total = 0;
    integer test_pass  = 0;

    reg [7:0] slave_pattern = 8'h00;
    integer   slave_bit_idx = 0;

    soc_axi_top #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115200)
    ) dut (
        .clk      (clk), 
        .rst_n    (rst_n),
        
        .S_AXI_AWADDR (s_axi_awaddr), .S_AXI_AWVALID(s_axi_awvalid), .S_AXI_AWREADY(s_axi_awready),
        .S_AXI_WDATA  (s_axi_wdata),  .S_AXI_WSTRB  (s_axi_wstrb),   .S_AXI_WVALID (s_axi_wvalid), .S_AXI_WREADY(s_axi_wready),
        .S_AXI_BRESP  (s_axi_bresp),  .S_AXI_BVALID (s_axi_bvalid),  .S_AXI_BREADY (s_axi_bready),
        .S_AXI_ARADDR (s_axi_araddr), .S_AXI_ARVALID(s_axi_arvalid), .S_AXI_ARREADY(s_axi_arready),
        .S_AXI_RDATA  (s_axi_rdata),  .S_AXI_RRESP  (s_axi_rresp),   .S_AXI_RVALID (s_axi_rvalid), .S_AXI_RREADY(s_axi_rready),
        
        .uart_tx  (), .uart_rx  (1'b1),
        .spi_sclk (spi_sclk), .spi_mosi (spi_mosi), .spi_miso (spi_miso), .spi_cs   (spi_cs),
        .scl_out  (), .sda_out  (), .sda_oe   (), .sda_in   (1'b1)
    );

    localparam REG_SPI_TXDATA = 32'h4000_1000;
    localparam REG_SPI_CS     = 32'h4000_1004;
    localparam REG_SPI_STATUS = 32'h4000_1008;

    task report(input passed);
        begin
            test_total = test_total + 1;
            if (passed) begin test_pass = test_pass + 1; $display("  -> [PASS]"); end 
            else $display("  -> [FAIL]");
        end
    endtask

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

    task wait_spi_busy_low;
        reg [31:0] st; integer guard;
        begin
            guard = 0; st = 32'h1;
            while (st[0] == 1'b1 && guard < 500) begin axi_read(REG_SPI_STATUS, st); guard = guard + 1; end
        end
    endtask

    task load_slave_pattern(input [7:0] pattern);
        begin slave_pattern = pattern; slave_bit_idx = 7; spi_miso = pattern[7]; end
    endtask

    always @(negedge spi_sclk or negedge rst_n) begin
        if (!rst_n) slave_bit_idx <= 0;
        else if (slave_bit_idx > 0) begin
            slave_bit_idx <= slave_bit_idx - 1;
            spi_miso      <= slave_pattern[slave_bit_idx - 1];
        end
    end

    // TC1 & TC2: Kiểm tra truyền Full-Duplex SPI
    task test_spi_transfer(input [7:0] tx_byte, input [7:0] rx_pattern);
        integer i; reg [7:0] captured_mosi; reg [31:0] rdata; reg cpol_ok;
        begin
            cpol_ok = (spi_sclk === 1'b0);
            $display("\n[%0.3f us] [TC1] SPI - CPOL: SCLK idle truoc khi truyen = %b (ky vong 0)", $realtime/1000.0, spi_sclk);
            report(cpol_ok);

            load_slave_pattern(rx_pattern);
            axi_write(REG_SPI_CS, 32'h0);               
            axi_write(REG_SPI_TXDATA, {24'b0, tx_byte}); 

            for (i = 0; i <= 7; i = i + 1) begin
                @(posedge spi_sclk);
                captured_mosi[7-i] = spi_mosi; 
            end
            
            $display("\n[%0.3f us] [TC2] SPI - Vi tri bit MOSI (MSB first) gui=0x%02h, nhan=0x%02h", $realtime/1000.0, tx_byte, captured_mosi);
            report(captured_mosi === tx_byte);

            wait_spi_busy_low;
            axi_write(REG_SPI_CS, 32'h1); 

            axi_read(REG_SPI_TXDATA, rdata); 
            $display("\n[%0.3f us] [TC2] SPI - Du lieu MISO nhan duoc = 0x%02h (ky vong 0x%02h)", $realtime/1000.0, rdata[7:0], rx_pattern);
            report(rdata[7:0] === rx_pattern);
        end
    endtask

    // TC3: Kiểm tra ghi/đọc thanh ghi CS
    task test_spi_cs_register;
        reg [31:0] rdata;
        begin
            axi_write(REG_SPI_CS, 32'h0);
            axi_read(REG_SPI_CS, rdata);
            $display("\n[%0.3f us] [TC3] SPI - Ghi/doc thanh ghi CS = 0: doc lai = %0d (ky vong 0)", $realtime/1000.0, rdata[0]);
            report(rdata[0] === 1'b0);
            
            axi_write(REG_SPI_CS, 32'h1);
            axi_read(REG_SPI_CS, rdata);
            $display("\n[%0.3f us] [TC3] SPI - Ghi/doc thanh ghi CS = 1: doc lai = %0d (ky vong 1)", $realtime/1000.0, rdata[0]);
            report(rdata[0] === 1'b1);
        end
    endtask
    
    initial begin
        rst_n = 1'b0; slave_pattern = 8'h00; slave_bit_idx = 0;
        repeat (3) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        
        //test_spi_transfer(8'hD6, 8'h3C);
        test_spi_cs_register;

        $display("\n--------------------------------------------------");
        $display("TONG KET SPI: %0d/%0d test case PASS", test_pass, test_total);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #200000;
        $display("\n[%0.3f us] TB FAIL: timeout.", $realtime/1000.0);
        $finish;
    end
endmodule