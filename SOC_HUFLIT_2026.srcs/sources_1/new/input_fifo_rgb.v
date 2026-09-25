// Ready/valid FIFO for RGB pixels.
//
// When the CNN deasserts out_ready, pixels are retained until the FIFO is
// drained.  When full, in_ready is deasserted unless a pop happens in the
// same cycle; this permits lossless push/pop at full throughput.

module input_fifo_rgb #(
    parameter DATA_WIDTH = 24,
    parameter DEPTH      = 64
) (
    input  wire                  clk,
    input  wire                  rst,

    input  wire [DATA_WIDTH-1:0] in_data,
    input  wire                  in_valid,
    output wire                  in_ready,

    output wire [DATA_WIDTH-1:0] out_data,
    output wire                  out_valid,
    input  wire                  out_ready,

    output wire                  full,
    output wire                  empty
);

    localparam PTR_WIDTH   = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam COUNT_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [COUNT_WIDTH-1:0] count;

    wire push;
    wire pop;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    // If the FIFO is full but the current head will be popped, the incoming
    // pixel can occupy that slot on this same clock edge.
    assign in_ready = !full || out_ready;
    assign out_valid = !empty;
    assign out_data = mem[rd_ptr];

    assign push = in_valid && in_ready;
    assign pop  = out_valid && out_ready;

    function [PTR_WIDTH-1:0] next_ptr;
        input [PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == DEPTH-1)
                next_ptr = {PTR_WIDTH{1'b0}};
            else
                next_ptr = ptr + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            count  <= {COUNT_WIDTH{1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= in_data;
                wr_ptr <= next_ptr(wr_ptr);
            end

            if (pop)
                rd_ptr <= next_ptr(rd_ptr);

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
