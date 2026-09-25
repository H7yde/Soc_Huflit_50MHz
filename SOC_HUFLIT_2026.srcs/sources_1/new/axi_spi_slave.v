`timescale 1ns/1ps

module axi_spi_slave (
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

    // --- SPI Physical Pins ---
    output reg         spi_sclk,
    output reg         spi_cs,
    output wire        spi_mosi,
    input  wire        spi_miso
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

    reg [7:0] tx_shifter;
    reg [7:0] tx_data_buf;
    reg [7:0] rx_data_buf;
    reg       spi_busy;
    reg       start_tx;
    
    assign spi_mosi = tx_shifter[7];

    // --- AXI Write FSM & Logic ---
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 0; axi_wready <= 0; axi_bvalid <= 0;
            spi_cs <= 1'b1; start_tx <= 1'b0; tx_data_buf <= 8'h0;
        end else begin
            start_tx <= 0;
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && ~axi_bvalid) begin
                axi_awready <= 1; axi_wready <= 1;
            end else begin
                axi_awready <= 0; axi_wready <= 0;
            end
            if (axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID) axi_bvalid <= 1;
            else if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 0;

            if (slv_reg_wren) begin
                case (S_AXI_AWADDR[7:0])
                    8'h00: begin tx_data_buf <= S_AXI_WDATA[7:0]; start_tx <= 1'b1; end
                    8'h04: spi_cs <= S_AXI_WDATA[0];
                endcase
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
                    8'h00: axi_rdata <= {24'b0, rx_data_buf};
                    8'h04: axi_rdata <= {31'b0, spi_cs};
                    8'h08: axi_rdata <= {31'b0, spi_busy};
                    default: axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && S_AXI_RREADY) axi_rvalid <= 0;
        end
    end

    // =================================================================
    // LÕI SPI MASTER FSM (Giữ nguyên cấu trúc cũ)
    // =================================================================
    reg [2:0] state;
    reg [3:0] bit_cnt;
    reg [7:0] clk_div;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 0; spi_sclk <= 0; bit_cnt <= 0; clk_div <= 0; spi_busy <= 0; rx_data_buf <= 0; tx_shifter <= 0;
        end else begin
            case (state)
                0: begin
                    spi_sclk <= 1'b0;
                    if (start_tx && !spi_cs) begin
                        spi_busy <= 1'b1; bit_cnt <= 0; clk_div <= 0; tx_shifter <= tx_data_buf; state <= 1;
                    end else spi_busy <= 1'b0;
                end
                1: begin
                    spi_sclk <= 1'b1;
                    if (clk_div == 8'd5) begin 
                        clk_div <= 0; rx_data_buf <= {rx_data_buf[6:0], spi_miso}; state <= 2;
                    end else clk_div <= clk_div + 1;
                end
                2: begin
                    spi_sclk <= 1'b0;
                    if (clk_div == 8'd5) begin
                        clk_div <= 0;
                        if (bit_cnt < 7) begin
                            bit_cnt <= bit_cnt + 1; tx_shifter <= tx_shifter << 1; state <= 1;
                        end else state <= 0; 
                    end else clk_div <= clk_div + 1;
                end
                default: state <= 0;
            endcase
        end
    end
endmodule