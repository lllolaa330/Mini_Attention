// Output-stationary PE: two operands move, one FP16 partial sum stays local.
// The baseline FMA is combinational. step advances one complete MAC/forward operation;
// no pipelined feedback and no unverified frequency are assumed.
module fp16_pe (
    input wire clk, rst_n, clear, step,
    input wire [15:0] a_in, b_in,
    input wire a_valid_in, b_valid_in,
    output reg [15:0] a_out, b_out,
    output reg a_valid_out, b_valid_out,
    output reg [15:0] acc,
    input wire first_term
);
    wire [15:0] next_acc;
    fp16_fma fma (.a(a_in), .b(b_in), .c(first_term ? 16'h0000 : acc), .y(next_acc));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= 16'h0000; b_out <= 16'h0000;
            a_valid_out <= 1'b0; b_valid_out <= 1'b0;
            acc <= 16'h0000;
        end else if (clear) begin
            a_out <= 16'h0000; b_out <= 16'h0000;
            a_valid_out <= 1'b0; b_valid_out <= 1'b0;
            acc <= 16'h0000;
        end else if (step) begin
            a_out <= a_in; b_out <= b_in;
            a_valid_out <= a_valid_in; b_valid_out <= b_valid_in;
            if (a_valid_in && b_valid_in) acc <= next_acc;
        end
    end
endmodule
