`timescale 1ns/1ps

module axi_uart_slave #(
    parameter CLK_FREQ  = 50000000, 
    parameter BAUD_RATE = 115200
)(
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

    // --- UART Physical Pins ---
    output wire        uart_tx,
    input  wire        uart_rx
);

    // --- AXI Registers & Handshake ---
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

    // --- UART Internal Signals ---
    reg [7:0] tx_data;
    reg       tx_start;
    wire      tx_busy;
    wire [7:0] rx_data;
    wire       rx_ready;
    reg       rx_clear;

    // --- AXI Write FSM & Logic ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 0; axi_wready <= 0; axi_bvalid <= 0;
            tx_data <= 0; tx_start <= 0;
        end else begin
            tx_start <= 0;
            // Write handshake
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && ~axi_bvalid) begin
                axi_awready <= 1; axi_wready <= 1;
            end else begin
                axi_awready <= 0; axi_wready <= 0;
            end
            if (axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID) axi_bvalid <= 1;
            else if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 0;

            // Write Address Decoding
            if (slv_reg_wren) begin
                if (S_AXI_AWADDR[7:0] == 8'h00) begin
                    tx_data  <= S_AXI_WDATA[7:0];
                    tx_start <= 1'b1;
                end
            end
        end
    end

    // --- AXI Read FSM & Logic ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_arready <= 0; axi_rvalid <= 0; axi_rdata <= 0; rx_clear <= 0;
        end else begin
            rx_clear <= 0;
            if (~axi_arready && S_AXI_ARVALID && ~axi_rvalid) axi_arready <= 1;
            else axi_arready <= 0;

            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1;
                case (S_AXI_ARADDR[7:0])
                    8'h04: begin 
                        axi_rdata <= {24'b0, rx_data}; 
                        rx_clear <= 1'b1; // Tự động xóa cờ khi CPU đọc
                    end
                    8'h08: axi_rdata <= {30'b0, rx_ready, !tx_busy};
                    default: axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && S_AXI_RREADY) axi_rvalid <= 0;
        end
    end

    // =================================================================
    // LÕI UART TX & RX (Giữ nguyên cấu trúc cũ)
    // =================================================================
    localparam BIT_PERIOD = CLK_FREQ / BAUD_RATE;
    reg [15:0] clk_cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  tx_shift_reg;
    reg        tx_active;

    assign uart_tx = tx_active ? tx_shift_reg[0] : 1'b1;
    assign tx_busy = tx_active || tx_start;

    // TX Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 0; bit_idx <= 0; tx_active <= 0; tx_shift_reg <= 10'b1;
        end else if (tx_start && !tx_active) begin
            tx_active    <= 1'b1;
            tx_shift_reg <= {1'b1, tx_data, 1'b0}; 
            clk_cnt      <= 0; bit_idx <= 0;
        end else if (tx_active) begin
            if (clk_cnt < BIT_PERIOD - 1) clk_cnt <= clk_cnt + 1;
            else begin
                clk_cnt <= 0;
                if (bit_idx < 9) begin bit_idx <= bit_idx + 1; tx_shift_reg <= tx_shift_reg >> 1; end 
                else tx_active <= 1'b0;
            end
        end
    end

    // RX Logic
    reg [1:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], uart_rx};

    reg        rx_active;
    reg [15:0] rx_clk_cnt;
    reg [3:0]  rx_bit_idx;
    reg [7:0]  rx_shift_data;
    reg        rx_done;

    assign rx_data  = rx_shift_data;
    assign rx_ready = rx_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_active <= 0; rx_clk_cnt <= 0; rx_bit_idx <= 0; rx_done <= 0;
        end else begin
            if (rx_clear) rx_done <= 1'b0;
            
            if (!rx_active && (rx_sync[1] == 1'b0)) begin 
                rx_active  <= 1'b1; rx_clk_cnt <= BIT_PERIOD / 2; rx_bit_idx <= 0;
            end else if (rx_active) begin
                if (rx_clk_cnt < BIT_PERIOD - 1) rx_clk_cnt <= rx_clk_cnt + 1;
                else begin
                    rx_clk_cnt <= 0;
                    if (rx_bit_idx == 0) rx_bit_idx <= rx_bit_idx + 1;
                    else if (rx_bit_idx <= 8) begin
                        rx_shift_data <= {rx_sync[1], rx_shift_data[7:1]};
                        rx_bit_idx    <= rx_bit_idx + 1;
                    end else begin 
                        rx_active <= 1'b0; rx_done <= 1'b1; 
                    end
                end
            end
        end
    end
endmodule