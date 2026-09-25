// Convert a stream of 32-bit DMA words into a stream of 24-bit RGB pixels.
//
// Assumption used by this design:
//   dma_data[31:24], [23:16], [15:8], [7:0] are four consecutive bytes
//   in the RGB byte stream.  Therefore 32'h01_02_03_04 produces bytes
//   01,02,03,04 and the next DMA word continues the same byte stream.
//
// The fourth byte of one DMA word may belong to the next RGB pixel.  The
// three-byte packer below deliberately retains that byte across words.
// All transfers use ready/valid semantics; data is held while rgb_ready=0.

module dma32_to_rgb24 #(
    parameter MSB_FIRST = 1'b1
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] dma_data,
    input  wire        dma_valid,
    output wire        dma_ready,

    output wire [23:0] rgb_data,
    output wire        rgb_valid,
    input  wire        rgb_ready
);

    reg [31:0] dma_word_reg;
    reg        dma_word_valid;
    reg [1:0]  dma_byte_index;

    reg [23:0] pack_reg;
    reg [1:0]  pack_count;

    reg [23:0] rgb_data_reg;
    reg        rgb_valid_reg;

    wire rgb_output_slot_available;
    wire consume_byte;

    assign dma_ready = !dma_word_valid;
    assign rgb_data  = rgb_data_reg;
    assign rgb_valid = rgb_valid_reg;

    // A byte can be consumed unless the third byte of a pixel would overwrite
    // an output pixel that is currently stalled.
    assign rgb_output_slot_available = !rgb_valid_reg || rgb_ready;
    assign consume_byte = dma_word_valid &&
                          ((pack_count != 2'd2) || rgb_output_slot_available);

    function [7:0] select_dma_byte;
        input [31:0] word_value;
        input [1:0]  byte_index;
        begin
            if (MSB_FIRST) begin
                case (byte_index)
                    2'd0: select_dma_byte = word_value[31:24];
                    2'd1: select_dma_byte = word_value[23:16];
                    2'd2: select_dma_byte = word_value[15:8];
                    default: select_dma_byte = word_value[7:0];
                endcase
            end else begin
                case (byte_index)
                    2'd0: select_dma_byte = word_value[7:0];
                    2'd1: select_dma_byte = word_value[15:8];
                    2'd2: select_dma_byte = word_value[23:16];
                    default: select_dma_byte = word_value[31:24];
                endcase
            end
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            dma_word_reg   <= 32'd0;
            dma_word_valid <= 1'b0;
            dma_byte_index <= 2'd0;
            pack_reg       <= 24'd0;
            pack_count     <= 2'd0;
            rgb_data_reg   <= 24'd0;
            rgb_valid_reg  <= 1'b0;
        end else begin
            // Remove a pixel after the downstream accepts it.  If a new
            // pixel is completed in this same clock, the later assignment
            // in the consume_byte block replaces this clear with valid=1.
            if (rgb_valid_reg && rgb_ready)
                rgb_valid_reg <= 1'b0;

            // A DMA word is buffered before its bytes are unpacked.  This
            // makes dma_ready independent of the byte-level processing.
            if (dma_valid && dma_ready) begin
                dma_word_reg   <= dma_data;
                dma_word_valid <= 1'b1;
                dma_byte_index <= 2'd0;
            end

            if (consume_byte) begin
                case (pack_count)
                    2'd0: begin
                        pack_reg[23:16] <= select_dma_byte(dma_word_reg,
                                                            dma_byte_index);
                        pack_count <= 2'd1;
                    end

                    2'd1: begin
                        pack_reg[15:8] <= select_dma_byte(dma_word_reg,
                                                           dma_byte_index);
                        pack_count <= 2'd2;
                    end

                    default: begin
                        pack_reg[7:0] <= select_dma_byte(dma_word_reg,
                                                          dma_byte_index);
                        rgb_data_reg <= {pack_reg[23:16],
                                         pack_reg[15:8],
                                         select_dma_byte(dma_word_reg,
                                                         dma_byte_index)};
                        rgb_valid_reg <= 1'b1;
                        pack_count <= 2'd0;
                    end
                endcase

                if (dma_byte_index == 2'd3) begin
                    dma_word_valid <= 1'b0;
                    dma_byte_index <= 2'd0;
                end else begin
                    dma_byte_index <= dma_byte_index + 2'd1;
                end
            end
        end
    end

endmodule
