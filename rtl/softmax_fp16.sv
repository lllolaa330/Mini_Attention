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
    localparam IDLE=0, SCALE=1, EXP=2, SUM=3, DIV_START=4, DIV_WAIT=5, FINISH=6;
    reg [2:0] state;
    reg [15:0] scores [0:15];  // 存储 raw_scores / 4
    reg [15:0] weights [0:15]; // 存储 exp(scores-max)
    reg [15:0] row_max, denominator; // 行最大值 & 分母 都是 FP16 （0S + 5E + 10F）

    wire [15:0] scaled_all [0:15];
    wire [15:0] max_l1 [0:7];
    wire [15:0] max_l2 [0:3];
    wire [15:0] max_l3 [0:1];
    wire [15:0] max_all;

    wire [15:0] delta_all [0:15];
    wire [15:0] exp_all   [0:15];

    wire [15:0] sum_l1 [0:7];
    wire [15:0] sum_l2 [0:3];
    wire [15:0] sum_l3 [0:1];
    wire [15:0] sum_all;

    wire [15:0] quotient_all [0:15];
    reg [15:0] div_done_seen;
    wire [15:0] div_ready_all;
    wire [15:0] div_done_all;
    wire        all_div_ready;
    wire        div_start_all;

    // 0x4C56 represents FP16 17.34375.
    // exp(-17.34375) rounds to +0 in FP16 (RNE).
    reg [15:0] exp_rom [0:19541];
    initial $readmemh(EXP_FILE, exp_rom);
    // 绝对值 < 17.328 就直接近似为 0

    genvar i;

    // 16 个 scaled
    generate
      for(i=0;i<16;i=i+1) begin: GEN_SCALE
        fp16_mul scale_op(
            .a(raw_scores[i]),
            .b(16'h3400),
            .y(scaled_all[i])
        );
      end
    endgenerate

    // 比较器数 找 max_all
    generate
      for(i=0;i<8;i=i+1) begin:GEN_MAX_L1
        assign max_l1[i] = 
          less_than(scaled_all[2*i], scaled_all[2*i+1])
          ? scaled_all[2*i+1]
          : scaled_all[2*i];
      end
    endgenerate

    generate
      for(i=0;i<4;i=i+1) begin:GEN_MAX_L2
        assign max_l2[i] = 
          less_than(max_l1[2*i], max_l1[2*i+1])
          ? max_l1[2*i+1]
          : max_l1[2*i];
      end
    endgenerate

    generate
      for(i=0;i<2;i=i+1) begin:GEN_MAX_L3
        assign max_l3[i] = 
          less_than(max_l2[2*i], max_l2[2*i+1])
          ? max_l2[2*i+1]
          : max_l2[2*i];
      end
    endgenerate

    assign max_all = 
        less_than(max_l3[0], max_l3[1])
        ? max_l3[1]
        : max_l3[0];

    // 16 个 EXP
    generate
        for (i = 0; i < 16; i = i + 1) begin : GEN_EXP
            fp16_addsub subtract_op (
                .sub(1'b1),
                .a(scores[i]),
                .b(row_max),
                .y(delta_all[i])
            );
            assign exp_all[i] =
                (delta_all[i][14:0] <= 15'h4c55)
                ? exp_rom[delta_all[i][14:0]]
                : 16'h0000;
        end
    endgenerate

    // 计算分母的加法树
    generate
        for (i = 0; i < 8; i = i + 1) begin : GEN_SUM_L1
            fp16_addsub add_op (
                .sub(1'b0),
                .a(weights[2*i]),
                .b(weights[2*i+1]),
                .y(sum_l1[i])
            );
        end
    endgenerate
    generate
        for (i = 0; i < 4; i = i + 1) begin : GEN_SUM_L2
            fp16_addsub add_op (
                .sub(1'b0),
                .a(sum_l1[2*i]),
                .b(sum_l1[2*i+1]),
                .y(sum_l2[i])
            );
        end
    endgenerate
    generate
        for (i = 0; i < 2; i = i + 1) begin : GEN_SUM_L3
            fp16_addsub add_op (
                .sub(1'b0),
                .a(sum_l2[2*i]),
                .b(sum_l2[2*i+1]),
                .y(sum_l3[i])
            );
        end
    endgenerate
    fp16_addsub add_final (
        .sub(1'b0),
        .a(sum_l3[0]),
        .b(sum_l3[1]),
        .y(sum_all)
    );

    // 16 个 除法器
    generate
        for (i = 0; i < 16; i = i + 1) begin : GEN_DIV
            fp16_div divide_op (
                .clk(clk),
                .rst_n(rst_n),
                .start(div_start_all),
                .a(weights[i]),
                .b(denominator),
                .ready(div_ready_all[i]),
                .done(div_done_all[i]),
                .y(quotient_all[i])
            );
        end
    endgenerate

    assign all_div_ready = &div_ready_all; // 归约与
    assign div_start_all =(state == DIV_START) && all_div_ready;

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
            row_max <= 16'hfc00; // 16'hfc00 = 1111 1100 0000 0000 指数位为全1 && 尾数=0，表示-inf
            denominator <= 0;
            div_done_seen <= 16'b0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    state <= SCALE;
                    row_max <= 16'hfc00;
                    denominator <= 0;
                end
                SCALE: begin
                    for (integer j=0;j<16;j=j+1) begin
                        scores[j] <= scaled_all[j];
                    end
                    row_max <= max_all;
                    state <= EXP; 
                end
                EXP: begin
                    for (integer j = 0; j < 16; j = j + 1)
                        weights[j] <= exp_all[j];
                    state <= SUM;
                end
                SUM: begin
                    denominator <= sum_all;
                    state <= DIV_START;
                end
                DIV_START: begin
                    if (all_div_ready) begin
                        div_done_seen <= 16'b0;
                        state <= DIV_WAIT;
                    end
                end
                DIV_WAIT: begin
                    // Division latency is data-dependent; capture each lane only
                    // while its done pulse guarantees that quotient_all is valid.
                    for(integer j = 0; j < 16; j = j + 1) begin
                        if (div_done_all[j])
                            probabilities[j] <= quotient_all[j];
                    end
                    div_done_seen <= div_done_seen | div_done_all;
                    if(&(div_done_seen | div_done_all)) begin
                        state <= FINISH;
                    end
                end
                FINISH: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
