`timescale 1ns / 1ps

// ------------------------------------------------------------
// 1. IDDR Deserializer
// ------------------------------------------------------------
module iddr_result_deserializer #(
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [DATA_WIDTH-1:0] ddr_data_in,
    output wire [DATA_WIDTH-1:0] data_rise,
    output wire [DATA_WIDTH-1:0] data_fall,
    output reg                   rx_valid
);
    genvar i;
    generate
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin : gen_iddr
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0),
                .INIT_Q2(1'b0),
                .SRTYPE("SYNC")
            ) u_iddr (
                .Q1(data_rise[i]), 
                .Q2(data_fall[i]), 
                .C(clk),
                .CE(1'b1),
                .D(ddr_data_in[i]),
                .R(~rst_n),
                .S(1'b0)
            );
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_valid <= 1'b0;
        else rx_valid <= 1'b1; 
    end
endmodule

// ------------------------------------------------------------
// 2. Independent Lane Distributor
// ------------------------------------------------------------
module independent_lane_distributor #(
    parameter NUM_LANES = 4,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  rx_valid,
    input  wire [DATA_WIDTH-1:0] data_rise,
    input  wire [DATA_WIDTH-1:0] data_fall,
    input  wire [NUM_LANES-1:0]  lane_ready,
    output reg  [NUM_LANES-1:0]  lane_valid,
    output reg  [DATA_WIDTH-1:0] lane_data_0,
    output reg  [DATA_WIDTH-1:0] lane_data_1,
    output reg  [DATA_WIDTH-1:0] lane_data_2,
    output reg  [DATA_WIDTH-1:0] lane_data_3
);
    reg [1:0] rr_ptr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr <= 2'b00;
            lane_valid <= 4'b0000;
            lane_data_0 <= 32'h0; lane_data_1 <= 32'h0;
            lane_data_2 <= 32'h0; lane_data_3 <= 32'h0;
        end else begin
            lane_valid <= 4'b0000; 
            if (rx_valid) begin
                case (rr_ptr)
                    2'b00: begin
                        if (lane_ready[0] && lane_ready[1]) begin
                            lane_data_0 <= data_rise; lane_valid[0] <= 1'b1;
                            lane_data_1 <= data_fall; lane_valid[1] <= 1'b1;
                            rr_ptr <= 2'b10; 
                        end
                    end
                    2'b10: begin
                        if (lane_ready[2] && lane_ready[3]) begin
                            lane_data_2 <= data_rise; lane_valid[2] <= 1'b1;
                            lane_data_3 <= data_fall; lane_valid[3] <= 1'b1;
                            rr_ptr <= 2'b00;
                        end
                    end
                    default: rr_ptr <= 2'b00;
                endcase
            end
        end
    end
endmodule

// ------------------------------------------------------------
// 3. ODDR Serializer
// ------------------------------------------------------------
module ddr_result_serializer #(
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load,
    input  wire [DATA_WIDTH-1:0] data_rise_0,
    input  wire [DATA_WIDTH-1:0] data_fall_0,
    input  wire [DATA_WIDTH-1:0] data_rise_1,
    input  wire [DATA_WIDTH-1:0] data_fall_1,
    output wire [DATA_WIDTH-1:0] ddr_data,
    output wire                  ddr_clk_out,
    output reg                   ddr_valid,
    output reg                   ddr_done,
    output wire                  ddr_ready
);
    localparam PHASE_IDLE   = 2'd0;
    localparam PHASE_SEND_0 = 2'd1;
    localparam PHASE_SEND_1 = 2'd2;
    localparam PHASE_DONE   = 2'd3;

    reg [1:0] phase;
    reg [DATA_WIDTH-1:0] rise_word;
    reg [DATA_WIDTH-1:0] fall_word;

    assign ddr_ready = (phase == PHASE_IDLE);

    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < DATA_WIDTH; bit_index = bit_index + 1) begin : gen_oddr
            ODDR #(
                .DDR_CLK_EDGE ("SAME_EDGE"),
                .INIT         (1'b0),
                .SRTYPE       ("SYNC")
            ) u_oddr (
                .Q  (ddr_data[bit_index]), .C  (clk), .CE (1'b1),
                .D1 (rise_word[bit_index]), .D2 (fall_word[bit_index]),
                .R  (~rst_n), .S  (1'b0)
            );
        end
    endgenerate

    ODDR #(.DDR_CLK_EDGE ("SAME_EDGE"), .INIT (1'b0), .SRTYPE ("SYNC")) 
    u_oddr_clk (
        .Q(ddr_clk_out), .C(clk), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(~rst_n), .S(1'b0)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PHASE_IDLE; rise_word <= 0; fall_word <= 0; ddr_valid <= 0; ddr_done <= 0;
        end else begin
            ddr_done <= 1'b0;
            case (phase)
                PHASE_IDLE: begin
                    if (load) begin
                        rise_word <= data_rise_0; fall_word <= data_fall_0; phase <= PHASE_SEND_0;
                    end
                end
                PHASE_SEND_0: begin
                    rise_word <= data_rise_1; fall_word <= data_fall_1; ddr_valid <= 1'b1; phase <= PHASE_SEND_1;
                end
                PHASE_SEND_1: phase <= PHASE_DONE;
                default: begin ddr_valid <= 1'b0; ddr_done <= 1'b1; phase <= PHASE_IDLE; end
            endcase
        end
    end
endmodule

// ------------------------------------------------------------
// 4. Parallel Core & Lanes
// ------------------------------------------------------------
module parallel_lane (
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [31:0] result_out
);
    assign in_ready   = out_ready;
    assign out_valid  = in_valid;
    assign result_out = a + b;
endmodule

module parallel_core #(
    parameter NUM_LANES = 4
)(
    input  wire [NUM_LANES-1:0]         in_valid,
    output wire [NUM_LANES-1:0]         in_ready,
    input  wire [(NUM_LANES*32)-1:0]    a_flat,
    input  wire [(NUM_LANES*32)-1:0]    b_flat,
    output wire [NUM_LANES-1:0]         out_valid,
    input  wire [NUM_LANES-1:0]         out_ready,
    output wire [(NUM_LANES*32)-1:0]    result_flat
);
    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i = i + 1) begin : gen_lanes
            parallel_lane u_lane (
                .in_valid   (in_valid[i]),
                .in_ready   (in_ready[i]),
                .a          (a_flat[(i*32) +: 32]),
                .b          (b_flat[(i*32) +: 32]),
                .out_valid  (out_valid[i]),
                .out_ready  (out_ready[i]),
                .result_out (result_flat[(i*32) +: 32])
            );
        end
    endgenerate
endmodule

// ------------------------------------------------------------
// 5. Module TOP (AXI4-Lite Wrapper)
// ------------------------------------------------------------
    module parallel_axi #(
    parameter NUM_LANES = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // --- AXI4-Lite Slave Interface ---
    input  wire [31:0] S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [ 3:0] S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [ 1:0] S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [31:0] S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [ 1:0] S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,

    // --- IDDR / ODDR Interface ---
    input  wire [31:0] ddr_data_in,
    input  wire        ddr_rx_valid,
    output wire [31:0] result_out,
    output wire        result_valid,
    output wire [31:0] ddr_data,
    output wire        ddr_clk_out,
    output wire        ddr_valid,
    output wire        ddr_done
);

    localparam [7:0] REG_CTRL_STATUS = 8'h00;
    localparam [7:0] REG_A_BASE      = 8'h10;
    localparam [7:0] REG_B_BASE      = 8'h20;
    localparam [7:0] REG_RESULT_BASE = 8'h30;

    reg  [31:0] reg_a      [0:NUM_LANES-1];
    reg  [31:0] reg_b      [0:NUM_LANES-1];
    reg  [31:0] reg_result [0:NUM_LANES-1];
    reg  [NUM_LANES-1:0] start_pending;
    reg  [NUM_LANES-1:0] result_valid_reg;

    reg axi_awready, axi_wready, axi_bvalid;
    reg axi_arready, axi_rvalid;
    reg [31:0] axi_rdata;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = axi_rvalid;

    wire slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    wire slv_reg_rden = axi_arready && S_AXI_ARVALID && ~axi_rvalid;
    
    wire [7:0] write_offset = S_AXI_AWADDR[7:0];
    wire [1:0] write_lane   = S_AXI_AWADDR[3:2];
    wire [7:0] read_offset  = S_AXI_ARADDR[7:0];
    wire [1:0] read_lane    = S_AXI_ARADDR[3:2];

    wire [NUM_LANES-1:0] core_in_ready, core_out_valid, fire_start;
    wire [(NUM_LANES*32)-1:0] a_flat, b_flat, result_flat;
    wire ddr_ready;

    assign fire_start   = start_pending & core_in_ready;
    assign result_out   = reg_result[0];
    assign result_valid = |result_valid_reg;

    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i = i + 1) begin : gen_pack
            assign a_flat[(i*32) +: 32] = reg_a[i];
            assign b_flat[(i*32) +: 32] = reg_b[i];
        end
    endgenerate

    parallel_core #(.NUM_LANES(NUM_LANES)) u_core (
        .in_valid    (fire_start),
        .in_ready    (core_in_ready),
        .a_flat      (a_flat),
        .b_flat      (b_flat),
        .out_valid   (core_out_valid),
        .out_ready   ({NUM_LANES{1'b1}}),
        .result_flat (result_flat)
    );

    // ==========================================
    // TẠO TRỄ ĐỒNG BỘ 1 CHU KỲ (PIPELINE MATCHING)
    // ==========================================
    wire [31:0] iddr_data_rise, iddr_data_fall;
    
    // Sử dụng thanh ghi dịch 2-bit để tạo trễ chính xác 2 clock
    reg [1:0] ddr_rx_valid_shift; 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ddr_rx_valid_shift <= 2'b00;
        else        ddr_rx_valid_shift <= {ddr_rx_valid_shift[0], ddr_rx_valid};
    end

    iddr_result_deserializer #(.DATA_WIDTH(32)) u_iddr_rx (
        .clk(clk), .rst_n(rst_n), .ddr_data_in(ddr_data_in),
        .data_rise(iddr_data_rise), .data_fall(iddr_data_fall), .rx_valid() 
    );

    wire [NUM_LANES-1:0] dist_lane_valid;
    wire [31:0] dist_lane_data_0, dist_lane_data_1, dist_lane_data_2, dist_lane_data_3;

    independent_lane_distributor #(.NUM_LANES(NUM_LANES), .DATA_WIDTH(32)) u_distributor (
        .clk(clk), .rst_n(rst_n), 
        .rx_valid(ddr_rx_valid_shift[1]), // <--- LẤY TÍN HIỆU BIT [1] (ĐÃ TRỄ ĐÚNG 2 CHU KỲ)
        .data_rise(iddr_data_rise), .data_fall(iddr_data_fall),
        .lane_ready(~start_pending), 
        .lane_valid(dist_lane_valid),
        .lane_data_0(dist_lane_data_0), .lane_data_1(dist_lane_data_1),
        .lane_data_2(dist_lane_data_2), .lane_data_3(dist_lane_data_3)
    );

    wire all_results_valid = &result_valid_reg;
    wire load_serializer = all_results_valid & ddr_ready;

    ddr_result_serializer #(.DATA_WIDTH (32)) u_ddr_result_serializer (
        .clk(clk), .rst_n(rst_n), .load(load_serializer),
        .data_rise_0(result_flat[31:0]), .data_fall_0(result_flat[63:32]),
        .data_rise_1(result_flat[95:64]), .data_fall_1(result_flat[127:96]),
        .ddr_data(ddr_data), .ddr_clk_out(ddr_clk_out),
        .ddr_valid(ddr_valid), .ddr_done(ddr_done), .ddr_ready(ddr_ready)
    );

    // --- AXI FSM ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b0; axi_wready  <= 1'b0; axi_bvalid <= 1'b0;
            axi_arready <= 1'b0; axi_rvalid  <= 1'b0; axi_rdata  <= 32'h0;
        end else begin
            // Write
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && ~axi_bvalid) begin
                axi_awready <= 1'b1; axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0; axi_wready  <= 1'b0;
            end
            if (axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID) axi_bvalid <= 1'b1;
            else if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;

            // Read
            if (~axi_arready && S_AXI_ARVALID && ~axi_rvalid) axi_arready <= 1'b1;
            else axi_arready <= 1'b0;

            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                case (read_offset)
                    REG_CTRL_STATUS: axi_rdata <= {24'h0, result_valid_reg, start_pending};
                    REG_A_BASE + 8'h00, REG_A_BASE + 8'h04, REG_A_BASE + 8'h08, REG_A_BASE + 8'h0c: 
                        axi_rdata <= reg_a[read_lane];
                    REG_B_BASE + 8'h00, REG_B_BASE + 8'h04, REG_B_BASE + 8'h08, REG_B_BASE + 8'h0c: 
                        axi_rdata <= reg_b[read_lane];
                    REG_RESULT_BASE + 8'h00, REG_RESULT_BASE + 8'h04, REG_RESULT_BASE + 8'h08, REG_RESULT_BASE + 8'h0c: 
                        axi_rdata <= reg_result[read_lane];
                    default: axi_rdata <= 32'hDEADBEEF;
                endcase
            end else if (axi_rvalid && S_AXI_RREADY) axi_rvalid <= 1'b0;
        end
    end

    // --- Control Registers ---
    integer lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            start_pending <= {NUM_LANES{1'b0}}; result_valid_reg <= {NUM_LANES{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                reg_a[lane] <= 32'h0; reg_b[lane] <= 32'h0; reg_result[lane] <= 32'h0;
            end
        end else begin
            start_pending <= start_pending & ~fire_start;
            if (load_serializer) result_valid_reg <= {NUM_LANES{1'b0}};

            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                if (core_out_valid[lane]) begin
                    reg_result[lane] <= result_flat[(lane*32) +: 32];
                    result_valid_reg[lane] <= 1'b1;
                end
            end

            if (dist_lane_valid[0]) begin reg_a[0] <= dist_lane_data_0; start_pending[0] <= 1'b1; end
            if (dist_lane_valid[1]) begin reg_a[1] <= dist_lane_data_1; start_pending[1] <= 1'b1; end
            if (dist_lane_valid[2]) begin reg_a[2] <= dist_lane_data_2; start_pending[2] <= 1'b1; end
            if (dist_lane_valid[3]) begin reg_a[3] <= dist_lane_data_3; start_pending[3] <= 1'b1; end

            if (slv_reg_wren) begin
                case (write_offset)
                    REG_CTRL_STATUS: begin
                        if (S_AXI_WDATA[0]) start_pending <= start_pending | ((|S_AXI_WDATA[NUM_LANES+7:8]) ? S_AXI_WDATA[NUM_LANES+7:8] : {NUM_LANES{1'b1}});
                        if (S_AXI_WDATA[1]) result_valid_reg <= result_valid_reg & ~((|S_AXI_WDATA[NUM_LANES+15:16]) ? S_AXI_WDATA[NUM_LANES+15:16] : {NUM_LANES{1'b1}});
                    end
                    REG_A_BASE + 8'h00, REG_A_BASE + 8'h04, REG_A_BASE + 8'h08, REG_A_BASE + 8'h0c: reg_a[write_lane] <= S_AXI_WDATA;
                    REG_B_BASE + 8'h00, REG_B_BASE + 8'h04, REG_B_BASE + 8'h08, REG_B_BASE + 8'h0c: reg_b[write_lane] <= S_AXI_WDATA;
                endcase
            end
        end
    end
endmodule