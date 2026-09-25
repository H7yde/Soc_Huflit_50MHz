`timescale 1ns/1ps

module axi_i2c_slave (
    input wire clk,
    input wire rst_n,

    // --- AXI4-Lite Interface ---
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

    // --- I2C Physical Pins ---
    output reg         scl_out,
    output reg         sda_out,
    output reg         sda_oe, 
    input  wire        sda_in
);

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

    reg [7:0] i2c_data;
    reg [3:0] i2c_cmd;
    reg       cmd_trigger;
    wire      i2c_busy;
    wire      rx_ack;

    // --- AXI Write FSM & Logic ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 0; axi_wready <= 0; axi_bvalid <= 0;
            i2c_data <= 8'h0; i2c_cmd <= 4'h0; cmd_trigger <= 1'b0;
        end else begin
            cmd_trigger <= 0;
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && ~axi_bvalid) begin
                axi_awready <= 1; axi_wready <= 1;
            end else begin
                axi_awready <= 0; axi_wready <= 0;
            end
            if (axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID) axi_bvalid <= 1;
            else if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 0;

            if (slv_reg_wren) begin
                if (S_AXI_AWADDR[7:0] == 8'h00) i2c_data <= S_AXI_WDATA[7:0];
                if (S_AXI_AWADDR[7:0] == 8'h04) begin 
                    i2c_cmd <= S_AXI_WDATA[3:0]; cmd_trigger <= 1'b1; 
                end
            end
        end
    end

    // --- AXI Read FSM & Logic ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_arready <= 0; axi_rvalid <= 0; axi_rdata <= 0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID && ~axi_rvalid) axi_arready <= 1;
            else axi_arready <= 0;

            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1;
                case (S_AXI_ARADDR[7:0])
                    8'h00: axi_rdata <= {24'b0, i2c_data};
                    8'h08: axi_rdata <= {30'b0, rx_ack, i2c_busy};
                    default: axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && S_AXI_RREADY) axi_rvalid <= 0;
        end
    end

    // =================================================================
    // LÕI I2C MASTER FSM (Giữ nguyên cấu trúc cũ)
    // =================================================================
    reg [3:0] state;
    reg [7:0] clk_cnt;
    reg [2:0] bit_idx;
    reg       busy_reg;
    reg       ack_reg;

    assign i2c_busy = busy_reg;
    assign rx_ack   = ack_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 0; scl_out <= 1; sda_out <= 1; sda_oe <= 1; 
            busy_reg <= 0; ack_reg <= 0; clk_cnt <= 0; bit_idx <= 0;
        end else begin
            case (state)
                0: begin
                    scl_out <= 1'b1; sda_out <= 1'b1; sda_oe <= 1'b1;
                    if (cmd_trigger) begin
                        busy_reg <= 1'b1; clk_cnt <= 0;
                        if (i2c_cmd[0])      state <= 1; 
                        else if (i2c_cmd[1]) state <= 3; 
                        else if (i2c_cmd[2]) begin bit_idx <= 7; state <= 5; end 
                    end else busy_reg <= 1'b0;
                end
                1: begin sda_out <= 1'b0; clk_cnt <= clk_cnt + 1; if(clk_cnt == 50) begin clk_cnt <= 0; state <= 2; end end
                2: begin scl_out <= 1'b0; clk_cnt <= clk_cnt + 1; if(clk_cnt == 50) begin clk_cnt <= 0; state <= 0; end end
                3: begin sda_out <= 1'b0; scl_out <= 1'b1; clk_cnt <= clk_cnt + 1; if(clk_cnt == 50) begin clk_cnt <= 0; state <= 4; end end
                4: begin sda_out <= 1'b1; clk_cnt <= clk_cnt + 1; if(clk_cnt == 50) begin clk_cnt <= 0; state <= 0; end end
                5: begin
                    sda_out <= i2c_data[bit_idx];
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == 25) scl_out <= 1'b1;
                    if (clk_cnt == 50) begin
                        scl_out <= 1'b0; clk_cnt <= 0;
                        if (bit_idx > 0) bit_idx <= bit_idx - 1;
                        else state <= 6; 
                    end
                end
                6: begin
                    sda_oe  <= 1'b0;
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == 25) begin scl_out <= 1'b1; ack_reg <= sda_in; end 
                    if (clk_cnt == 50) begin
                        scl_out <= 1'b0; clk_cnt <= 0; state <= 0;
                    end
                end
                default: state <= 0;
            endcase
        end
    end
endmodule