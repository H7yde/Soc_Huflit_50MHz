`timescale 1ns/1ps

module tb_uart;
    localparam CLK_FREQ         = 50_000_000;              
    localparam BAUD_RATE        = 5000000;                  
    localparam CLK_PERIOD_NS    = 20;                      
    localparam real BIT_PERIOD_NS = 1_000_000_000.0 / BAUD_RATE; 

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
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

    // UART Signals
    wire        uart_tx;
    reg         uart_rx = 1'b1;

    integer pass_cnt  = 0;
    integer total_cnt = 0;

    localparam REG_TXDATA = 32'h4000_0000;
    localparam REG_RXDATA = 32'h4000_0004;
    localparam REG_STATUS = 32'h4000_0008;

    soc_axi_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) dut (
        .clk     (clk),     
        .rst_n   (rst_n),
        
        .S_AXI_AWADDR (s_axi_awaddr), .S_AXI_AWVALID(s_axi_awvalid), .S_AXI_AWREADY(s_axi_awready),
        .S_AXI_WDATA  (s_axi_wdata),  .S_AXI_WSTRB  (s_axi_wstrb),   .S_AXI_WVALID (s_axi_wvalid), .S_AXI_WREADY(s_axi_wready),
        .S_AXI_BRESP  (s_axi_bresp),  .S_AXI_BVALID (s_axi_bvalid),  .S_AXI_BREADY (s_axi_bready),
        .S_AXI_ARADDR (s_axi_araddr), .S_AXI_ARVALID(s_axi_arvalid), .S_AXI_ARREADY(s_axi_arready),
        .S_AXI_RDATA  (s_axi_rdata),  .S_AXI_RRESP  (s_axi_rresp),   .S_AXI_RVALID (s_axi_rvalid), .S_AXI_RREADY(s_axi_rready),
        
        .uart_tx (uart_tx), .uart_rx (uart_rx),
        .spi_sclk(), .spi_mosi(), .spi_miso(1'b0), .spi_cs(),
        .scl_out(),  .sda_out(),  .sda_oe(),   .sda_in(1'b1)
    );

    task check_result(input [256*8-1:0] tc_name, input condition);
        begin
            total_cnt = total_cnt + 1;
            if (condition) begin
                $display("[%0.3f us] [PASS] %0s", $realtime/1000.0, tc_name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[%0.3f us] [FAIL] %0s", $realtime/1000.0, tc_name);
            end
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

    task send_uart_rx_byte(input [7:0] rx_byte);
        integer i;
        begin
            $display("[%0.3f us]   [TB Drive RX] Bat dau truyen byte 0x%02h vao chan uart_rx...", $realtime/1000.0, rx_byte);
            uart_rx = 1'b0; #(BIT_PERIOD_NS);
            for (i = 0; i < 8; i = i + 1) begin uart_rx = rx_byte[i]; #(BIT_PERIOD_NS); end
            uart_rx = 1'b1; #(BIT_PERIOD_NS);
        end
    endtask

    // TC1: Baud Rate & Framing Check
    task tc_uart_baud_and_framing;
        integer k; reg [9:0] captured_frame; reg tx_started; real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("\n==================================================");
            $display("[%0.3f us] ---> START TASK: [TC1] UART Baud Rate & Framing Check", start_time_us);
            
            tx_started = 1'b0; repeat (5) @(posedge clk);
            axi_write(REG_TXDATA, 32'h55);

            fork : wait_start_bit
                begin @(negedge uart_tx); tx_started = 1'b1; disable wait_start_bit; end
                begin #(BIT_PERIOD_NS * 5); disable wait_start_bit; end
            join

            if (!tx_started) begin
                check_result("UART TX khoi dong thanh cong", 1'b0);
            end else begin
                for (k = 0; k < 10; k = k + 1) begin
                    if (k == 0) #(BIT_PERIOD_NS / 2.0); else #(BIT_PERIOD_NS);
                    captured_frame[k] = uart_tx;
                end
                check_result("Start bit phai la Logic 0", captured_frame[0] === 1'b0);
                check_result("Data bit truyen dung pattern 0x55", captured_frame[8:1] === 8'h55);
                check_result("Stop bit phai la Logic 1", captured_frame[9] === 1'b1);
            end
            #(BIT_PERIOD_NS * 2);
        end
    endtask

    // TC2: Data Pattern Validation (TX)
    task tc_uart_data_pattern(input [7:0] tx_byte);
        integer i; reg [9:0] captured; reg [7:0] rx_byte; real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("\n==================================================");
            $display("[%0.3f us] ---> START TASK: [TC2] UART Data Pattern TX (0x%02h)", start_time_us, tx_byte);
            
            axi_write(REG_TXDATA, {24'b0, tx_byte});
            @(negedge uart_tx);
            for (i = 0; i <= 9; i = i + 1) begin
                if (i == 0) #(BIT_PERIOD_NS / 2.0); else #(BIT_PERIOD_NS);
                captured[i] = uart_tx;
            end
            rx_byte = captured[8:1];
            check_result("Xac nhan Khung Du Lieu UART TX gui thanh cong", (captured[0] === 1'b0) && (rx_byte === tx_byte) && (captured[9] === 1'b1));
            #(BIT_PERIOD_NS * 2);
        end
    endtask

    // TC3: Status Register Verification
    task tc_uart_status_reg;
        reg [31:0] rdata; real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("\n==================================================");
            $display("[%0.3f us] ---> START TASK: [TC3] AXI Status Register Verification", start_time_us);

            axi_read(REG_STATUS, rdata);
            check_result("Status IDLE: Tx Ready (bit 0) == 1", rdata[0] === 1'b1);

            axi_write(REG_TXDATA, 32'hA5);
            axi_read(REG_STATUS, rdata);
            check_result("Status BUSY: Tx Ready (bit 0) == 0", rdata[0] === 1'b0);

            #(11 * BIT_PERIOD_NS);
            axi_read(REG_STATUS, rdata);
            check_result("Status DONE: Tx Ready (bit 0) == 1", rdata[0] === 1'b1);
        end
    endtask

    // TC4: Receive Data Validation (RX)
    task tc_uart_rx_receive(input [7:0] expected_byte);
        reg [31:0] rdata; real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("\n==================================================");
            $display("[%0.3f us] ---> START TASK: [TC4] UART Receive Data RX (0x%02h)", start_time_us, expected_byte);

            send_uart_rx_byte(expected_byte);
            repeat (5) @(posedge clk);

            axi_read(REG_RXDATA, rdata);
            check_result("Xac nhan UART RX nhan va doc thanh cong qua AXI", rdata[7:0] === expected_byte);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //tc_uart_baud_and_framing;
        //tc_uart_data_pattern(8'hA5);
        //tc_uart_status_reg;
        tc_uart_rx_receive(8'h3C);

        $display("\n==================================================");
        $display("[%0.3f us] TONG KET UART: PASS %0d / %0d TEST CASES", $realtime / 1000.0, pass_cnt, total_cnt);
        $display("==================================================");
        $finish;
    end

    initial begin
        #2_000_000; 
        $display("\n[%0.3f us] [TIMEOUT] Testbench bi treo qua thoi gian cho phep!", $realtime / 1000.0);
        $finish;
    end
endmodule