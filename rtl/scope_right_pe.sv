`timescale 1ns/1ps
// Fig. 9d / 10b. The adjacent left PE takes this cell's stationary bias.
// For SCNA the same GEMM MAC computes 1 * ReLU(affine) + the north sum.
module scope_right_pe (
    input  wire clk, rst_n, load, commit, gemm, scna,
    input  wire [15:0] west, north, left_affine,
    output reg  [15:0] east, south, resident
);
    wire [15:0] rectified = left_affine[15] ? 16'h0000 : left_affine;
    wire [15:0] product_sum;
    fp16_fma mac (.a(scna ? rectified : west),
                  .b(scna ? 16'h3c00 : resident), .c(north), .y(product_sum));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            east <= 0;
            resident <= 0;
            south <= 0;
        end else begin
            if (load || gemm) east <= west;
            if (commit) resident <= east;
            if (gemm || scna) south <= product_sum;
        end
    end
endmodule
