`timescale 1ns/1ps
// Fig. 9c / 10b. During SCNA the fourth register forwards x vertically,
// while the usual GEMM partial-sum register forwards the affine result east.
module scope_left_pe (
    input  wire clk, rst_n, load, commit, gemm, scna,
    input  wire [15:0] west, north, right_bias,
    output reg  [15:0] east, affine,
    output wire [15:0] south
);
    reg  [15:0] weight, x_delay;
    wire [15:0] product_sum;
    fp16_fma mac (.a(scna ? north : west), .b(weight),
                  .c(scna ? right_bias : north), .y(product_sum));
    assign south = scna ? x_delay : affine;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            east <= 0;
            weight <= 0;
            affine <= 0;
            x_delay <= 0;
        end else begin
            if (load || gemm) east <= west;
            if (commit) weight <= east;
            if (gemm || scna) affine <= product_sum;
            if (scna) x_delay <= north;
        end
    end
endmodule
