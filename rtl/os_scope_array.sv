`timescale 1ns/1ps
// A single 16x16 OS mesh with two eight-row SCNA strips. The scheduler
// provides enables for the physical diagonal d=r+c on the current edge.
// A non-advancing edge holds every link, accumulator and nonlinear register.
module os_scope_array (
    input wire clk, rst_n, step,
    input wire [255:0] west, north, x_in,
    input wire [30:0] gemm_diag_valid, gemm_diag_first, exp_diag_valid,
    output wire [4095:0] accum,
    output wire [255:0] exp_out
);
    `include "scope_exp_coeffs.svh"

    wire [15:0] a_link [0:15][0:16];
    wire [15:0] b_link [0:16][0:15];

    for (genvar lane=0; lane<16; lane=lane+1) begin : boundary
        assign a_link[lane][0] = west[16*lane +: 16];
        assign b_link[0][lane] = north[16*lane +: 16];
    end

    for (genvar strip=0; strip<2; strip=strip+1) begin : strips
        for (genvar pair=0; pair<8; pair=pair+1) begin : pairs
            localparam integer L = 2*pair, R = L+1;
            localparam integer LANE = 8*strip + pair;
            wire [15:0] x [0:8], sum [0:8];
            assign x[0] = x_in[16*LANE +: 16];
            assign sum[0] = 16'h0000;
            assign exp_out[16*LANE +: 16] = sum[8];

            for (genvar h=0; h<8; h=h+1) begin : neurons
                localparam integer ROW = 8*strip + h;
                wire [15:0] affine, bias;
                os_scope_left_pe #(.WEIGHT(scope_exp_weight(3'(h)))) left_pe (
                    .clk, .rst_n, .step,
                    .gemm(gemm_diag_valid[ROW+L]), .first_term(gemm_diag_first[ROW+L]),
                    .scna(exp_diag_valid[ROW+L]),
                    .west(a_link[ROW][L]), .north(b_link[ROW][L]),
                    .east(a_link[ROW][L+1]), .south(b_link[ROW+1][L]),
                    .acc(accum[16*(16*ROW+L) +: 16]),
                    .x_in(x[h]), .right_bias(bias), .x_out(x[h+1]), .affine
                );
                os_scope_right_pe #(.BIAS(scope_exp_bias(3'(h)))) right_pe (
                    .clk, .rst_n, .step,
                    .gemm(gemm_diag_valid[ROW+R]), .first_term(gemm_diag_first[ROW+R]),
                    .scna(exp_diag_valid[ROW+R]),
                    .west(a_link[ROW][R]), .north(b_link[ROW][R]),
                    .east(a_link[ROW][R+1]), .south(b_link[ROW+1][R]),
                    .acc(accum[16*(16*ROW+R) +: 16]),
                    .left_affine(affine), .sum_in(sum[h]), .sum_out(sum[h+1]), .left_bias(bias)
                );
            end
        end
    end
endmodule
