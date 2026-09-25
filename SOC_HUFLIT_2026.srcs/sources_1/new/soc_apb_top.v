`timescale 1ns/1ps

// ============================================================
// SOC APB top-level
//   0x4000_0000 - 0x4000_0FFF: UART
//   0x4000_1000 - 0x4000_1FFF: SPI
//   0x4000_2000 - 0x4000_2FFF: I2C
// The parallel accelerator at 0x4000_3000 is decoded in soc_top.
// ============================================================

module soc_apb_top #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERR,

    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs,

    output wire        scl_out,
    output wire        sda_out,
    output wire        sda_oe,
    input  wire        sda_in
);

    wire psel_uart = (PADDR[31:12] == 20'h40000);
    wire psel_spi  = (PADDR[31:12] == 20'h40001);
    wire psel_i2c  = (PADDR[31:12] == 20'h40002);

    wire [31:0] prdata_uart;
    wire [31:0] prdata_spi;
    wire [31:0] prdata_i2c;
    wire        pready_uart;
    wire        pready_spi;
    wire        pready_i2c;

    always @(*) begin
        case (1'b1)
            psel_uart: PRDATA = prdata_uart;
            psel_spi:  PRDATA = prdata_spi;
            psel_i2c:  PRDATA = prdata_i2c;
            default:   PRDATA = 32'h0;
        endcase
    end

    assign PREADY  = psel_uart ? pready_uart :
                     psel_spi  ? pready_spi  :
                     psel_i2c  ? pready_i2c  : 1'b1;
    assign PSLVERR = 1'b0;

    apb_uart_slave #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart (
        .PCLK         (clk),
        .PRESETn      (rst_n),
        .UART_PADDR   ({24'h0, PADDR[7:0]}),
        .UART_PSEL    (psel_uart),
        .UART_PENABLE (PENABLE),
        .UART_PWRITE  (PWRITE),
        .UART_PWDATA  (PWDATA),
        .UART_PRDATA  (prdata_uart),
        .UART_PREADY  (pready_uart),
        .uart_tx      (uart_tx),
        .uart_rx      (uart_rx)
    );

    apb_spi_slave u_spi (
        .PCLK        (clk),
        .PRESETn     (rst_n),
        .SPI_PADDR   ({24'h0, PADDR[7:0]}),
        .SPI_PSEL    (psel_spi),
        .SPI_PENABLE (PENABLE),
        .SPI_PWRITE  (PWRITE),
        .SPI_PWDATA  (PWDATA),
        .SPI_PRDATA  (prdata_spi),
        .PREADY      (pready_spi),
        .spi_sclk    (spi_sclk),
        .spi_cs      (spi_cs),
        .spi_mosi    (spi_mosi),
        .spi_miso    (spi_miso)
    );

    apb_i2c_slave u_i2c (
        .PCLK        (clk),
        .PRESETn     (rst_n),
        .I2C_PADDR   ({24'h0, PADDR[7:0]}),
        .I2C_PSEL    (psel_i2c),
        .I2C_PENABLE (PENABLE),
        .I2C_PWRITE  (PWRITE),
        .I2C_PWDATA  (PWDATA),
        .I2C_PRDATA  (prdata_i2c),
        .PREADY      (pready_i2c),
        .scl_out     (scl_out),
        .sda_out     (sda_out),
        .sda_oe      (sda_oe),
        .sda_in      (sda_in)
    );

endmodule
