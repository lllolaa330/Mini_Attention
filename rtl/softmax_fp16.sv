`timescale 1ns/1ps
// One row at a time. Every stored arithmetic result is IEEE binary16.
module softmax_fp16 #(
    parameter EXP_FILE = "rtl/exp_fp16.hex"
) (
    input wire clk, rst_n, start,
    input wire [15:0] raw_scores [0:15],
    output reg [15:0] probabilities [0:15],
    output wire done
);
    localparam IDLE=0, SCALE=1, EXP=2, DIV_START=3, DIV_WAIT=4, FINISH=5;
    reg [2:0] state;
    reg [3:0] index;
    reg [15:0] scores [0:15];
    reg [15:0] weights [0:15];
    reg [15:0] row_max, denominator;
    wire [15:0] scaled, delta, exp_value, sum_next, quotient;
    wire div_ready, div_done;

    // Negative arguments with magnitude >= 0x4c56 round exp to +0.
    // The table covers magnitude 0..0x4c55, including both signed zeros.
    reg [15:0] exp_rom [0:19541];
    initial $readmemh(EXP_FILE, exp_rom);
    assign exp_value = (delta[14:0] <= 15'h4c55) ? exp_rom[delta[14:0]] : 16'h0000;

    fp16_mul scale_op(.a(raw_scores[index]), .b(16'h3400), .y(scaled));
    fp16_addsub subtract_op(.sub(1'b1), .a(scores[index]), .b(row_max), .y(delta));
    fp16_addsub sum_op(.sub(1'b0), .a(denominator), .b(exp_value), .y(sum_next));
    fp16_div divide_op(.clk(clk), .rst_n(rst_n), .start(state == DIV_START),
        .a(weights[index]), .b(denominator), .ready(div_ready), .done(div_done), .y(quotient));

    // Finite values, plus the initial -infinity sentinel. Signed zeros compare equal.
    function automatic less_than(input [15:0] a, input [15:0] b);
        begin
            if ((a[14:0] == 0) && (b[14:0] == 0)) less_than = 1'b0;
            else if (a[15] != b[15]) less_than = a[15];
            else if (a[15]) less_than = a[14:0] > b[14:0];
            else less_than = a[14:0] < b[14:0];
        end
    endfunction

    assign done = (state == FINISH);
    // Row arrays are written fully before their first read; reset clears control.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            row_max <= 16'hfc00;
            denominator <= 0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    state <= SCALE;
                    index <= 0;
                    row_max <= 16'hfc00;
                    denominator <= 0;
                end
                SCALE: begin
                    scores[index] <= scaled;
                    if (less_than(row_max, scaled)) row_max <= scaled;
                    if (index == 15) begin index <= 0; state <= EXP; end
                    else index <= index + 1'b1;
                end
                EXP: begin
                    weights[index] <= exp_value;
                    denominator <= sum_next;
                    if (index == 15) begin index <= 0; state <= DIV_START; end
                    else index <= index + 1'b1;
                end
                DIV_START: if (div_ready) state <= DIV_WAIT;
                DIV_WAIT: if (div_done) begin
                    probabilities[index] <= quotient;
                    if (index == 15) begin index <= 0; state <= FINISH; end
                    else begin index <= index + 1'b1; state <= DIV_START; end
                end
                FINISH: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
