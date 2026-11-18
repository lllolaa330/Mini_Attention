`timescale 1ns/1ps
// Weight-stationary FP16 PE. weight is installed vertically and then held;
// A propagates to the right, while registered partial sums propagate down.
// Each row implements the next FMA in k=0..N-1 order, with one FP16 rounding.
module fp16_ws_pe (
    input wire clk, rst_n, clear, load_weights, step,
    input wire direct_load,
    input wire [15:0] direct_weight,
    input wire [15:0] weight_in,
    input wire [15:0] a_in, psum_in,
    input wire a_valid_in, psum_valid_in,
    output reg [15:0] weight,
    output reg [15:0] a_out, psum_out,
    output reg a_valid_out, psum_valid_out
);
    wire [15:0] next_sum;
    fp16_fma fma (.a(a_in), .b(weight), .c(psum_in), .y(next_sum));

    // Reset clears all state. Direct writes are independent of the computation
    // pipeline, including clear and step. A same-edge FMA uses the old weight;
    // the newly written weight is available at the following clock edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight <= 16'h0000;
            a_out <= 16'h0000;
            psum_out <= 16'h0000;
            a_valid_out <= 1'b0;
            psum_valid_out <= 1'b0;
        end else begin
            // clear preserves the resident weight unless it is directly
            // replaced. Direct write wins if both loading modes are asserted.
            if (direct_load) weight <= direct_weight;
            else if (load_weights && !clear) weight <= weight_in;

            if (clear || load_weights) begin
                a_out <= 16'h0000;
                psum_out <= 16'h0000;
                a_valid_out <= 1'b0;
                psum_valid_out <= 1'b0;
            end else if (step) begin
                a_out <= a_in;
                a_valid_out <= a_valid_in;
                psum_valid_out <= a_valid_in && psum_valid_in;
                if (a_valid_in && psum_valid_in) psum_out <= next_sum;
            end
        end
    end
endmodule
