`timescale 1ns/1ps

module tb_uart;

    // ------------------------------------------------------------------------
    // Simulation Settings
    // ------------------------------------------------------------------------
    localparam CLK_FREQ         = 50_000_000;               // System Clock 50 MHz
    localparam BAUD_RATE        = 5000000;                  // Baud rate tiêu chuẩn
    localparam CLK_PERIOD_NS    = 20;                      // 1 / 50MHz = 20 ns
    // Dùng kiểu real để giữ chính xác 8680.55 ns/bit (tránh lệch timing giữa các bit)
    localparam real BIT_PERIOD_NS = 1_000_000_000.0 / BAUD_RATE; 

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // APB Bus Signals
    reg  [31:0] PADDR;
    reg         PWRITE, PENABLE;
    reg  [31:0] PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    // UART Signals
    wire        uart_tx;
    reg         uart_rx = 1'b1;

    // Testbench Counters
    integer pass_cnt  = 0;
    integer total_cnt = 0;

    // Address Register Map
    localparam REG_TXDATA = 32'h4000_0000;
    localparam REG_RXDATA = 32'h4000_0004;
    localparam REG_STATUS = 32'h4000_0008;

    soc_apb_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) dut (
        .clk     (clk),     
        .rst_n   (rst_n),
        
        // APB Bus
        .PADDR   (PADDR),    
        .PWRITE  (PWRITE), 
        .PENABLE (PENABLE),
        .PWDATA  (PWDATA),   
        .PRDATA  (PRDATA), 
        .PREADY  (PREADY), 
        .PSLVERR (PSLVERR),
        
        // UART Interface
        .uart_tx (uart_tx),  
        .uart_rx (uart_rx),
        
        // Unused Peripherals
        .spi_sclk(), .spi_mosi(), .spi_miso(1'b0), .spi_cs(),
        .scl_out(),  .sda_out(),  .sda_oe(),   .sda_in(1'b1)
    );

    // ------------------------------------------------------------------------
    // Helper Tasks
    // ------------------------------------------------------------------------
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

    // APB Write Task (Hỗ trợ chuẩn APB PREADY Handshake)
    task apb_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            PADDR   <= addr; 
            PWDATA  <= data; 
            PWRITE  <= 1'b1; 
            PENABLE <= 1'b0;
            
            @(posedge clk);
            PENABLE <= 1'b1;
            
            // Chờ PREADY từ Slave kéo lên high
            @(posedge clk);
             while (!PREADY);
            
            PENABLE <= 1'b0; 
            PWRITE  <= 1'b0;
        end
    endtask

    // APB Read Task (Hỗ trợ chuẩn APB PREADY Handshake)
    task apb_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(posedge clk);
            PADDR   <= addr; 
            PWRITE  <= 1'b0; 
            PENABLE <= 1'b0;
            
            @(posedge clk);
            PENABLE <= 1'b1;
            
            // Chờ PREADY từ Slave kéo lên high
            @(posedge clk); 
            while (!PREADY);
            
            rdata   = PRDATA;
            PENABLE <= 1'b0;
        end
    endtask

    // Task mô phỏng thiết bị ngoài truyền 1 byte vào chân uart_rx
    task send_uart_rx_byte(input [7:0] rx_byte);
        integer i;
        begin
            $display("[%0.3f us]   [TB Drive RX] Bat dau truyen byte 0x%02h vao chan uart_rx...", $realtime/1000.0, rx_byte);
            
            // 1. Start Bit (Logic 0)
            uart_rx = 1'b0;
            #(BIT_PERIOD_NS);

            // 2. 8 Data Bits (LSB First)
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = rx_byte[i];
                #(BIT_PERIOD_NS);
            end

            // 3. Stop Bit (Logic 1)
            uart_rx = 1'b1;
            #(BIT_PERIOD_NS);
            
            $display("[%0.3f us]   [TB Drive RX] Hoan tat truyen khung RX qua chan uart_rx!", $realtime/1000.0);
        end
    endtask

    // ------------------------------------------------------------------------
    // Test Cases
    // ------------------------------------------------------------------------
    
    // TC1: Baud Rate & Framing Check (Pattern 0x55)
    task tc_uart_baud_and_framing;
        integer k;
        reg [9:0] captured_frame; // 1 Start + 8 Data + 1 Stop = 10 bits
        reg tx_started;
        real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("\n==================================================");
            $display("[%0.3f us] ---> START TASK: [TC1] UART Baud Rate & Framing Check", start_time_us);
            $display("==================================================");

            tx_started = 1'b0;
            repeat (5) @(posedge clk);

            $display("[%0.3f us]   [TB Log] Dang ghi 0x55 vao APB address 0x%08h...", $realtime/1000.0, REG_TXDATA);
            apb_write(REG_TXDATA, 32'h55);

            // 1. Chờ Start bit
            fork : wait_start_bit
                begin
                    @(negedge uart_tx);
                    tx_started = 1'b1;
                    disable wait_start_bit;
                end
                begin
                    #(BIT_PERIOD_NS * 5); // Timeout 5 bit periods
                    disable wait_start_bit;
                end
            join

            if (!tx_started) begin
                $display("[%0.3f us]   [FAIL CRITICAL] UART TX khong bat dau truyen! (uart_tx giu nguyen %b)", $realtime/1000.0, uart_tx);
                check_result("UART TX khoi dong thanh cong", 1'b0);
            end else begin
                $display("[%0.3f us]   [TB Log] Da phat hien Start Bit! Dang doc 10 bit khung truyen...", $realtime/1000.0);

                // 2. Đọc từng bit tại giữa chu kỳ bit (Center sampling)
                for (k = 0; k < 10; k = k + 1) begin
                    if (k == 0) 
                        #(BIT_PERIOD_NS / 2.0); // Nhảy vào giữa Start bit
                    else 
                        #(BIT_PERIOD_NS);       // Nhảy sang giữa bit tiếp theo

                    captured_frame[k] = uart_tx;
                    $display("[%0.3f us]   -> Bit [%0d]: Val = %b", $realtime/1000.0, k, uart_tx);
                end

                // 3. Display kết quả thu được
                $display("[%0.3f us]   -> Cap Frame [Stop..Data..Start]: %b_%08b_%b", 
                         $realtime/1000.0, captured_frame[9], captured_frame[8:1], captured_frame[0]);

                check_result("Start bit phai la Logic 0", captured_frame[0] === 1'b0);
                check_result("Data bit truyen dung pattern 0x55 (01010101)", captured_frame[8:1] === 8'h55);
                check_result("Stop bit phai la Logic 1", captured_frame[9] === 1'b1);
            end

            #(BIT_PERIOD_NS * 2);
            $display("[%0.3f us] ---> END TASK: [TC1] | Total Duration: %0.3f us\n", $realtime/1000.0, ($realtime/1000.0) - start_time_us);
        end
    endtask

    // TC2: Data Pattern Validation (TX)
    task tc_uart_data_pattern(input [7:0] tx_byte);
        integer i;
        reg [9:0] captured;
        reg [7:0] rx_byte;
        real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("==================================================");
            $display("[%0.3f us] ---> START TASK: [TC2] UART Data Pattern TX (0x%02h)", start_time_us, tx_byte);
            $display("==================================================");

            apb_write(REG_TXDATA, {24'b0, tx_byte});

            @(negedge uart_tx);

            for (i = 0; i <= 9; i = i + 1) begin
                if (i == 0)
                    #(BIT_PERIOD_NS / 2.0);
                else
                    #(BIT_PERIOD_NS);

                captured[i] = uart_tx;
            end

            rx_byte = captured[8:1];
            $display("[%0.3f us]   -> Data Gui: 0x%02h | Captured: Start=%b Data=0x%02h Stop=%b", 
                     $realtime/1000.0, tx_byte, captured[0], rx_byte, captured[9]);

            check_result("Xac nhan Khung Du Lieu UART TX gui thanh cong", 
                (captured[0] === 1'b0) && (rx_byte === tx_byte) && (captured[9] === 1'b1));

            #(BIT_PERIOD_NS * 2);
            $display("[%0.3f us] ---> END TASK: [TC2] | Total Duration: %0.3f us\n", $realtime/1000.0, ($realtime/1000.0) - start_time_us);
        end
    endtask

    // TC3: Status Register Verification
    task tc_uart_status_reg;
        reg [31:0] rdata;
        real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("==================================================");
            $display("[%0.3f us] ---> START TASK: [TC3] APB Status Register Verification", start_time_us);
            $display("==================================================");

            apb_read(REG_STATUS, rdata);
            check_result("Status IDLE: Tx Ready (bit 0) == 1", rdata[0] === 1'b1);

            apb_write(REG_TXDATA, 32'hA5);

            apb_read(REG_STATUS, rdata);
            check_result("Status BUSY: Tx Ready (bit 0) == 0", rdata[0] === 1'b0);

            #(11 * BIT_PERIOD_NS);
            apb_read(REG_STATUS, rdata);
            check_result("Status DONE: Tx Ready (bit 0) == 1", rdata[0] === 1'b1);

            $display("[%0.3f us] ---> END TASK: [TC3] | Total Duration: %0.3f us\n", $realtime/1000.0, ($realtime/1000.0) - start_time_us);
        end
    endtask

    // TC4: Receive Data Validation (RX)
    task tc_uart_rx_receive(input [7:0] expected_byte);
        reg [31:0] rdata;
        real start_time_us;
        begin
            start_time_us = $realtime / 1000.0;
            $display("==================================================");
            $display("[%0.3f us] ---> START TASK: [TC4] UART Receive Data RX (0x%02h)", start_time_us, expected_byte);
            $display("==================================================");

            send_uart_rx_byte(expected_byte);

            repeat (5) @(posedge clk);

            apb_read(REG_RXDATA, rdata);
            $display("[%0.3f us]   -> Read REG_RXDATA via APB = 0x%02h (Ky vong: 0x%02h)", $realtime/1000.0, rdata[7:0], expected_byte);

            check_result("Xac nhan UART RX nhan va doc thanh cong qua APB", rdata[7:0] === expected_byte);

            $display("[%0.3f us] ---> END TASK: [TC4] | Total Duration: %0.3f us\n", $realtime/1000.0, ($realtime/1000.0) - start_time_us);
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Simulation Process
    // ------------------------------------------------------------------------
    initial begin
        $display("==================================================");
        $display("      STARTING UART PROTOCOL VERIFICATION         ");
        $display("==================================================");
        $display("[%0.3f us] Simulation Initialized\n", $realtime / 1000.0);
        
        rst_n = 1'b0;
        PADDR = 0; PWDATA = 0; PWRITE = 0; PENABLE = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Run full Testcases Suite
        tc_uart_baud_and_framing;
       //tc_uart_data_pattern(8'hA5);
        //tc_uart_status_reg;
        //tc_uart_rx_receive(8'h3C);

        $display("\n==================================================");
        $display("[%0.3f us] TONG KET UART: PASS %0d / %0d TEST CASES", $realtime / 1000.0, pass_cnt, total_cnt);
        $display("==================================================");
        $finish;
    end

    // Safety Timeout Monitor
    initial begin
        #2_000_000; // 2 ms đủ cho cả 4 Test cases chạy hoàn tất ở 115200 Baud
        $display("\n[%0.3f us] [TIMEOUT] Testbench bi treo qua thoi gian cho phep!", $realtime / 1000.0);
        $finish;
    end

endmodule