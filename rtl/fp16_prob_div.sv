`timescale 1ns/1ps
// Direct binary16 division for Softmax: |a| in [0,1] and |b| in [1,16].
// Eleven restoring steps produce an exact quotient and remainder at the
// required output ULP. Two register stages accept independent operands every
// clock. The caller controls their valid bits and flushes them on frame reset.
module fp16_prob_div (
    input  wire clk, stage1_enable, stage2_enable,
    input  wire [15:0] a, b,
    output reg  [15:0] y
);
    wire [10:0] a_sig = {a[14:10] != 0, a[9:0]};
    wire [10:0] b_sig = {1'b1, b[9:0]};  // every legal divisor is normal
    wire [4:0] a_exp = a[14:10] == 0 ? 5'd1 : a[14:10];
    wire signed [6:0] exp_diff =
        $signed({2'b00,a_exp}) - $signed({2'b00,b[14:10]});
    wire less_sig = a_sig < b_sig;
    wire signed [6:0] biased_exp = exp_diff + 7'sd15 - $signed({6'b0,less_sig});
    wire normal = biased_exp > 0;
    // For a normal result, the significand is measured in 2^-10 units
    // relative to its leading 1. For subnormals, one ULP is always 2^-24.
    wire [3:0] shift_amount = normal ? (less_sig ? 4'd11 : 4'd10)
                                     : 4'(exp_diff + 7'sd24);
    wire [21:0] dividend = {11'b0,a_sig} << shift_amount;

    // State layout after all 11 steps: {remainder[10:0], quotient[10:0]}.
    // Before the first step, the high 11 bits are already below the divisor.
    function automatic [21:0] divide_bit(input [21:0] state, input [10:0] divisor);
        reg [11:0] trial;
        begin
            trial = state[21:10];
            if (trial >= {1'b0,divisor})
                divide_bit = {11'(trial - {1'b0,divisor}), state[9:0], 1'b1};
            else
                divide_bit = {trial[10:0], state[9:0], 1'b0};
        end
    endfunction

    function automatic [21:0] divide_five(input [21:0] state, input [10:0] divisor);
        reg [21:0] work;
        integer i;
        begin
            work = state;
            for (i=0; i<5; i=i+1)
                work = divide_bit(work, divisor);
            divide_five = work;
        end
    endfunction

    reg [21:0] partial;
    reg [10:0] divisor_reg;
    reg [4:0] exponent_base;
    reg sign_reg;
    always @(posedge clk) begin
        if (stage1_enable) begin
            partial <= divide_bit(divide_five(dividend,b_sig),b_sig);
            divisor_reg <= b_sig;
            // Adding the full rounded significand to this base also handles
            // a carry into the next binade or the smallest normal number.
            exponent_base <= normal ? 5'(biased_exp - 7'sd1) : 5'd0;
            sign_reg <= a[15] ^ b[15];
        end
    end

    wire [21:0] result = divide_five(partial,divisor_reg);
    wire [10:0] quotient = result[10:0];
    wire [11:0] twice_remainder = {result[21:11],1'b0};
    wire round_up = twice_remainder > {1'b0,divisor_reg} ||
                    (twice_remainder == {1'b0,divisor_reg} && quotient[0]);
    wire [14:0] magnitude = {exponent_base,10'b0} + {4'b0,quotient} + {14'b0,round_up};
    always @(posedge clk)
        if (stage2_enable) y <= {sign_reg,magnitude};
endmodule
