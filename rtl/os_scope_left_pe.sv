`timescale 1ns/1ps
// Left PE of a dual-strip output-stationary array. The local FMA alternates
// between a GEMM dot product and one neuron's affine term. GEMM operands
// still pass through the cell on any advancing edge, including an Exp edge.
module os_scope_left_pe #(
    parameter [15:0] WEIGHT = 16'h0000
) (
    input wire clk, rst_n, step, gemm, first_term, scna,
    input wire [15:0] west, north, x_in, right_bias,
    output reg [15:0] east, south, acc, x_out, affine
);
    wire [15:0] gemm_addend = first_term ? 16'h0000 : acc;
    wire [15:0] result;
    fp16_fma mac (
        .a(scna ? x_in : west),
        .b(scna ? WEIGHT : north),
        .c(scna ? right_bias : gemm_addend),
        .y(result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            east <= 0;
            south <= 0;
            acc <= 0;
            x_out <= 0;
            affine <= 0;
        end else if (step) begin
            east <= west;
            south <= north;
            if (scna) begin
                x_out <= x_in;
                affine <= result;
            end else if (gemm) begin
                acc <= result;
            end
        end
    end
endmodule
