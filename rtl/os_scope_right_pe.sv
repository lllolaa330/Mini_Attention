`timescale 1ns/1ps
// The paired Right PE adds the rectified affine term to the previous
// neuron's running sum. This is the same FMA used by the local OS accumulator.
module os_scope_right_pe #(
    parameter [15:0] BIAS = 16'h0000
) (
    input wire clk, rst_n, step, gemm, first_term, scna,
    input wire [15:0] west, north, left_affine, sum_in,
    output reg [15:0] east, south, acc, sum_out,
    output wire [15:0] left_bias
);
    assign left_bias = BIAS;
    wire [15:0] rectified = left_affine[15] ? 16'h0000 : left_affine;
    wire [15:0] gemm_addend = first_term ? 16'h0000 : acc;
    wire [15:0] result;
    fp16_fma mac (
        .a(scna ? 16'h3c00 : west),
        .b(scna ? rectified : north),
        .c(scna ? sum_in : gemm_addend),
        .y(result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            east <= 0;
            south <= 0;
            acc <= 0;
            sum_out <= 0;
        end else if (step) begin
            east <= west;
            south <= north;
            if (scna) sum_out <= result;
            else if (gemm) acc <= result;
        end
    end
endmodule
