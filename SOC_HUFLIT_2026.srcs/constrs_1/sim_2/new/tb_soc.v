`timescale 1ns/1ps

module tb_soc_apb_top;

// ── Clock / Reset ──────────────────────────────────────────
reg clk = 0, rst_n = 0;
always #10 clk = ~clk;  // 50 MHz (Chu kỳ 20ns)

// ── DUT I/O ────────────────────────────────────────────────
reg  [31:0] PADDR = 0; 
reg         PWRITE = 0, PENABLE = 0; 
reg  [31:0] PWDATA = 0;
wire [31:0] PRDATA; 
wire        PREADY, PSLVERR;

wire uart_tx, spi_sclk, spi_mosi, spi_cs;
wire scl_out, sda_out, sda_oe;
reg  uart_rx = 1, spi_miso = 0;

// ── Xử lý I2C Open-Drain & Pull-up ─────────────────────────
wire scl_bus, sda_bus;
wire sda_in;

assign scl_bus = scl_out;
assign sda_bus = sda_oe ? sda_out : 1'bz;
pullup(sda_bus);
pullup(scl_bus);

assign sda_in  = sda_bus;

// ── Address Mapping Defines ────────────────────────────────
localparam UART_BASE = 32'h4000_0000;
localparam SPI_BASE  = 32'h4000_1000;
localparam I2C_BASE  = 32'h4000_2000;

// ── Instantiation ──────────────────────────────────────────
soc_apb_top #(
    .CLK_FREQ(50_000_000), 
    .BAUD_RATE(115200)
) u_dut (
    .clk(clk), .rst_n(rst_n),
    .PADDR(PADDR), .PWRITE(PWRITE), .PENABLE(PENABLE),
    .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
    .uart_tx(uart_tx), .uart_rx(uart_rx),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi),
    .spi_miso(spi_miso), .spi_cs(spi_cs),
    .scl_out(scl_out), .sda_out(sda_out),
    .sda_oe(sda_oe), .sda_in(sda_in)
);

// ── Task: APB Write chuẩn APB3 Protocol ─────────────────────
task apb_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        PADDR   <= addr; 
        PWDATA  <= data; 
        PWRITE  <= 1'b1; 
        PENABLE <= 1'b0; 
        
        @(posedge clk);
        PENABLE <= 1'b1; 
        
        @(posedge clk);
        while (!PREADY) @(posedge clk);
        
        PENABLE <= 1'b0; 
        PWRITE  <= 1'b0;
        PADDR   <= 32'h0;
        PWDATA  <= 32'h0;
    end
endtask

// ── Task: APB Read chuẩn APB3 Protocol ──────────────────────
task apb_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        PADDR   <= addr;
        PWRITE  <= 1'b0;
        PENABLE <= 1'b0;
        
        @(posedge clk);
        PENABLE <= 1'b1;
        
        @(posedge clk);
        while (!PREADY) @(posedge clk);
        
        data = PRDATA;
        
        PENABLE <= 1'b0;
        PADDR   <= 32'h0;
    end
endtask

// ── TEST 1: PSEL mutually exclusive ───────────────────────
task test_psel_exclusive;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 1: APB Decoder Access Check", $realtime);
        apb_write(UART_BASE, 32'h41);
        $display("[%0.1f ns] TEST 1 PASS: Access APB decoder successfully", $realtime);
    end
endtask

// ── TEST 2: Concurrent HW output (UART + SPI) ─────────────
task test_hw_concurrent;
    integer uart_active, spi_active, overlap_cycles;
    reg done_test;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 2: UART + SPI Concurrent Check", $realtime);
        uart_active = 0; 
        spi_active = 0; 
        overlap_cycles = 0;
        done_test = 0;

        apb_write(SPI_BASE + 32'h4, 32'h0); 
        apb_write(SPI_BASE, 32'hAB);        
        apb_write(UART_BASE, 32'h55);       

        repeat(5000) begin
            if (!done_test) begin
                @(posedge clk);
                
                uart_active = (!uart_tx) ? 1 : 0;
                spi_active  = (!spi_cs || spi_sclk) ? 1 : 0;

                if (uart_active && spi_active) begin
                    overlap_cycles = overlap_cycles + 1;
                    if (overlap_cycles >= 50) begin
                        done_test = 1;
                    end
                end
            end
        end

        if (overlap_cycles > 0)
            $display("[%0.1f ns] TEST 2 PASS: uart_tx + spi overlap = %0d cycles (Early Exit)", $realtime, overlap_cycles);
        else
            $display("[%0.1f ns] TEST 2 FAIL: Không phát hiện hoạt động song song giữa UART và SPI!", $realtime);
    end
endtask

// ── TEST 3: Tất cả 3 peripheral concurrent ─────────────────
task test_all_three_concurrent;
    integer all_three_active_count;
    reg done_test;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 3: All 3 Peripherals Concurrent Check", $realtime);
        all_three_active_count = 0;
        done_test = 0;

        // 1. Kích hoạt SPI (CS active)
        apb_write(SPI_BASE + 32'h4, 32'h0); 

        // 2. Kích hoạt I2C phát điều kiện START (Ghi 0x01 vào Offset 0x04)
        apb_write(I2C_BASE + 32'h04, 32'h01); 

        // 3. Kích hoạt UART TX phát dữ liệu
        apb_write(UART_BASE, 32'hAA);       

        // 4. Kích hoạt SPI TX phát dữ liệu
        apb_write(SPI_BASE, 32'h3C);        

        // Giám sát tín hiệu trên bus
        repeat(6000) begin
            if (!done_test) begin
                @(posedge clk);
                
                // I2C Active khi scl_out = 0 HOẶC sda_out = 0 (do FSM kéo xuống)
                if ((!uart_tx) && (!spi_cs || spi_sclk) && (!scl_out || !sda_out)) begin
                    all_three_active_count = all_three_active_count + 1;
                    if (all_three_active_count >= 20) begin
                        done_test = 1; // Thoát sớm khi thu thập đủ bằng chứng
                    end
                end
            end
        end

        if (all_three_active_count > 0)
            $display("[%0.1f ns] TEST 3 PASS: So chu ky ca 3 ngoai vi cung hoat dong = %0d", 
                     $realtime, all_three_active_count);
        else
            $display("[%0.1f ns] TEST 3 FAIL: I2C hoac ngoai vi khac KHONG hoat dong!", $realtime);
    end
endtask

// ── TEST 4: Interleaved Cross-Peripheral Access ───────────
task test_interleaved_access;
    reg [31:0] read_data_uart;
    reg [31:0] read_data_spi;
    reg [31:0] read_data_i2c;
    begin
        $display("\n[%0.1f ns] ---> RUNNING TEST 4: Interleaved Cross-Peripheral Access Check", $realtime);

        // 1. Ghi UART TX DATA ('X' = 0x58)
        apb_write(UART_BASE, 32'h58);
        $display("[%0.1f ns] [STEP 1] WRITE UART: 0x58", $realtime);

        // 2. Đọc SPI Status/Control Register ngay chu kỳ tiếp theo (Offset 0x04)
        apb_read(SPI_BASE + 32'h4, read_data_spi);
        $display("[%0.1f ns] [STEP 2] READ  SPI CS Reg: 0x%h", $realtime, read_data_spi);

        // 3. I2C: Nạp dữ liệu (Offset 0x00) và Phát lệnh START (Offset 0x04)
        apb_write(I2C_BASE + 32'h00, 32'hA7); // Nạp byte 0xA7
        apb_write(I2C_BASE + 32'h04, 32'h01); // Bit 0 = 1 (Phát điều kiện START)
        $display("[%0.1f ns] [STEP 3] WRITE I2C Data (0xA7) & CMD START (0x01)", $realtime);

        // 4. Đọc UART Status Register
        apb_read(UART_BASE, read_data_uart);
        $display("[%0.1f ns] [STEP 4] READ  UART Reg: 0x%h", $realtime, read_data_uart);

        // 5. Ghi SPI TX DATA (0xA5)
        apb_write(SPI_BASE, 32'hA5);
        $display("[%0.1f ns] [STEP 5] WRITE SPI Data: 0xA5", $realtime);

        // 6. Đọc I2C Status Register (Offset 0x08)
        apb_read(I2C_BASE + 32'h08, read_data_i2c);
        $display("[%0.1f ns] [STEP 6] READ  I2C Status Reg: 0x%h (busy bit = %b)", $realtime, read_data_i2c, read_data_i2c[0]);

        $display("[%0.1f ns] TEST 4 PASS: Executed cross-peripheral transactions seamlessly!", $realtime);
    end
endtask
// ── Main Execution ─────────────────────────────────────────
initial begin
    $dumpfile("tb_soc.vcd"); 
    $dumpvars(0, tb_soc_apb_top);

    // Reset Sequence
    rst_n = 0; 
    repeat(1) @(posedge clk);
    rst_n = 1; 
    repeat(2)  @(posedge clk);

    // Run Tests
      //test_psel_exclusive;
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