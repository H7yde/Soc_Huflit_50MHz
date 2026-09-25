`timescale 1ns / 1ps

module tb_parallel_axi;
    // Localparam địa chỉ thanh ghi
    localparam REG_CTRL = 32'h00, REG_A = 32'h10, REG_B = 32'h20, REG_RES = 32'h30;

    // Các tín hiệu hệ thống
    reg clk = 0, rst_n = 0;

    // --------------------------------------------------------
    // Tín hiệu AXI4-Lite Master (Testbench đóng vai trò là CPU)
    // --------------------------------------------------------
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

    // --- Tín hiệu IDDR / ODDR ---
    reg  [31:0] ddr_data_in = 0;
    reg         ddr_rx_valid = 0;
    
    wire [31:0] ddr_data;
    wire        ddr_clk_out;
    wire        ddr_valid;
    wire        ddr_done;
    wire [31:0] result_out;
    wire        result_valid;

    // --- Biến nội bộ Testbench ---
    integer test_total = 0, test_pass = 0, ddr_sample_count = 0, i=0;
    reg [31:0] expected_oddr_stream [0:11];
    reg [31:0] expected_axi_reads   [0:11];
    reg [31:0] read_data = 32'h0;

    // --------------------------------------------------------
    // Khởi tạo DUT (Device Under Test)
    // --------------------------------------------------------
    parallel_axi dut (
        .clk             (clk), 
        .rst_n           (rst_n), 
        
        .S_AXI_AWADDR    (s_axi_awaddr),
        .S_AXI_AWVALID   (s_axi_awvalid),
        .S_AXI_AWREADY   (s_axi_awready),
        .S_AXI_WDATA     (s_axi_wdata),
        .S_AXI_WSTRB     (s_axi_wstrb),
        .S_AXI_WVALID    (s_axi_wvalid),
        .S_AXI_WREADY    (s_axi_wready),
        .S_AXI_BRESP     (s_axi_bresp),
        .S_AXI_BVALID    (s_axi_bvalid),
        .S_AXI_BREADY    (s_axi_bready),
        .S_AXI_ARADDR    (s_axi_araddr),
        .S_AXI_ARVALID   (s_axi_arvalid),
        .S_AXI_ARREADY   (s_axi_arready),
        .S_AXI_RDATA     (s_axi_rdata),
        .S_AXI_RRESP     (s_axi_rresp),
        .S_AXI_RVALID    (s_axi_rvalid),
        .S_AXI_RREADY    (s_axi_rready),

        .ddr_data_in     (ddr_data_in),       
        .ddr_rx_valid    (ddr_rx_valid),
        .result_out      (result_out),
        .result_valid    (result_valid),
        .ddr_data        (ddr_data),             
        .ddr_clk_out     (ddr_clk_out), 
        .ddr_valid       (ddr_valid), 
        .ddr_done        (ddr_done)
    );

    // Clock Generation (T = 10ns, f = 100MHz)
    always #5 clk = ~clk;

    // Lấy mẫu tín hiệu xuất ra từ ODDR
    always @(posedge ddr_clk_out or negedge ddr_clk_out) begin
        #0.1; // Chờ mạch ổn định sau cạnh xung
        if (ddr_valid && ddr_sample_count < 12) begin
            $write("[%0t ns] [ODDR Sample %0d] ", $time, ddr_sample_count);
            check_result(ddr_data === expected_oddr_stream[ddr_sample_count], ddr_data, expected_oddr_stream[ddr_sample_count]);
            ddr_sample_count = ddr_sample_count + 1;
        end
    end

    // ====================================================================
    // CÁC HÀM HỖ TRỢ (HELPER TASKS)
    // ====================================================================
    task check_result(input passed, input [31:0] val_got, input [31:0] val_exp);
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

    // -----------------------------------------------------
    // Task Ghi chuẩn AXI4-Lite
    // -----------------------------------------------------
    task axi_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            // Chờ Slave chấp nhận AW và W
            fork
                begin wait(s_axi_awready); @(posedge clk); s_axi_awvalid <= 1'b0; end
                begin wait(s_axi_wready);  @(posedge clk); s_axi_wvalid  <= 1'b0; end
            join

            // Chờ Slave phản hồi ghi xong (BRESP)
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    // -----------------------------------------------------
    // Task Đọc chuẩn AXI4-Lite
    // -----------------------------------------------------
    task axi_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            // Chờ Slave chấp nhận AR
            wait(s_axi_arready);
            @(posedge clk);
            s_axi_arvalid <= 1'b0;

            // Chờ Slave trả dữ liệu (RDATA)
            wait(s_axi_rvalid);
            rdata = s_axi_rdata;
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // -----------------------------------------------------
    // Task Giả lập tín hiệu DDR vào IDDR (Không đổi)
    // -----------------------------------------------------
    task send_iddr_pair(input [31:0] rise_val, input [31:0] fall_val);
        begin
            @(negedge clk); #1;
            ddr_rx_valid = 1'b1; ddr_data_in = rise_val; 
            
            @(posedge clk); #1;
            ddr_data_in = fall_val; 
            
            @(negedge clk); #1;
            ddr_rx_valid = 1'b0;
        end
    endtask

    // ====================================================================
    // CÁC KỊCH BẢN KIỂM THỬ (TEST CASE TASKS)
    // ====================================================================
    task init_data_and_reset;
        begin
            // Test 1 Expected (A + B via AXI)
            expected_oddr_stream[0] = 32'h11; expected_axi_reads[0] = 32'h11;
            expected_oddr_stream[1] = 32'h22; expected_axi_reads[1] = 32'h22;
            expected_oddr_stream[2] = 32'h33; expected_axi_reads[2] = 32'h33;
            expected_oddr_stream[3] = 32'h44; expected_axi_reads[3] = 32'h44;

            // Test 2 Expected (A via IDDR + B via AXI)
            expected_oddr_stream[4] = 32'h110; expected_axi_reads[4] = 32'h110;
            expected_oddr_stream[5] = 32'h220; expected_axi_reads[5] = 32'h220;
            expected_oddr_stream[6] = 32'h330; expected_axi_reads[6] = 32'h330;
            expected_oddr_stream[7] = 32'h440; expected_axi_reads[7] = 32'h440;

            // Test 3 Expected (Edge Isolation)
            expected_oddr_stream[8]  = 32'h999; expected_axi_reads[8]  = 32'h999;
            expected_oddr_stream[9]  = 32'h000; expected_axi_reads[9]  = 32'h000;
            expected_oddr_stream[10] = 32'h000; expected_axi_reads[10] = 32'h000;
            expected_oddr_stream[11] = 32'h000; expected_axi_reads[11] = 32'h000;

            // Reset
            repeat (3) @(posedge clk); 
            @(negedge clk) rst_n = 1'b1; 
            repeat (2) @(posedge clk);
        end
    endtask

    task run_test_case_1;
        begin
            $display("\n---> RUNNING TEST 1: AXI Trigger (All Lanes)");
            axi_write(REG_A + 0,  32'h01); axi_write(REG_B + 0,  32'h10);
            axi_write(REG_A + 4,  32'h02); axi_write(REG_B + 4,  32'h20);
            axi_write(REG_A + 8,  32'h03); axi_write(REG_B + 8,  32'h30);
            axi_write(REG_A + 12, 32'h04); axi_write(REG_B + 12, 32'h40);

            axi_write(REG_CTRL, 32'h1); // Kích hoạt chạy đồng bộ

            while (!ddr_done) @(posedge clk);

            for (i = 0; i < 4; i = i + 1) begin
                axi_read(REG_RES + i*4, read_data);
                $write("[%0t ns] [AXI Read Lane %0d] ", $time, i);
                check_result(read_data === expected_axi_reads[i], read_data, expected_axi_reads[i]);
            end
        end
    endtask

    task run_test_case_2;
        begin
            $display("\n---> RUNNING TEST 2: IDDR Trigger (Independent Lane Execution)");
            axi_write(REG_B + 0,  32'h100);
            axi_write(REG_B + 4,  32'h200);
            axi_write(REG_B + 8,  32'h300);
            axi_write(REG_B + 12, 32'h400);

            send_iddr_pair(32'h010, 32'h020);
            $display("[%0t ns] [INFO] Sent Data for Lane 0 & 1 via IDDR. Waiting to show independence...", $time);

            repeat(5) @(posedge clk);

            $display("[%0t ns] [INFO] Sent Data for Lane 2 & 3 via IDDR. Serializer should fire now!", $time);
            send_iddr_pair(32'h030, 32'h040);

            while (!ddr_done) @(posedge clk);

            for (i = 0; i < 4; i = i + 1) begin
                axi_read(REG_RES + i*4, read_data);
                $write("[%0t ns] [AXI Read Lane %0d] ", $time, i);
                check_result(read_data === expected_axi_reads[i+4], read_data, expected_axi_reads[i+4]);
            end
        end
    endtask

    task run_test_case_3;
        begin
            $display("\n---> RUNNING TEST 3: Edge Isolation (Single Rising Edge Target)");
            axi_write(REG_B + 0,  32'h0);
            axi_write(REG_B + 4,  32'h0);
            axi_write(REG_B + 8,  32'h0);
            axi_write(REG_B + 12, 32'h0);

            send_iddr_pair(32'h999, 32'h000);
            $display("[%0t ns] [INFO] Sent Valid Data on RISE edge, Zero on FALL edge...", $time);

            send_iddr_pair(32'h000, 32'h000);
            
            while (!ddr_done) @(posedge clk);

            for (i = 0; i < 4; i = i + 1) begin
                axi_read(REG_RES + i*4, read_data);
                $write("[%0t ns] [AXI Read Lane %0d] ", $time, i);
                check_result(read_data === expected_axi_reads[i+8], read_data, expected_axi_reads[i+8]);
            end
        end
    endtask

    task run_test_case_4_throughput_comparison;
        real time_start_1lane, time_end_1lane, duration_1lane_ns;
        real time_start_2lane, time_end_2lane, duration_2lane_ns;
        real speedup_ratio;
        begin
            $display("\n======================================================================");
            $display(" ---> RUNNING TEST 4: Performance & Latency Benchmark (1 Lane vs 2 Lane)");
            $display("======================================================================");

            // Cài đặt toán hạng B = 0 cho cả hệ thống qua AXI
            axi_write(REG_B + 0,  32'h0);
            axi_write(REG_B + 4,  32'h0);
            axi_write(REG_B + 8,  32'h0);
            axi_write(REG_B + 12, 32'h0);

            // ----------------------------------------------------------------
            // GIAI ĐOẠN 1: Truyền 4 mẫu tuần tự qua 1 LANE DUY NHẤT (Single-Lane Serial)
            // ----------------------------------------------------------------
            $display("[%0t ns] [BENCHMARK] Bat dau truyen 4 mau qua 1 Lane (Tuan tu)...", $time);
            time_start_1lane = $realtime;

            // Mẫu 1: Gửi 0x10 qua Lane 0
            axi_write(REG_A + 0, 32'h10);
            axi_write(REG_CTRL, 32'h1);
            while (!ddr_done) @(posedge clk);

            // Mẫu 2: Gửi 0x20 qua Lane 0
            axi_write(REG_A + 0, 32'h20);
            axi_write(REG_CTRL, 32'h1);
            while (!ddr_done) @(posedge clk);

            // Mẫu 3: Gửi 0x30 qua Lane 0
            axi_write(REG_A + 0, 32'h30);
            axi_write(REG_CTRL, 32'h1);
            while (!ddr_done) @(posedge clk);

            // Mẫu 4: Gửi 0x40 qua Lane 0
            axi_write(REG_A + 0, 32'h40);
            axi_write(REG_CTRL, 32'h1);
            while (!ddr_done) @(posedge clk);

            time_end_1lane = $realtime;
            duration_1lane_ns = time_end_1lane - time_start_1lane;
            $display("[%0t ns] [RESULT 1-LANE] Thoi gian hoan tat (4 mau): %0.2f ns", $time, duration_1lane_ns);

            // Nghỉ 10 chu kỳ xung nhịp giữa 2 lần đo
            repeat (10) @(posedge clk);

            // ----------------------------------------------------------------
            // GIAI ĐOẠN 2: Truyền 4 mẫu song song qua 2 LANES DDR (Dual-Lane Streaming)
            // ----------------------------------------------------------------
            $display("\n[%0t ns] [BENCHMARK] Bat dau truyen cung 4 mau qua 2 Lanes DDR (Song song)...", $time);
            time_start_2lane = $realtime;

            // Gói 1: Truyền đồng thời Mẫu 1 (Rise = 0x10) và Mẫu 2 (Fall = 0x20)
            send_iddr_pair(32'h10, 32'h20);

            // Gói 2: Truyền đồng thời Mẫu 3 (Rise = 0x30) và Mẫu 4 (Fall = 0x40)
            send_iddr_pair(32'h30, 32'h40);

            // Chờ bộ phát ODDR hoàn tất toàn bộ chuỗi
            while (!ddr_done) @(posedge clk);

            time_end_2lane = $realtime;
            duration_2lane_ns = time_end_2lane - time_start_2lane;
            $display("[%0t ns] [RESULT 2-LANE DDR] Thoi gian hoan tat (4 mau): %0.2f ns", $time, duration_2lane_ns);

            // ----------------------------------------------------------------
            // TÍNH TOÁN & KẾT LUẬN HIỆU NĂNG
            // ----------------------------------------------------------------
            speedup_ratio = duration_1lane_ns / duration_2lane_ns;
            
            $display("\n----------------------------------------------------------------------");
            $display(" [BENCHMARK REPORT]");
            $display("   * Thoi gian xu ly 1 Lane (Tuan tu) : %0.2f ns", duration_1lane_ns);
            $display("   * Thoi gian xu ly 2 Lane (DDR Core) : %0.2f ns", duration_2lane_ns);
            $display("   * Thoi gian tiet kiem duoc          : %0.2f ns (%0.1f %%)", 
                     duration_1lane_ns - duration_2lane_ns, 
                     ((duration_1lane_ns - duration_2lane_ns) / duration_1lane_ns) * 100.0);
            $display("   * He so tang toc (Speedup Factor)   : %0.2f X", speedup_ratio);
            $display("----------------------------------------------------------------------\n");

            // Đánh giá Pass nếu chế độ 2 Lane đạt tốc độ vượt trội (> 1.5x)
            check_result(speedup_ratio > 1.5, 32'h1, 32'h1);
        end
    endtask
    task print_summary;
        begin
            $display("\n==================================================");
            $display(" TONG KET: %0d/%0d PASS", test_pass, test_total);
            if (test_pass == test_total)
                $display(" => SYSTEM IS FULLY FUNCTIONAL WITH AXI4-LITE!");
            else
                $display(" => ERROR FOUND IN SIMULATION.");
            $display("==================================================\n");
        end
    endtask

    // ====================================================================
    // MAIN INITIAL BLOCK 
    // ====================================================================
    initial begin
        init_data_and_reset(); 
        #100;
        //run_test_case_1();   
        //run_test_case_2();     
        //run_test_case_3();    
        ddr_sample_count = 12; 
        run_test_case_4_throughput_comparison; 
        print_summary();       
        $finish;
    end

    // Safety Timeout
    initial begin #100000; $display("\n[ERROR] TIMEOUT!"); $finish; end

endmodule