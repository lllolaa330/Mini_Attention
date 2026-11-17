`timescale 1ns/1ps
// Two matrix passes share one 16x16 output-stationary array.
module attention_fp16 #(
    parameter EXP_FILE = "rtl/exp_fp16.hex"
) (
    input wire clk, rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [15:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [15:0] out_data,
    output wire out_last, busy,
    output reg done
);
    localparam LOAD=0, CLEAR_QK=1, RUN_QK=2, SM_START=3,
               SM_WAIT=4, CLEAR_PV=5, RUN_PV=6, EMIT=7;
    reg [2:0] state;
    reg [9:0] load_count;
    reg [5:0] feed_step;
    reg [3:0] sm_row;
    reg [7:0] out_index;
    reg [15:0] q_mem [0:255], k_mem [0:255], v_mem [0:255], p_mem [0:255];
    reg [15:0] a_edge [0:15], b_edge [0:15];
    reg [15:0] a_valid, b_valid;
    wire [15:0] accum [0:15][0:15];
    wire [15:0] row_scores [0:15], row_probabilities [0:15];
    wire sm_done;

    systolic_array #(.N(16)) array_core (
        .clk(clk), .rst_n(rst_n), .clear(state == CLEAR_QK || state == CLEAR_PV),
        .step(state == RUN_QK || state == RUN_PV),
        .a_edge(a_edge), .b_edge(b_edge), .a_valid(a_valid), .b_valid(b_valid), .accum(accum)
    );
    genvar j;
    generate for (j=0; j<16; j=j+1) begin: row_select
        assign row_scores[j] = accum[sm_row][j];
    end endgenerate
    softmax_fp16 #(.EXP_FILE(EXP_FILE)) sm (
        .clk(clk), .rst_n(rst_n), .start(state == SM_START),
        .raw_scores(row_scores), .probabilities(row_probabilities), .done(sm_done)
    );

    integer lane, k;
    always @* begin
        a_valid = 0;
        b_valid = 0;
        k = 0;
        for (lane=0; lane<16; lane=lane+1) begin
            a_edge[lane] = 0;
            b_edge[lane] = 0;
            k = int'(feed_step) - lane;
            if ((k >= 0) && (k < 16)) begin
                if (state == RUN_QK) begin
                    a_edge[lane] = q_mem[lane*16+k];
                    b_edge[lane] = k_mem[lane*16+k];
                    a_valid[lane] = 1'b1;
                    b_valid[lane] = 1'b1;
                end else if (state == RUN_PV) begin
                    a_edge[lane] = p_mem[lane*16+k];
                    b_edge[lane] = v_mem[k*16+lane];
                    a_valid[lane] = 1'b1;
                    b_valid[lane] = 1'b1;
                end
            end
        end
    end

    assign in_ready = rst_n && state == LOAD;
    assign out_valid = rst_n && state == EMIT;
    assign out_data = accum[out_index[7:4]][out_index[3:0]];
    assign out_last = out_valid && out_index == 255;
    assign busy = rst_n && ((state != LOAD) || (load_count != 0));

    integer col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LOAD;
            load_count <= 0;
            feed_step <= 0;
            sm_row <= 0;
            out_index <= 0;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                LOAD: if (in_valid && in_ready) begin
                    case (load_count[9:8])
                        0: q_mem[load_count[7:0]] <= in_data;
                        1: k_mem[load_count[7:0]] <= in_data;
                        2: v_mem[load_count[7:0]] <= in_data;
                        default: ;
                    endcase
                    if (load_count == 767) begin load_count <= 0; state <= CLEAR_QK; end
                    else load_count <= load_count + 1'b1;
                end
                CLEAR_QK: begin feed_step <= 0; sm_row <= 0; state <= RUN_QK; end
                RUN_QK: begin
                    if (feed_step == 45) state <= SM_START;
                    else feed_step <= feed_step + 1'b1;
                end
                SM_START: state <= SM_WAIT;
                SM_WAIT: if (sm_done) begin
                    for (col=0; col<16; col=col+1)
                        p_mem[int'(sm_row)*16+col] <= row_probabilities[col];
                    if (sm_row == 15) state <= CLEAR_PV;
                    else begin sm_row <= sm_row + 1'b1; state <= SM_START; end
                end
                CLEAR_PV: begin feed_step <= 0; state <= RUN_PV; end
                RUN_PV: begin
                    if (feed_step == 45) begin out_index <= 0; state <= EMIT; end
                    else feed_step <= feed_step + 1'b1;
                end
                EMIT: if (out_ready) begin
                    if (out_index == 255) begin out_index <= 0; state <= LOAD; done <= 1; end
                    else out_index <= out_index + 1'b1;
                end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
