`timescale 1ns/1ps

module tb_i2c;
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

    // Tín hiệu giao tiếp I2C
    wire        scl_out, sda_out, sda_oe;
    reg         sda_in = 1'b1;

    integer test_total = 0;
    integer test_pass  = 0;

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
        .spi_sclk (), .spi_mosi (), .spi_miso (1'b0), .spi_cs   (),
        .scl_out  (scl_out), .sda_out  (sda_out), .sda_oe   (sda_oe), .sda_in   (sda_in)
    );

    localparam REG_I2C_DATA   = 32'h4000_2000;
    localparam REG_I2C_CMD    = 32'h4000_2004;
    localparam REG_I2C_STATUS = 32'h4000_2008;

    task report(input passed);
        begin
            test_total = test_total + 1;
            if (passed) begin test_pass = test_pass + 1; $display("  -> [PASS] (At %0.3f us)", $realtime/1000.0); end 
            else $display("  -> [FAIL] (At %0.3f us)", $realtime/1000.0);
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

    task wait_i2c_busy_low;
        reg [31:0] st; integer guard;
        begin
            guard = 0; st = 32'h1;
            while (st[0] == 1'b1 && guard < 1000) begin axi_read(REG_I2C_STATUS, st); guard = guard + 1; end
        end
    endtask

    // TC1: Ghi/đọc thanh ghi dữ liệu I2C qua AXI
    task test_i2c_data_register;
        reg [31:0] rdata;
        begin
            axi_write(REG_I2C_DATA, 32'hA7);
            axi_read(REG_I2C_DATA, rdata);
            $display("\n[%0.3f us] [TC1] I2C - Ghi/doc thanh ghi du lieu = 0xA7, doc lai = 0x%02h", $realtime/1000.0, rdata[7:0]);
            report(rdata[7:0] === 8'hA7);
        end
    endtask

    // TC2: Kiểm tra Điều kiện START
    task test_i2c_start;
        reg scl_during_fall;
        begin
            axi_write(REG_I2C_CMD, 32'h1); 
            @(negedge sda_out);
            scl_during_fall = scl_out;
            $display("\n[%0.3f us] [TC2] I2C - START: SDA roi xuong luc SCL=%b (ky vong 1)", $realtime/1000.0, scl_during_fall);
            report(scl_during_fall === 1'b1);
            wait_i2c_busy_low;
        end
    endtask

    // TC3: Ghi byte + ACK/NACK
    task test_i2c_write_and_ack(input [7:0] data_byte, input drive_ack);
        reg [31:0] rdata;
        begin
            axi_write(REG_I2C_DATA, {24'b0, data_byte});
            fork
                begin axi_write(REG_I2C_CMD, 32'h4); end
                begin @(negedge sda_oe); sda_in = drive_ack; end
            join
            wait_i2c_busy_low;
            axi_read(REG_I2C_STATUS, rdata);
            $display("\n[%0.3f us] [TC3] I2C - Ghi byte 0x%02h + ACK/NACK: rx_ack=%b (ky vong %b)", $realtime/1000.0, data_byte, rdata[1], drive_ack);
            report(rdata[1] === drive_ack);
            sda_in = 1'b1;
        end
    endtask

    // TC4: Kiểm tra Điều kiện STOP
    task test_i2c_stop;
        reg scl_is_high;
        begin
            axi_write(REG_I2C_CMD, 32'h2); 
            @(posedge sda_out);
            scl_is_high = scl_out;
            $display("\n[%0.3f us] [TC4] I2C - STOP: SDA nay len 1 luc SCL=%b (ky vong 1)", $realtime/1000.0, scl_is_high);
            report(scl_is_high === 1'b1);
            wait_i2c_busy_low;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);

        //test_i2c_data_register;
        //test_i2c_start;
        //test_i2c_write_and_ack(8'h3C, 1'b0); // Giả lập ACK (sda_in = 0)
        //test_i2c_write_and_ack(8'h3C, 1'b1); // Giả lập NACK (sda_in = 1)
        test_i2c_stop;

        $display("\n--------------------------------------------------");
        $display("TONG KET I2C: %0d/%0d test case PASS", test_pass, test_total);
        if (test_pass == test_total) $display("=> TAT CA TEST CASE DEU PASS");
        else $display("=> CO %0d TEST CASE FAIL", test_total - test_pass);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #500000;
        $display("\n[%0.3f us] TB FAIL: Timeout - Simulation bi treo!", $realtime/1000.0);
        $finish;
    end
endmodule