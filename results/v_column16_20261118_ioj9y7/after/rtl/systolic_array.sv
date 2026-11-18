// N x N output-stationary array; default N=16 instantiates 256 FP16 FMA PEs.
// At logical step t, feed A[i][t-i] and B[t-j][j], valid iff index in range.
// For K inner terms, all outputs are complete after K+2*(N-1) enabled steps.
// During step=0 operands, validity, and accumulators all hold. clear overrides
// step. With diagonal control, a new dot product starts from +0 on first_term,
// so a completed QK cell can be reused for PV while other diagonals finish QK.
module systolic_array #(
    parameter integer N = 16,
    parameter bit DIAGONAL_CONTROL = 1'b0
) (
    input wire clk, rst_n, clear, step, // step=0 不进行脉动 step=1 进行脉动
    input wire [15:0] a_edge [0:N-1],
    input wire [15:0] b_edge [0:N-1],
    input wire [N-1:0] a_valid, b_valid,
    output wire [15:0] accum [0:N-1][0:N-1],
    input wire [2*N-2:0] diagonal_enable, diagonal_first
);
    wire [15:0] a_link [0:N-1][0:N];
    wire [15:0] b_link [0:N][0:N-1];
    wire av_link [0:N-1][0:N];
    wire bv_link [0:N][0:N-1];
    genvar i, j;
    generate
        for (i=0; i<N; i=i+1) begin : edges
            assign a_link[i][0] = a_edge[i];
            assign av_link[i][0] = a_valid[i];
            assign b_link[0][i] = b_edge[i];
            assign bv_link[0][i] = b_valid[i];
        end
        for (i=0; i<N; i=i+1) begin : rows
            for (j=0; j<N; j=j+1) begin : cols
                wire cell_step = step && (!DIAGONAL_CONTROL || diagonal_enable[i+j]);
                fp16_pe pe (
                    .clk(clk), .rst_n(rst_n), .clear(clear), .step(cell_step),
                    .first_term(DIAGONAL_CONTROL && diagonal_first[i+j]),
                    .a_in(a_link[i][j]), .b_in(b_link[i][j]),
                    .a_valid_in(av_link[i][j]), .b_valid_in(bv_link[i][j]),
                    .a_out(a_link[i][j+1]), .b_out(b_link[i+1][j]),
                    .a_valid_out(av_link[i][j+1]),
                    .b_valid_out(bv_link[i+1][j]), .acc(accum[i][j]));
            end
        end
    endgenerate
endmodule
