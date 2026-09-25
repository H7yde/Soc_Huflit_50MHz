`timescale 1ns / 1ps

module soc_top #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115200,
    parameter ENABLE_MUL = 0,
    parameter ENABLE_DIV = 0,
    parameter ENABLE_IRQ = 1
)(
    input  wire        clk,
    input  wire        resetn,

    // --- Physical Pins ---
    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs,

    output wire        scl_out,
    output wire        sda_out,
    output wire        sda_oe,
    input  wire        sda_in,

    // --- IDDR / ODDR Stream Pins ---
    input  wire [31:0] ddr_data_in,
    input  wire        ddr_rx_valid,
    output wire [31:0] ddr_data,
    output wire        ddr_clk_out,
    output wire        ddr_valid,
    output wire        ddr_done,

    output wire        cpu_trap
);

    wire        mem_valid, mem_instr;
    wire [31:0] mem_addr, mem_wdata;
    wire [ 3:0] mem_wstrb;

    // --------------------------------------------------------
    // PicoRV32 CPU (Sử dụng Native Memory Interface để nạp lệnh siêu tốc)
    // --------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS  (1),
        .ENABLE_REGS_16_31(1),
        .ENABLE_MUL       (ENABLE_MUL),
        .ENABLE_DIV       (ENABLE_DIV),
        .ENABLE_IRQ       (ENABLE_IRQ),
        .ENABLE_IRQ_TIMER (1),
        .PROGADDR_RESET   (32'h0000_0000),
        .STACKADDR        (32'h0000_0FF0)
    ) u_cpu (
        .clk      (clk),
        .resetn   (resetn),
        .trap     (cpu_trap),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr (mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read (), .mem_la_write(), .mem_la_addr(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
        .pcpi_wr(1'b0), .pcpi_rd(32'h0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(32'h0), .eoi(),
        .trace_valid(), .trace_data()
    );

    // --------------------------------------------------------
    // Rẽ nhánh Bộ nhớ: BRAM (Native) vs MMIO Ngoại vi (AXI)
    // --------------------------------------------------------
    wire is_bram = (mem_addr[31:28] == 4'h0); // 0x0000_0000 -> BRAM
    wire is_mmio = (mem_addr[31:28] == 4'h4); // 0x4000_0000 -> Ngoại vi

    wire        bram_ready;
    wire [31:0] bram_rdata;
    wire        mmio_ready;
    wire [31:0] mmio_rdata;

    // CPU nhận kết quả từ BRAM hoặc từ khối AXI MMIO
    assign mem_ready = is_bram ? bram_ready : (is_mmio ? mmio_ready : 1'b0);
    wire [31:0] mem_rdata_wire = is_bram ? bram_rdata : (is_mmio ? mmio_rdata : 32'h0);
    assign mem_rdata = mem_rdata_wire;

    // ========================================================
    // BRAM 4KB (Giao tiếp Native 1-cycle latency)
    // ========================================================
    reg [31:0] bram [0:1023];
    initial $readmemh("firmware.hex", bram);

    reg [31:0] bram_rdata_reg;
    reg        bram_ready_reg;
    always @(posedge clk) begin
        bram_ready_reg <= 1'b0;
        if (mem_valid && is_bram) begin
            bram_rdata_reg <= bram[mem_addr[11:2]];
            bram_ready_reg <= 1'b1; // Phản hồi ngay lập tức
            
            if (!mem_instr && |mem_wstrb) begin
                if (mem_wstrb[0]) bram[mem_addr[11:2]][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) bram[mem_addr[11:2]][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) bram[mem_addr[11:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) bram[mem_addr[11:2]][31:24] <= mem_wdata[31:24];
            end
        end
    end
    assign bram_rdata = bram_rdata_reg;
    assign bram_ready = bram_ready_reg;

    // ========================================================
    // BỘ CHUYỂN ĐỔI (NATIVE to AXI4-LITE MASTER)
    // ========================================================
    wire        axi_m_awvalid, axi_m_awready;
    wire [31:0] axi_m_awaddr;
    wire [ 2:0] axi_m_awprot;
    wire        axi_m_wvalid, axi_m_wready;
    wire [31:0] axi_m_wdata;
    wire [ 3:0] axi_m_wstrb;
    wire        axi_m_bvalid, axi_m_bready;
    wire        axi_m_arvalid, axi_m_arready;
    wire [31:0] axi_m_araddr;
    wire [ 2:0] axi_m_arprot;
    wire        axi_m_rvalid, axi_m_rready;
    wire [31:0] axi_m_rdata;

    picorv32_axi_adapter u_axi_adapter (
        .clk            (clk),
        .resetn         (resetn),
        // AXI4-Lite Master Output
        .mem_axi_awvalid(axi_m_awvalid), .mem_axi_awready(axi_m_awready), .mem_axi_awaddr (axi_m_awaddr), .mem_axi_awprot(axi_m_awprot),
        .mem_axi_wvalid (axi_m_wvalid),  .mem_axi_wready (axi_m_wready),  .mem_axi_wdata  (axi_m_wdata),  .mem_axi_wstrb (axi_m_wstrb),
        .mem_axi_bvalid (axi_m_bvalid),  .mem_axi_bready (axi_m_bready),
        .mem_axi_arvalid(axi_m_arvalid), .mem_axi_arready(axi_m_arready), .mem_axi_araddr (axi_m_araddr), .mem_axi_arprot(axi_m_arprot),
        .mem_axi_rvalid (axi_m_rvalid),  .mem_axi_rready (axi_m_rready),  .mem_axi_rdata  (axi_m_rdata),
        // Native Input (Chỉ kích hoạt khi là MMIO)
        .mem_valid      (mem_valid && is_mmio),
        .mem_instr      (mem_instr),
        .mem_ready      (mmio_ready),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_wstrb      (mem_wstrb),
        .mem_rdata      (mmio_rdata)
    );

    // ========================================================
    // 1-to-2 AXI CROSSBAR (Bộ định tuyến AXI)
    // ========================================================
    wire aw_sel_parallel = (axi_m_awaddr[31:12] == 20'h40003);
    wire aw_sel_cnn      = (axi_m_awaddr[31:12] == 20'h40004);
    wire aw_sel_periph   = (axi_m_awaddr[31:12] >= 20'h40000 && axi_m_awaddr[31:12] <= 20'h40002);
    wire ar_sel_parallel = (axi_m_araddr[31:12] == 20'h40003);
    wire ar_sel_cnn      = (axi_m_araddr[31:12] == 20'h40004);
    wire ar_sel_periph   = (axi_m_araddr[31:12] >= 20'h40000 && axi_m_araddr[31:12] <= 20'h40002);

    // Chốt mục tiêu Ghi (Write Latch) - Sửa điều kiện bẻ khóa Deadlock
    reg [2:0] w_target; // [2]: CNN, [1]: parallel, [0]: periph
    always @(posedge clk) begin
        if (!resetn) w_target <= 3'b000;
        else if (axi_m_awvalid && !axi_m_bvalid)
            w_target <= {aw_sel_cnn, aw_sel_parallel, aw_sel_periph};
        else if (axi_m_bvalid && axi_m_bready) w_target <= 3'b000;
    end
    wire [2:0] act_w_target = (w_target != 3'b000) ? w_target :
                              (axi_m_awvalid ? {aw_sel_cnn, aw_sel_parallel, aw_sel_periph} : 3'b000);

    // Chốt mục tiêu Đọc (Read Latch) - Sửa điều kiện bẻ khóa Deadlock
    reg [2:0] r_target;
    always @(posedge clk) begin
        if (!resetn) r_target <= 3'b000;
        else if (axi_m_arvalid && !axi_m_rvalid)
            r_target <= {ar_sel_cnn, ar_sel_parallel, ar_sel_periph};
        else if (axi_m_rvalid && axi_m_rready) r_target <= 3'b000;
    end
    wire [2:0] act_r_target = (r_target != 3'b000) ? r_target :
                              (axi_m_arvalid ? {ar_sel_cnn, ar_sel_parallel, ar_sel_periph} : 3'b000);

    // Tín hiệu AXI cho Nhóm Periph (UART, SPI, I2C)
    wire axi_periph_awready, axi_periph_wready, axi_periph_bvalid, axi_periph_arready, axi_periph_rvalid;
    wire [1:0] axi_periph_bresp, axi_periph_rresp;
    wire [31:0] axi_periph_rdata;

    // Tín hiệu AXI cho Khối Parallel DDR
    wire axi_parallel_awready, axi_parallel_wready, axi_parallel_bvalid, axi_parallel_arready, axi_parallel_rvalid;
    wire [1:0] axi_parallel_bresp, axi_parallel_rresp;
    wire [31:0] axi_parallel_rdata;

    wire axi_cnn_awready, axi_cnn_wready, axi_cnn_bvalid, axi_cnn_arready, axi_cnn_rvalid;
    wire [1:0] axi_cnn_bresp, axi_cnn_rresp;
    wire [31:0] axi_cnn_rdata;

    // --- Ghép kênh trả về CPU (Mux) ---
    assign axi_m_awready = (act_w_target[2] & axi_cnn_awready) |
                           (act_w_target[1] & axi_parallel_awready) |
                           (act_w_target[0] & axi_periph_awready);
    assign axi_m_wready  = (act_w_target[2] & axi_cnn_wready) |
                           (act_w_target[1] & axi_parallel_wready) |
                           (act_w_target[0] & axi_periph_wready);
    assign axi_m_bvalid  = (act_w_target[2] & axi_cnn_bvalid) |
                           (act_w_target[1] & axi_parallel_bvalid) |
                           (act_w_target[0] & axi_periph_bvalid);
    assign axi_m_bresp   = act_w_target[2] ? axi_cnn_bresp :
                           (act_w_target[1] ? axi_parallel_bresp : axi_periph_bresp);

    assign axi_m_arready = (act_r_target[2] & axi_cnn_arready) |
                           (act_r_target[1] & axi_parallel_arready) |
                           (act_r_target[0] & axi_periph_arready);
    assign axi_m_rvalid  = (act_r_target[2] & axi_cnn_rvalid) |
                           (act_r_target[1] & axi_parallel_rvalid) |
                           (act_r_target[0] & axi_periph_rvalid);
    assign axi_m_rdata   = act_r_target[2] ? axi_cnn_rdata :
                           (act_r_target[1] ? axi_parallel_rdata : axi_periph_rdata);
    assign axi_m_rresp   = act_r_target[2] ? axi_cnn_rresp :
                           (act_r_target[1] ? axi_parallel_rresp : axi_periph_rresp);

    // ========================================================
    // TÍCH HỢP NGOẠI VI (AXI SLAVES)
    // ========================================================
    
    // 1. Cụm thiết bị ngoại vi chuẩn (UART, SPI, I2C)
    soc_axi_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_axi_periph (
        .clk             (clk),
        .rst_n           (resetn),
        
        .S_AXI_AWADDR    (axi_m_awaddr),
        .S_AXI_AWVALID   (axi_m_awvalid & act_w_target[0]),
        .S_AXI_AWREADY   (axi_periph_awready),
        .S_AXI_WDATA     (axi_m_wdata),
        .S_AXI_WSTRB     (axi_m_wstrb),
        .S_AXI_WVALID    (axi_m_wvalid & act_w_target[0]),
        .S_AXI_WREADY    (axi_periph_wready),
        .S_AXI_BRESP     (axi_periph_bresp),
        .S_AXI_BVALID    (axi_periph_bvalid),
        .S_AXI_BREADY    (axi_m_bready & act_w_target[0]),
        
        .S_AXI_ARADDR    (axi_m_araddr),
        .S_AXI_ARVALID   (axi_m_arvalid & act_r_target[0]),
        .S_AXI_ARREADY   (axi_periph_arready),
        .S_AXI_RDATA     (axi_periph_rdata),
        .S_AXI_RRESP     (axi_periph_rresp),
        .S_AXI_RVALID    (axi_periph_rvalid),
        .S_AXI_RREADY    (axi_m_rready & act_r_target[0]),
        
        .uart_tx         (uart_tx),
        .uart_rx         (uart_rx),
        .spi_sclk        (spi_sclk),
        .spi_mosi        (spi_mosi),
        .spi_miso        (spi_miso),
        .spi_cs          (spi_cs),
        .scl_out         (scl_out),
        .sda_out         (sda_out),
        .sda_oe          (sda_oe),
        .sda_in          (sda_in)
    );

    // 2. Bộ Tăng tốc Song song DDR (IDDR & ODDR)
    parallel_axi u_parallel_axi (
        .clk             (clk),
        .rst_n           (resetn),
        
        .S_AXI_AWADDR    (axi_m_awaddr),
        .S_AXI_AWVALID   (axi_m_awvalid & act_w_target[1]),
        .S_AXI_AWREADY   (axi_parallel_awready),
        .S_AXI_WDATA     (axi_m_wdata),
        .S_AXI_WSTRB     (axi_m_wstrb),
        .S_AXI_WVALID    (axi_m_wvalid & act_w_target[1]),
        .S_AXI_WREADY    (axi_parallel_wready),
        .S_AXI_BRESP     (axi_parallel_bresp),
        .S_AXI_BVALID    (axi_parallel_bvalid),
        .S_AXI_BREADY    (axi_m_bready & act_w_target[1]),
        
        .S_AXI_ARADDR    (axi_m_araddr),
        .S_AXI_ARVALID   (axi_m_arvalid & act_r_target[1]),
        .S_AXI_ARREADY   (axi_parallel_arready),
        .S_AXI_RDATA     (axi_parallel_rdata),
        .S_AXI_RRESP     (axi_parallel_rresp),
        .S_AXI_RVALID    (axi_parallel_rvalid),
        .S_AXI_RREADY    (axi_m_rready & act_r_target[1]),
        
        .ddr_data_in     (ddr_data_in),
        .ddr_rx_valid    (ddr_rx_valid),
        .result_out      (),
        .result_valid    (),
        .ddr_data        (ddr_data),
        .ddr_clk_out     (ddr_clk_out),
        .ddr_valid       (ddr_valid),
        .ddr_done        (ddr_done)
    );

    // 3. CNN AXI peripheral at base address 0x40004000.
    CNN u_cnn (
        .clk             (clk),
        .rst_n           (resetn),

        .S_AXI_AWADDR    (axi_m_awaddr),
        .S_AXI_AWVALID   (axi_m_awvalid & act_w_target[2]),
        .S_AXI_AWREADY   (axi_cnn_awready),
        .S_AXI_WDATA     (axi_m_wdata),
        .S_AXI_WSTRB     (axi_m_wstrb),
        .S_AXI_WVALID    (axi_m_wvalid & act_w_target[2]),
        .S_AXI_WREADY    (axi_cnn_wready),
        .S_AXI_BRESP     (axi_cnn_bresp),
        .S_AXI_BVALID    (axi_cnn_bvalid),
        .S_AXI_BREADY    (axi_m_bready & act_w_target[2]),

        .S_AXI_ARADDR    (axi_m_araddr),
        .S_AXI_ARVALID   (axi_m_arvalid & act_r_target[2]),
        .S_AXI_ARREADY   (axi_cnn_arready),
        .S_AXI_RDATA     (axi_cnn_rdata),
        .S_AXI_RRESP     (axi_cnn_rresp),
        .S_AXI_RVALID    (axi_cnn_rvalid),
        .S_AXI_RREADY    (axi_m_rready & act_r_target[2])
    );

endmodule
