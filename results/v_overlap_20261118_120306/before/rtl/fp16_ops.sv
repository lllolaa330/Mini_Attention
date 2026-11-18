// 4 个 FP16（半精度浮点数）运算模块, 调用了 Berkeley HardFloat 库中的运算单元
// IEEE binary16 arithmetic. HardFloat Release 1, expWidth=5, sigWidth=11.
// All operations use round-to-nearest, ties-to-even and tininess after rounding.
// 外部使用标准 IEEE FP16，内部使用 HardFloat 特有的 recFN 格式。
// recFN 仅用于组合运算器内部，不用于阵列中的状态存储。
// y = a * b + c
module fp16_fma (
    input wire [15:0] a, b, c,
    output wire [15:0] y
);
    wire [16:0] ar, br, cr, yr;
    wire [4:0] unused_flags;
    fNToRecFN #(5,11) ca (.in(a), .out(ar));
    fNToRecFN #(5,11) cb (.in(b), .out(br));
    fNToRecFN #(5,11) cc (.in(c), .out(cr));
    mulAddRecFN #(5,11) core (.control(1'b1), .op(2'b00),
        .a(ar), .b(br), .c(cr), .roundingMode(3'b000),
        .out(yr), .exceptionFlags(unused_flags));
    recFNToFN #(5,11) cy (.in(yr), .out(y));
endmodule

// y = a +/- b
module fp16_addsub (
    input wire sub,
    input wire [15:0] a, b,
    output wire [15:0] y
);
    wire [16:0] ar, br, yr;
    wire [4:0] unused_flags;
    fNToRecFN #(5,11) ca (.in(a), .out(ar));
    fNToRecFN #(5,11) cb (.in(b), .out(br));
    addRecFN #(5,11) core (.control(1'b1), .subOp(sub),
        .a(ar), .b(br), .roundingMode(3'b000),
        .out(yr), .exceptionFlags(unused_flags));
    recFNToFN #(5,11) cy (.in(yr), .out(y));
endmodule

// y = a * b
module fp16_mul (
    input wire [15:0] a, b,
    output wire [15:0] y
);
    wire [16:0] ar, br, yr;
    wire [4:0] unused_flags;
    fNToRecFN #(5,11) ca (.in(a), .out(ar));
    fNToRecFN #(5,11) cb (.in(b), .out(br));
    mulRecFN #(5,11) core (.control(1'b1), .a(ar), .b(br),
        .roundingMode(3'b000), .out(yr), .exceptionFlags(unused_flags));
    recFNToFN #(5,11) cy (.in(yr), .out(y));
endmodule

// y = a / b 时序逻辑
// A request is accepted on start && ready. done and y identify the result;
// 只有在 done=1 时，才保证 y 有效。下游模块必须及时保存结果。
module fp16_div (
    input wire clk, rst_n, start,
    input wire [15:0] a, b,
    output wire ready, done,
    output wire [15:0] y
);
    wire [16:0] ar, br, yr;
    wire raw_ready, raw_done, unused_sqrt;
    wire [4:0] unused_flags;
    fNToRecFN #(5,11) ca (.in(a), .out(ar));
    fNToRecFN #(5,11) cb (.in(b), .out(br));
    divSqrtRecFN_small #(5,11,0) core (
        .nReset(rst_n), .clock(clk), .control(1'b1),
        .inReady(raw_ready), .inValid(start && rst_n), .sqrtOp(1'b0),
        .a(ar), .b(br), .roundingMode(3'b000),
        .outValid(raw_done), .sqrtOpOut(unused_sqrt),
        .out(yr), .exceptionFlags(unused_flags));
    recFNToFN #(5,11) cy (.in(yr), .out(y));
    assign ready = rst_n && raw_ready;
    assign done = rst_n && raw_done;
endmodule
