`timescale 1ns/1ps

module tb_spi;

    localparam CLK_PERIOD_NS = 20;

    reg clk = 0;
    reg rst_n = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Tín hiệu giao tiếp APB Bus
    reg  [31:0] PADDR;
    reg         PWRITE, PENABLE;
    reg  [31:0] PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    // Tín hiệu giao tiếp SPI - Trọng tâm kiểm thử
    wire        spi_sclk, spi_mosi, spi_cs;
    reg         spi_miso = 1'b0;

    // Biến quản lý Test Case
    integer test_total = 0;
    integer test_pass  = 0;

    // FIX LỖI 90ns: Khởi tạo giá trị ban đầu ngay từ 0ns
    reg [7:0] slave_pattern = 8'h00;
    integer   slave_bit_idx = 0;

    // -----------------------------------------------------------
    // Instantiate SOC TOP
    // -----------------------------------------------------------
    soc_apb_top #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115200)
    ) dut (
        .clk      (clk), 
        .rst_n    (rst_n),
        
        // APB Interface
        .PADDR    (PADDR), 
        .PWRITE   (PWRITE), 
        .PENABLE  (PENABLE),
        .PWDATA   (PWDATA), 
        .PRDATA   (PRDATA), 
        .PREADY   (PREADY), 
        .PSLVERR  (PSLVERR),
        
        // UART Interface - Unconnected
        .uart_tx  (), 
        .uart_rx  (1'b1),
        
        // SPI Interface
        .spi_sclk (spi_sclk), 
        .spi_mosi (spi_mosi), 
        .spi_miso (spi_miso), 
        .spi_cs   (spi_cs),
        
        // I2C Interface - Unconnected
        .scl_out  (), 
        .sda_out  (), 
        .sda_oe   (), 
        .sda_in   (1'b1)
    );

    // Địa chỉ các thanh ghi SPI
    localparam REG_SPI_TXDATA = 32'h4000_1000;
    localparam REG_SPI_CS     = 32'h4000_1004;
    localparam REG_SPI_STATUS = 32'h4000_1008;

    // -----------------------------------------------------------
    // Helper Tasks
    // -----------------------------------------------------------
    task report(input passed);
        begin
            test_total = test_total + 1;
            if (passed) begin
                test_pass = test_pass + 1;
                $display("  -> [PASS] (At %0.3f us)", $realtime/1000.0);
            end else begin
                $display("  -> [FAIL] (At %0.3f us)", $realtime/1000.0);
            end
        end
    endtask

    task apb_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            PADDR = addr; PWDATA = data; PWRITE = 1'b1; PENABLE = 1'b0;
            @(posedge clk);
            PENABLE = 1'b1;
            @(posedge clk);
            PENABLE = 1'b0; PWRITE = 1'b0;
        end
    endtask

    task apb_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(posedge clk);
            PADDR = addr; PWRITE = 1'b0; PENABLE = 1'b0;
            @(posedge clk);
            PENABLE = 1'b1;
            @(posedge clk);
            rdata = PRDATA;
            PENABLE = 1'b0;
        end
    endtask

    task wait_spi_busy_low;
        reg [31:0] st;
        integer guard;
        begin
            guard = 0;
            st = 32'h1;
            while (st[0] == 1'b1 && guard < 500) begin
                apb_read(REG_SPI_STATUS, st);
                guard = guard + 1;
            end
        end
    endtask

    // Slave giả lập: đưa ra pattern 8-bit qua spi_miso, thay đổi trên cạnh xuống spi_sclk
    task load_slave_pattern(input [7:0] pattern);
        begin
            slave_pattern = pattern;
            slave_bit_idx = 7;
            spi_miso = pattern[7]; // Sẵn sàng trước cạnh lên đầu tiên
        end
    endtask

    always @(negedge spi_sclk or negedge rst_n) begin
        if (!rst_n) begin
            slave_bit_idx <= 0;
        end else if (slave_bit_idx > 0) begin
            slave_bit_idx <= slave_bit_idx - 1;
            spi_miso      <= slave_pattern[slave_bit_idx - 1];
        end
    end

    // -----------------------------------------------------------
    // TC1 & TC2: Kiểm tra truyền Full-Duplex SPI
    // -----------------------------------------------------------
    task test_spi_transfer(input [7:0] tx_byte, input [7:0] rx_pattern);
        integer i;
        reg [7:0] captured_mosi;
        reg [31:0] rdata;
        reg cpol_ok;
        begin
            cpol_ok = (spi_sclk === 1'b0);
            $display("\n[%0.3f us] [TC1] SPI - CPOL: SCLK idle truoc khi truyen = %b (ky vong 0)", $realtime/1000.0, spi_sclk);
            report(cpol_ok);

            load_slave_pattern(rx_pattern);

            apb_write(REG_SPI_CS, 32'h0);               // CS = 0 -> Chọn chip
            apb_write(REG_SPI_TXDATA, {24'b0, tx_byte}); // Bắt đầu truyền

            for (i = 0; i <= 7; i = i + 1) begin
                @(posedge spi_sclk);
                captured_mosi[7-i] = spi_mosi; // Sample bit MOSI tại cạnh lên
            end

            $display("\n[%0.3f us] [TC2] SPI - Vi tri bit MOSI (MSB first) gui=0x%02h, nhan=0x%02h", 
                     $realtime/1000.0, tx_byte, captured_mosi);
            report(captured_mosi === tx_byte);

            wait_spi_busy_low;
            apb_write(REG_SPI_CS, 32'h1); // CS = 1 -> Nhả chip

            apb_read(REG_SPI_TXDATA, rdata); // Đọc dữ liệu nhận được từ MISO
            $display("\n[%0.3f us] [TC2] SPI - Du lieu MISO nhan duoc = 0x%02h (ky vong 0x%02h)", 
                     $realtime/1000.0, rdata[7:0], rx_pattern);
            report(rdata[7:0] === rx_pattern);
        end
    endtask
    
    // -----------------------------------------------------------
    // TC3: Kiểm tra ghi/đọc thanh ghi CS
    // -----------------------------------------------------------
    task test_spi_cs_register;
        reg [31:0] rdata;
        begin
            apb_write(REG_SPI_CS, 32'h0);
            apb_read(REG_SPI_CS, rdata);
            $display("\n[%0.3f us] [TC3] SPI - Ghi/doc thanh ghi CS = 0: doc lai = %0d (ky vong 0)", $realtime/1000.0, rdata[0]);
            report(rdata[0] === 1'b0);
            apb_write(REG_SPI_CS, 32'h1);
            apb_read(REG_SPI_CS, rdata);
            $display("\n[%0.3f us] [TC3] SPI - Ghi/doc thanh ghi CS = 1: doc lai = %0d (ky vong 1)", $realtime/1000.0, rdata[0]);
            report(rdata[0] === 1'b1);
        end
    endtask
    // -----------------------------------------------------------
    // Main Simulation Process
    // -----------------------------------------------------------
    initial begin
        // Khởi tạo các tín hiệu bus APB tại 0ns
        rst_n = 1'b0;
        PADDR = 32'h0; PWDATA = 32'h0; PWRITE = 1'b0; PENABLE = 1'b0;
        
        // Khởi tạo trạng thái Slave tại 0ns
        slave_pattern = 8'h00;
        slave_bit_idx = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

      test_spi_cs_register;
        $display("\n--------------------------------------------------");
        $display("TONG KET SPI: %0d/%0d test case PASS", test_pass, test_total);
        if (test_pass == test_total)
            $display("=> TAT CA TEST CASE DEU PASS");
        else
            $display("=> CO %0d TEST CASE FAIL", test_total - test_pass);
        $display("--------------------------------------------------");
        $finish;
    end

    // Safety Timeout Guard (200 us)
    initial begin
        #200000;
        $display("\n[%0.3f us] TB FAIL: timeout.", $realtime/1000.0);
        $finish;
    end

endmodule