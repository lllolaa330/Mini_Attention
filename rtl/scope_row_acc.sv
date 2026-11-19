`timescale 1ns/1ps
// ACC side of Softmax: four registered row-sum stages, then direct binary16
// E/sum. A new row is accepted every clock. All four sums round with RNE.
module scope_row_acc (
    input wire clk, rst_n, advance, row_valid,
    input wire [3:0] row_id,
    input wire [255:0] exp_row,
    output wire norm_valid,
    output wire [3:0] norm_row,
    output wire [15:0] probability [0:15]
);
    reg [5:0] valid_pipe;
    reg [3:0] row_pipe [0:5];
    reg [255:0] exp_pipe [0:3];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe <= 0;
        else if (advance) valid_pipe <= {valid_pipe[4:0],row_valid};
    end
    always @(posedge clk) if (advance) begin
        if (row_valid) begin
            row_pipe[0] <= row_id;
            exp_pipe[0] <= exp_row;
        end
        for (integer s=1; s<6; s=s+1)
            if (valid_pipe[s-1]) row_pipe[s] <= row_pipe[s-1];
        for (integer s=1; s<4; s=s+1)
            if (valid_pipe[s-1]) exp_pipe[s] <= exp_pipe[s-1];
    end
    for (genvar level=0; level<4; level=level+1) begin : tree
        localparam integer WIDTH=8>>level;
        reg [15:0] sum [0:WIDTH-1];
        for (genvar j=0; j<WIDTH; j=j+1) begin : nodes
            wire [15:0] a, b, y;
            if (level==0) begin : from_exp
                assign a=exp_row[32*j +: 16];
                assign b=exp_row[32*j+16 +: 16];
                always @(posedge clk) if (advance && row_valid) sum[j] <= y;
            end else begin : from_sum
                assign a=tree[level-1].sum[2*j];
                assign b=tree[level-1].sum[2*j+1];
                always @(posedge clk) if (advance && valid_pipe[level-1]) sum[j] <= y;
            end
            fp16_addsub add (.sub(1'b0),.a(a),.b(b),.y(y));
        end
    end
    for (genvar j=0; j<16; j=j+1) begin : divide
        fp16_prob_div div (.clk, .stage1_enable(advance && valid_pipe[3]), .stage2_enable(advance && valid_pipe[4]),
                           .a(exp_pipe[3][16*j +: 16]), .b(tree[3].sum[0]), .y(probability[j]));
    end
    assign norm_valid = valid_pipe[5];
    assign norm_row = row_pipe[5];
endmodule
