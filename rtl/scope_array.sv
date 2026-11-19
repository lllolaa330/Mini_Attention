`timescale 1ns/1ps
// SCOPE Fig. 9/10. Rows are GEMM terms k; columns are output features j.
// A 16x8 strip has eight vertical chains of eight adjacent left/right pairs.
// STRIPS=1 leaves the bottom eight rows standard. STRIPS=2 accepts 16 x/cycle.
module scope_array #(
    parameter integer STRIPS = 2
) (
    input  wire clk, rst_n, load, commit, gemm, scna,
    input  wire [255:0] west, x_in,
    output wire [255:0] gemm_out, exp_out
);
    wire [15:0] horizontal [0:15][0:16];
    wire [15:0] vertical [0:16][0:15];
    for (genvar lane=0; lane<16; lane=lane+1) begin : boundary
        assign horizontal[lane][0] = west[16*lane +: 16];
        assign vertical[0][lane] = 16'h0000;
        if (lane >= 8*STRIPS) begin : unused_stream
            wire [15:0] unused_x = x_in[16*lane +: 16];
            assign exp_out[16*lane +: 16] = 16'h0000;
        end
    end

    for (genvar r=0; r<16; r=r+1) begin : rows
        for (genvar pair=0; pair<8; pair=pair+1) begin : pairs
            localparam integer L = 2*pair, R = L+1;
            if (r < 8*STRIPS) begin : extended
                localparam integer STREAM = 8*(r/8)+pair;
                wire [15:0] affine, bias;
                wire [15:0] left_north, right_north;
                if (r%8 == 0) begin : strip_input
                    // Independent stream entry points for both strips; ordinary
                    // GEMM partial sums always traverse all sixteen rows.
                    assign left_north = scna ? x_in[16*STREAM +: 16] : vertical[r][L];
                    assign right_north = scna ? 16'h0000 : vertical[r][R];
                end else begin : strip_link
                    assign left_north = vertical[r][L];
                    assign right_north = vertical[r][R];
                end

                scope_left_pe left (
                    .clk(clk), .rst_n(rst_n), .load(load), .commit(commit), .gemm(gemm), .scna(scna),
                    .west(horizontal[r][L]), .north(left_north), .right_bias(bias),
                    .east(horizontal[r][R]), .south(vertical[r+1][L]), .affine(affine)
                );
                scope_right_pe right (
                    .clk(clk), .rst_n(rst_n), .load(load), .commit(commit), .gemm(gemm), .scna(scna),
                    .west(horizontal[r][R]), .north(right_north), .left_affine(affine),
                    .east(horizontal[r][R+1]), .south(vertical[r+1][R]), .resident(bias)
                );
                if (r%8 == 7) begin : strip_output
                    assign exp_out[16*STREAM +: 16] = vertical[r+1][R];
                end
                if (r == 15) begin : result
                    // Use the registered result even at a GEMM -> SCNA mode change.
                    assign gemm_out[16*L +: 16] = affine;
                    assign gemm_out[16*R +: 16] = vertical[r+1][R];
                end
            end else begin : standard
                for (genvar j=L; j<=R; j=j+1) begin : columns
                    scope_standard_pe cell_pe (
                        .clk(clk), .rst_n(rst_n), .load(load), .commit(commit), .gemm(gemm),
                        .west(horizontal[r][j]), .north(vertical[r][j]),
                        .east(horizontal[r][j+1]), .south(vertical[r+1][j])
                    );
                    if (r == 15) begin : result
                        assign gemm_out[16*j +: 16] = vertical[r+1][j];
                    end
                end
            end
        end
    end
endmodule
