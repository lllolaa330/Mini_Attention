`timescale 1ns/1ps
// Scores arrive in column order within each row. A QK completion wave can
// supply distinct rows together, with at most one last-column score per edge.
module online_softmax16 #(
    parameter EXP_FILE = "rtl/exp_fp16.hex"
) (
    input wire clk, rst_n, clear,
    input wire [15:0] score_valid,
    input wire [3:0] score_col [0:15],
    input wire [15:0] raw_score [0:15],
    output reg norm_issue,
    output reg [3:0] norm_issue_row,
    output reg prob_valid,
    output reg [3:0] prob_row,
    output wire [15:0] probability [0:15]
);
    reg [15:0] exp_rom [0:19541];
    initial $readmemh(EXP_FILE, exp_rom);
    // Stable differences are nonpositive. +0 and -0 both give exactly one.
    function automatic [15:0] exp_nonpositive(input [15:0] delta);
        if (!delta[15]) exp_nonpositive = 16'h3c00;
        else if (delta[14:0] < 15'h4c56) exp_nonpositive = exp_rom[delta[14:0]];
        else exp_nonpositive = 16'h0000;
    endfunction

    function automatic numeric_less(input [15:0] a, input [15:0] b);
        if (a[14:0] == 0 && b[14:0] == 0) numeric_less = 1'b0;
        else if (a[15] != b[15]) numeric_less = a[15];
        else numeric_less = a[15] ? a[14:0] > b[14:0] : a[14:0] < b[14:0];
    endfunction

    reg [15:0] saved_score [0:15][0:15];
    reg [15:0] row_max [0:15], row_sum [0:15];
    wire [15:0] last_score;
    genvar row;
    generate
        for (row=0; row<16; row=row+1) begin : statistics
            wire [15:0] x, difference, rescaled_sum, next_sum;
            fp16_mul scale (.a(raw_score[row]), .b(16'h3400), .y(x));
            wire new_max = numeric_less(row_max[row],x);
            wire [15:0] larger = new_max ? x : row_max[row];
            wire [15:0] smaller = new_max ? row_max[row] : x;
            fp16_addsub delta (.sub(1'b1), .a(smaller), .b(larger), .y(difference));
            wire [15:0] factor = exp_nonpositive(difference);
            // In each branch, one of the two exponential factors is exactly 1.
            fp16_mul rescale (.a(row_sum[row]), .b(factor), .y(rescaled_sum));
            fp16_addsub accumulate (.sub(1'b0),
                .a(new_max ? rescaled_sum : row_sum[row]),
                .b(new_max ? 16'h3c00 : factor), .y(next_sum));

            always @(posedge clk) begin
                if (!clear && score_valid[row]) begin
                    saved_score[row][score_col[row]] <= x;
                    // First score starts a fresh row without evaluating -inf - -inf.
                    row_max[row] <= score_col[row] == 0 ? x : larger;
                    row_sum[row] <= score_col[row] == 0 ? 16'h3c00 : next_sum;
                end
            end
            assign last_score[row] = score_valid[row] && score_col[row] == 4'd15;
        end
    endgenerate

    reg exp_valid, divide_valid;
    reg [3:0] exp_row, divide_row;
    reg [15:0] denominator;
    integer r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            norm_issue <= 0; exp_valid <= 0; divide_valid <= 0; prob_valid <= 0;
            norm_issue_row <= 0; exp_row <= 0; divide_row <= 0; prob_row <= 0;
        end else begin
            norm_issue <= !clear && (|last_score);
            for (r=0; r<16; r=r+1)
                if (last_score[r]) norm_issue_row <= 4'(r);
            exp_valid <= !clear && norm_issue;
            exp_row <= norm_issue_row;
            divide_valid <= !clear && exp_valid;
            divide_row <= exp_row;
            prob_valid <= !clear && divide_valid;
            prob_row <= divide_row;
        end
    end

    always @(posedge clk)
        if (norm_issue) denominator <= row_sum[norm_issue_row];
    genvar column;
    generate
        for (column=0; column<16; column=column+1) begin : normalization
            wire [15:0] delta;
            reg [15:0] numerator;
            fp16_addsub subtract_max (.sub(1'b1),
                .a(saved_score[norm_issue_row][column]), .b(row_max[norm_issue_row]), .y(delta));
            always @(posedge clk)
                if (norm_issue) numerator <= exp_nonpositive(delta);
            fp16_prob_div divide (.clk(clk), .stage1_enable(exp_valid),
                .stage2_enable(divide_valid), .a(numerator), .b(denominator), .y(probability[column]));
        end
    endgenerate
endmodule
