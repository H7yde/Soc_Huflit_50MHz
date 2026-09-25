`timescale 1ns/1ps

// AXI4-Lite CNN peripheral.
//
// Address map relative to 0x40004000:
//   0x000..0xBFC : 768 x 32-bit RGB byte-stream words (3072 bytes)
//   0xFF8        : STATUS, bit 0 = busy, bit 1 = done
//   0xFFC        : CONTROL, write bit 0 = START
//   0xFF4        : RESULT, bit 0 = classification (1 human, 0 non-human)
//
// Required source modules from CNN_RTL:
//   dma32_to_rgb24.v
//   cnn_docx_reference.v
//
// The reference CNN is frame-level simulation code. This peripheral is useful
// for AXI functional integration and simulation; it is not the final
// cycle-accurate streaming CNN implementation for synthesis.
module CNN (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,

    input  wire [31:0] S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY
);
    reg [31:0] frame_mem [0:767];

    reg        aw_pending;
    reg        w_pending;
    reg [31:0] awaddr_reg;
    reg [31:0] wdata_reg;
    reg [3:0]  wstrb_reg;
    reg        bvalid_reg;
    reg        rvalid_reg;
    reg [31:0] rdata_reg;

    reg        start_pending;
    reg        busy_reg;
    reg        done_reg;
    reg        classification_reg;
    reg [9:0]  frame_word_index;
    reg        frame_send_valid;

    wire [11:0] write_offset = awaddr_reg[11:0];
    wire [11:0] read_offset  = S_AXI_ARADDR[11:0];
    wire        write_fire = aw_pending && w_pending && !bvalid_reg;

    wire [31:0] frame_send_data = frame_mem[frame_word_index];
    wire        dma_ready;
    wire [23:0] rgb_data;
    wire        rgb_valid;
    wire        rgb_ready;
    wire        cnn_result_valid;
    wire        cnn_classification;
    wire        rst = ~rst_n;

    assign S_AXI_AWREADY = !aw_pending && !bvalid_reg;
    assign S_AXI_WREADY  = !w_pending && !bvalid_reg;
    assign S_AXI_BVALID  = bvalid_reg;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_ARREADY = !rvalid_reg;
    assign S_AXI_RVALID  = rvalid_reg;
    assign S_AXI_RDATA   = rdata_reg;
    assign S_AXI_RRESP   = 2'b00;

    dma32_to_rgb24 #(
        .MSB_FIRST(1'b1)
    ) u_dma_to_rgb (
        .clk       (clk),
        .rst       (rst),
        .dma_data  (frame_send_data),
        .dma_valid (frame_send_valid),
        .dma_ready (dma_ready),
        .rgb_data  (rgb_data),
        .rgb_valid (rgb_valid),
        .rgb_ready (rgb_ready)
    );

    cnn_docx_reference u_cnn_reference (
        .clk           (clk),
        .rst           (rst),
        .pixel_data    (rgb_data),
        .pixel_valid   (rgb_valid),
        .pixel_ready   (rgb_ready),
        .result_valid  (cnn_result_valid),
        .classification(cnn_classification)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_pending          <= 1'b0;
            w_pending           <= 1'b0;
            awaddr_reg          <= 32'd0;
            wdata_reg           <= 32'd0;
            wstrb_reg           <= 4'd0;
            bvalid_reg          <= 1'b0;
            rvalid_reg          <= 1'b0;
            rdata_reg           <= 32'd0;
            start_pending       <= 1'b0;
            busy_reg            <= 1'b0;
            done_reg            <= 1'b0;
            classification_reg  <= 1'b0;
            frame_word_index    <= 10'd0;
            frame_send_valid    <= 1'b0;
        end else begin
            // Capture AXI write address and data independently.
            if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                awaddr_reg <= S_AXI_AWADDR;
                aw_pending <= 1'b1;
            end
            if (S_AXI_WVALID && S_AXI_WREADY) begin
                wdata_reg  <= S_AXI_WDATA;
                wstrb_reg  <= S_AXI_WSTRB;
                w_pending  <= 1'b1;
            end

            if (write_fire) begin
                aw_pending <= 1'b0;
                w_pending  <= 1'b0;
                bvalid_reg <= 1'b1;

                // Image buffer: 768 words x 4 bytes = 3072 RGB bytes.
                if (write_offset < 12'hC00) begin
                    if (write_offset[11:2] < 10'd768) begin
                        if (wstrb_reg[0]) frame_mem[write_offset[11:2]][7:0]   <= wdata_reg[7:0];
                        if (wstrb_reg[1]) frame_mem[write_offset[11:2]][15:8]  <= wdata_reg[15:8];
                        if (wstrb_reg[2]) frame_mem[write_offset[11:2]][23:16] <= wdata_reg[23:16];
                        if (wstrb_reg[3]) frame_mem[write_offset[11:2]][31:24] <= wdata_reg[31:24];
                    end
                end

                // CONTROL: write bit 0 to start one frame.
                if (write_offset == 12'hFFC && wdata_reg[0] && !busy_reg) begin
                    start_pending <= 1'b1;
                    done_reg <= 1'b0;
                end
            end

            if (bvalid_reg && S_AXI_BREADY)
                bvalid_reg <= 1'b0;

            // One-cycle AXI read response.
            if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                rvalid_reg <= 1'b1;
                case (read_offset)
                    12'hFF4: rdata_reg <= {31'd0, classification_reg};
                    12'hFF8: rdata_reg <= {30'd0, done_reg, busy_reg};
                    12'hFFC: rdata_reg <= 32'd0;
                    default: rdata_reg <= 32'd0;
                endcase
            end else if (rvalid_reg && S_AXI_RREADY) begin
                rvalid_reg <= 1'b0;
            end

            // Start sending the buffered frame as a 32-bit RGB byte stream.
            if (start_pending && !busy_reg) begin
                start_pending    <= 1'b0;
                busy_reg         <= 1'b1;
                done_reg         <= 1'b0;
                frame_word_index <= 10'd0;
                frame_send_valid <= 1'b1;
            end

            if (frame_send_valid && dma_ready) begin
                if (frame_word_index == 10'd767) begin
                    frame_send_valid <= 1'b0;
                end else begin
                    frame_word_index <= frame_word_index + 10'd1;
                end
            end

            if (cnn_result_valid) begin
                classification_reg <= cnn_classification;
                busy_reg <= 1'b0;
                done_reg <= 1'b1;
            end
        end
    end
endmodule
