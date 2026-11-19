`timescale 1ns/1ps
// SCOPE Fig. 9b. The horizontal register also serves as the shadow
// weight register during preload. Commit copies it to the stationary weight.
module scope_standard_pe (
    input  wire clk, rst_n, load, commit, gemm,
    input  wire [15:0] west, north,
    output reg  [15:0] east, south
);
    reg  [15:0] weight;
    wire [15:0] product_sum;
    fp16_fma mac (.a(west), .b(weight), .c(north), .y(product_sum));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            east <= 0;
            weight <= 0;
            south <= 0;
        end else begin
            if (load || gemm) east <= west;
            if (commit) weight <= east;
            if (gemm) south <= product_sum;
        end
    end
endmodule
