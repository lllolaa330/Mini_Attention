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
    reg [3:0] index;  // 用于遍历 16 个元素的索引
    reg [15:0] scores [0:15];  // 存储 raw_scores / 4
    reg [15:0] weights [0:15]; // 存储 exp(scores-max)
    reg [15:0] row_max, denominator; // 行最大值 & 分母 都是 FP16 （0S + 5E + 10F）
    wire [15:0] scaled, delta, exp_value, sum_next, quotient;
    wire div_ready, div_done;

    // Negative arguments with magnitude >= 0x4c56 round exp to +0.
    // 0x4c56 = 0100 1100 0101 0110 = 2^(19-15) * (1+86/2^10) = 17.24275
    // The table covers magnitude 0..0x4c55, including both signed zeros.
    reg [15:0] exp_rom [0:19541];
    initial $readmemh(EXP_FILE, exp_rom);
    // 绝对值 < 17.328 就直接近似为 0
    assign exp_value = (delta[14:0] <= 15'h4c55) ? exp_rom[delta[14:0]] : 16'h0000;

    fp16_mul scale_op(.a(raw_scores[index]), .b(16'h3400), .y(scaled)); //16'h3400 = 0011 0100 0000 0000 = (-1)^0*(1+0/2^10)*2^(13-15) = 0.25
    fp16_addsub subtract_op(.sub(1'b1), .a(scores[index]), .b(row_max), .y(delta));
    fp16_addsub sum_op(.sub(1'b0), .a(denominator), .b(exp_value), .y(sum_next));
    fp16_div divide_op(.clk(clk), .rst_n(rst_n), .start(state == DIV_START),
        .a(weights[index]), .b(denominator), .ready(div_ready), .done(div_done), .y(quotient));

    // Finite values, plus the initial -infinity sentinel. Signed zeros compare equal.
    function automatic less_than(input [15:0] a, input [15:0] b);
        begin
            // 比较符号位外的15位 发现都是0 返回0
            if ((a[14:0] == 0) && (b[14:0] == 0)) less_than = 1'b0;
            // 比较符号位 发现不一样 返回对应的值
            else if (a[15] != b[15]) less_than = a[15];
            // 如果都是负数 绝对值大的反而小
            else if (a[15]) less_than = a[14:0] > b[14:0];
            // 如果都是正数 正常比较
            else less_than = a[14:0] < b[14:0];
        end
    endfunction

    assign done = (state == FINISH);
    // Row arrays are written fully before their first read; reset clears control.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            row_max <= 16'hfc00; // 16'hfc00 = 1111 1100 0000 0000 指数位为全1 && 尾数=0，表示-inf
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
                    scores[index] <= scaled; // *0.25
                    if (less_than(row_max, scaled)) row_max <= scaled; // 更新 row_max
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
