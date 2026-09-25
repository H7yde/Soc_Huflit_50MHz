`timescale 1ns / 1ps

module tb_parallel;
    // Localparam
    localparam REG_CTRL = 32'h00, REG_A = 32'h10, REG_B = 32'h20, REG_RES = 32'h30;

    // Signals
    reg clk = 0, rst_n = 0;
    reg [31:0] PADDR = 0, PWDATA = 0;
    reg PWRITE = 0, PSEL = 0, PENABLE = 0;
    wire [31:0] PRDATA;
    wire [31:0] ddr_data;
    wire PREADY, result_valid, ddr_done;
    wire ddr_valid;

    // Stats & Data Setup
    integer test_total = 0, test_pass = 0, ddr_sample_count = 0, i=0;
    reg [31:0] a_vals       [0:3];
    reg [31:0] b_vals       [0:3];
    reg [31:0] sum_expected [0:3];
    reg [31:0] dummy_data=32'h0;
    reg [31:0] read_data=32'h0;

    // DUT Instantiation
    parallel dut (
        .clk(clk), .rst_n(rst_n), .PADDR(PADDR), .PWRITE(PWRITE), 
        .PSEL(PSEL), .PENABLE(PENABLE), .PWDATA(PWDATA), .PRDATA(PRDATA), 
        .PREADY(PREADY), .PSLVERR(), .result_out(), .result_valid(result_valid), 
        .ddr_data(ddr_data), .ddr_clk_out(), .ddr_valid(ddr_valid), .ddr_done(ddr_done)
    );

    // Clock Generation (T = 10ns)
    always #5 clk = ~clk;

    // Task Report Tối Giản
    task check_result;
        input passed;
        input [31:0] val_got;
        input [31:0] val_exp;
        begin
            test_total = test_total + 1;
            if (passed) begin
                test_pass = test_pass + 1;
                $display("[%0t ns] [PASS] Value = %08h (Expected: %08h)", $time, val_got, val_exp);
            end else begin
                $display("[%0t ns] [FAIL] Value = %08h (Expected: %08h)", $time, val_got, val_exp);
            end
        end
    endtask

    // Task APB Write/Read Gộp Ngắn Gọn
    task apb_trans;
        input is_write;
        input [31:0] addr;
        input [31:0] wdata;
        output [31:0] rdata;
        begin
            @(negedge clk);
            PADDR <= addr; PWDATA <= wdata; PWRITE <= is_write; PSEL <= 1'b1; PENABLE <= 1'b0;
            @(negedge clk);
            PENABLE <= 1'b1; // PENABLE = 1
            PENABLE <= 1'b1;
            while (!PREADY) @(negedge clk);
            rdata = PRDATA;
            @(negedge clk);
            PSEL <= 0; PENABLE <= 0; PWRITE <= 0; PADDR <= 0; PWDATA <= 0;
        end
    endtask

    // Monitor DDR Sample: Bắt chính xác theo từng xung ddr_valid
    initial begin
        @(posedge rst_n); // Chờ giải phóng Reset
        
        for (ddr_sample_count = 0; ddr_sample_count < 4; ddr_sample_count = ddr_sample_count + 1) begin
            @(posedge ddr_valid); // Chỉ kích hoạt khi ddr_valid thực sự lên 1
            #0.1;                 // Trễ nhẹ để ddr_data trên bus định hình hoàn toàn
            
            $write("[%0t ns] [DDR Sample %0d] ", $time, ddr_sample_count);
            check_result(ddr_data === sum_expected[ddr_sample_count], ddr_data, sum_expected[ddr_sample_count]);
            
            @(negedge ddr_valid); // Chờ ddr_valid hạ xuống trước khi bắt mẫu tiếp theo
        end
    end

    // Main Test Sequence
    initial begin
        // Khởi tạo mảng dữ liệu
        a_vals[0] = 32'h01; b_vals[0] = 32'h10; sum_expected[0] = 32'h11;
        a_vals[1] = 32'h02; b_vals[1] = 32'h20; sum_expected[1] = 32'h22;
        a_vals[2] = 32'h03; b_vals[2] = 32'h30; sum_expected[2] = 32'h33;
        a_vals[3] = 32'h04; b_vals[3] = 32'h40; sum_expected[3] = 32'h44;

        // Reset
        repeat (3) @(posedge clk); 
        @(negedge clk) rst_n = 1'b1; 
        repeat (2) @(posedge clk);

        // 1. Ghi tham số A/B
        for (i = 0; i < 4; i = i + 1) begin
            apb_trans(1'b1, REG_A + i*4, a_vals[i], dummy_data);
            apb_trans(1'b1, REG_B + i*4, b_vals[i], dummy_data);
        end

        // 2. Kích hoạt START = 1
        apb_trans(1'b1, REG_CTRL, 32'h1, dummy_data);

        // 3. Chờ ddr_done
        begin : WAIT_DDR
            integer timeout;
            timeout = 0;
            while (!ddr_done && timeout < 200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 200)
                $display("[%0t ns] [WARNING] Timeout ddr_done!", $time);
        end

        // 4. Đọc & Check kết quả APB
        for (i = 0; i < 4; i = i + 1) begin
            apb_trans(1'b0, REG_RES + i*4, 32'h0, read_data);
            $write("[%0t ns] [APB Read Addr %02h] ", $time, REG_RES + i*4);
            check_result(read_data === sum_expected[i], read_data, sum_expected[i]);
        end

        // 5. Check cờ result_valid
        test_total = test_total + 1;
        if (result_valid === 1'b0) begin
            test_pass = test_pass + 1;
            $display("[%0t ns] [PASS] Flag result_valid auto cleared", $time);
        end else begin
            $display("[%0t ns] [FAIL] Flag result_valid NOT cleared", $time);
        end

        // Summary & Finish
        $display("\n==================================================");
        $display(" TONG KET: %0d/%0d PASS", test_pass, test_total);
        $display("==================================================\n");
        $finish;
    end

    // Safety Timeout
    initial begin #1000000; $display("\n[ERROR] TIMEOUT!"); $finish; end

endmodule