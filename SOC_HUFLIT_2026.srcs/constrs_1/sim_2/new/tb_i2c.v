`timescale 1ns/1ps

module tb_i2c;

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

    // Tín hiệu giao tiếp I2C
    wire        scl_out, sda_out, sda_oe;
    reg         sda_in = 1'b1;

    // Biến quản lý Test Case
    integer test_total = 0;
    integer test_pass  = 0;

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
        
        // SPI Interface - Unconnected
        .spi_sclk (), 
        .spi_mosi (), 
        .spi_miso (1'b0), 
        .spi_cs   (),
        
        // I2C Interface
        .scl_out  (scl_out), 
        .sda_out  (sda_out), 
        .sda_oe   (sda_oe), 
        .sda_in   (sda_in)
    );

    // Địa chỉ các thanh ghi I2C
    localparam REG_I2C_DATA   = 32'h4000_2000;
    localparam REG_I2C_CMD    = 32'h4000_2004;
    localparam REG_I2C_STATUS = 32'h4000_2008;

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

    task wait_i2c_busy_low;
        reg [31:0] st;
        integer guard;
        begin
            guard = 0;
            st = 32'h1;
            while (st[0] == 1'b1 && guard < 1000) begin
                apb_read(REG_I2C_STATUS, st);
                guard = guard + 1;
            end
        end
    endtask

    // -----------------------------------------------------------
    // TC1: Ghi/đọc thanh ghi dữ liệu I2C qua APB
    // -----------------------------------------------------------
    task test_i2c_data_register;
        reg [31:0] rdata;
        begin
            apb_write(REG_I2C_DATA, 32'hA7);
            apb_read(REG_I2C_DATA, rdata);
            $display("\n[%0.3f us] [TC1] I2C - Ghi/doc thanh ghi du lieu = 0xA7, doc lai = 0x%02h", $realtime/1000.0, rdata[7:0]);
            report(rdata[7:0] === 8'hA7);
        end
    endtask

    // -----------------------------------------------------------
    // TC2: Kiểm tra Điều kiện START
    // -----------------------------------------------------------
    task test_i2c_start;
        reg scl_during_fall;
        begin
            // Bắn lệnh START
            apb_write(REG_I2C_CMD, 32'h1); // Bit0 = Lệnh START

            // Kiểm tra điều kiện START: SDA kéo xuống 0 khi SCL đang giữ ở mức 1
            @(negedge sda_out);
            scl_during_fall = scl_out;

            $display("\n[%0.3f us] [TC2] I2C - START: SDA roi xuong luc SCL=%b (ky vong 1)", $realtime/1000.0, scl_during_fall);
            report(scl_during_fall === 1'b1);

            wait_i2c_busy_low;
        end
    endtask

    // -----------------------------------------------------------
    // TC3: Ghi byte + ACK/NACK
    // -----------------------------------------------------------
    task test_i2c_write_and_ack(input [7:0] data_byte, input drive_ack);
        reg [31:0] rdata;
        begin
            apb_write(REG_I2C_DATA, {24'b0, data_byte});
            
            // Ép sda_in ngay khi sda_oe thả nổi (State 6)
            fork
                begin
                    apb_write(REG_I2C_CMD, 32'h4); // Bit2 = Lệnh ghi byte
                end
                begin
                    @(negedge sda_oe);
                    sda_in = drive_ack; // Slave kéo SDA xuống (0=ACK, 1=NACK)
                end
            join

            wait_i2c_busy_low;

            apb_read(REG_I2C_STATUS, rdata);
            if (drive_ack)
                $display("\n[%0.3f us] [TC3] I2C - Ghi byte 0x%02h + NACK tu Slave: rx_ack=%b (ky vong 1)", $realtime/1000.0, data_byte, rdata[1]);
            else
                $display("\n[%0.3f us] [TC3] I2C - Ghi byte 0x%02h + ACK tu Slave: rx_ack=%b (ky vong 0)", $realtime/1000.0, data_byte, rdata[1]);
            
            report(rdata[1] === drive_ack);
            sda_in = 1'b1; // Reset lại bus float
        end
    endtask

    // -----------------------------------------------------------
    // TC4: Kiểm tra Điều kiện STOP
    // -----------------------------------------------------------
    task test_i2c_stop;
        reg scl_is_high;
        begin
            // Bắn lệnh STOP
            apb_write(REG_I2C_CMD, 32'h2); // Bit1 = Lệnh STOP

            // Bắt sự kiện SDA nảy lên 1 trong khi SCL đang ở mức 1
            @(posedge sda_out);
            scl_is_high = scl_out;

            $display("\n[%0.3f us] [TC4] I2C - STOP: SDA nay len 1 luc SCL=%b (ky vong 1)", $realtime/1000.0, scl_is_high);
            report(scl_is_high === 1'b1);

            wait_i2c_busy_low;
        end
    endtask

    // -----------------------------------------------------------
    // Main Simulation Process
    // -----------------------------------------------------------
    initial begin
        rst_n = 1'b0;
        PADDR = 0; PWDATA = 0; PWRITE = 0; PENABLE = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //test_i2c_data_register;
        //test_i2c_start;
        // test_i2c_write_and_ack(8'h3C, 1'b0); // Giả lập ACK (sda_in = 0)
        test_i2c_write_and_ack(8'h3C, 1'b1); // Giả lập NACK (sda_in = 1)
        //test_i2c_stop;

        $display("\n--------------------------------------------------");
        $display("TONG KET I2C: %0d/%0d test case PASS", test_pass, test_total);
        if (test_pass == test_total)
            $display("=> TAT CA TEST CASE DEU PASS");
        else
            $display("=> CO %0d TEST CASE FAIL", test_total - test_pass);
        $display("--------------------------------------------------");
        $finish;
    end

    // Safety Timeout Guard (500 us)
    initial begin
        #500000;
        $display("\n[%0.3f us] TB FAIL: Timeout - Simulation bi treo!", $realtime/1000.0);
        $finish;
    end

endmodule