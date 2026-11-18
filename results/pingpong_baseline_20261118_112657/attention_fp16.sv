`timescale 1ns/1ps
// QK transpose and PV share one 16x16 array in the selected dataflow.
module attention_fp16 #(
    parameter EXP_FILE = "rtl/exp_fp16.hex",
    parameter bit USE_WS = 1'b0
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
               SM_WAIT=4, CLEAR_PV=5, RUN_PV=6, EMIT=7,
               LOAD_W_QK=8, LOAD_W_PV=9;
    // WS captures the registered bottom-row result one step after its last FMA.
    localparam [5:0] LAST_STEP = USE_WS ? 6'd46 : 6'd45;
    reg [3:0] state;
    reg [9:0] load_count;
    reg [5:0] feed_step;
    reg [7:0] out_index;
    reg [15:0] q_mem [0:255], k_mem [0:255], v_mem [0:255], p_mem [0:255];
    wire [15:0] accum [0:15][0:15];
    wire [15:0] sm_probabilities [0:15][0:15];
    wire [15:0] sm_done;
    reg [15:0] sm_done_mask;

    wire array_clear = (state == CLEAR_QK || state == CLEAR_PV);
    wire array_step = (state == RUN_QK || state == RUN_PV);

    wire [15:0] edge_valid;
    wire [3:0] edge_index [0:15];
    genvar lane;
    generate
        for (lane=0; lane<16; lane=lane+1) begin : skew
            // On both dataflows lane l sees index t-l. Wrapped negatives exceed 15.
            wire [5:0] offset = feed_step - 6'(lane);
            assign edge_index[lane] = offset[3:0];
            assign edge_valid[lane] = array_step && offset < 6'd16;
        end

        if (USE_WS) begin : array_impl
            wire load_weights = (state == LOAD_W_QK || state == LOAD_W_PV);
            wire [3:0] weight_k = 4'd15 - feed_step[3:0];
            wire [15:0] weight_edge [0:15], a_edge [0:15];

            for (lane=0; lane<16; lane=lane+1) begin : edges
                // Load bottom k first. One shift per cycle puts B[k,j] in PE[k,j].
                assign weight_edge[lane] = state == LOAD_W_QK
                    ? k_mem[lane*16 + int'(weight_k)] : v_mem[int'(weight_k)*16 + lane];

                // At step t, physical row k receives A[i,k] where i = t-k.
                wire [3:0] input_row = edge_index[lane];
                assign a_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? q_mem[int'(input_row)*16 + lane]
                                       : p_mem[int'(input_row)*16 + lane])
                    : 16'h0000;
            end

            ws_systolic_array #(.N(16)) array_core (
                .clk(clk), .rst_n(rst_n), .clear(array_clear), .load_weights(load_weights),
                .step(array_step), .weight_edge(weight_edge), .a_edge(a_edge),
                .a_valid(edge_valid), .accum(accum)
            );
        end else begin : array_impl
            wire [15:0] a_edge [0:15], b_edge [0:15];
            for (lane=0; lane<16; lane=lane+1) begin : edges
                // At step t, lane l sends the inner term k = t-l.
                wire [3:0] k = edge_index[lane];
                assign a_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? q_mem[lane*16 + int'(k)] : p_mem[lane*16 + int'(k)])
                    : 16'h0000;
                assign b_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? k_mem[lane*16 + int'(k)] : v_mem[int'(k)*16 + lane])
                    : 16'h0000;
            end

            systolic_array #(.N(16)) array_core (
                .clk(clk), .rst_n(rst_n), .clear(array_clear), .step(array_step),
                .a_edge(a_edge), .b_edge(b_edge), .a_valid(edge_valid), .b_valid(edge_valid),
                .accum(accum)
            );
        end
    endgenerate

    genvar i,j;
    generate
        for (i=0; i<16; i=i+1) begin: parallel_softmax
            wire [15:0] row_scores [0:15];
            wire [15:0] row_probabilities [0:15];
            for (j=0; j<16; j=j+1) begin: connect_row
                assign row_scores[j] = accum[i][j];
                assign sm_probabilities[i][j] = row_probabilities[j];
            end
            softmax_fp16 #(
                .EXP_FILE(EXP_FILE)
            ) sm (
                .clk(clk),
                .rst_n(rst_n),
                .start(state == SM_START),
                .raw_scores(row_scores),
                .probabilities(row_probabilities),
                .done(sm_done[i])
            );
        end
    endgenerate

    assign in_ready = rst_n && state == LOAD;
    assign out_valid = rst_n && state == EMIT;
    assign out_data = accum[out_index[7:4]][out_index[3:0]];
    assign out_last = out_valid && out_index == 255;
    assign busy = rst_n && ((state != LOAD) || (load_count != 0));

    integer row, col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LOAD;
            load_count <= 0;
            feed_step <= 0;
            out_index <= 0;
            sm_done_mask <= 0;
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
                CLEAR_QK: begin feed_step <= 0; state <= USE_WS ? LOAD_W_QK : RUN_QK; end
                LOAD_W_QK, LOAD_W_PV: begin
                    if (feed_step == 15) begin
                        feed_step <= 0;
                        state <= state == LOAD_W_QK ? RUN_QK : RUN_PV;
                    end else feed_step <= feed_step + 1'b1;
                end
                RUN_QK: begin
                    if (feed_step == LAST_STEP) state <= SM_START;
                    else feed_step <= feed_step + 1'b1;
                end
                SM_START: begin
                  sm_done_mask <= 0;
                    state <= SM_WAIT;
                end
                SM_WAIT: begin
                    for (row=0; row<16; row=row+1) begin
                        if (sm_done[row]) begin
                            sm_done_mask[row] <= 1'b1;
                            for (col=0; col<16; col=col+1) begin
                                p_mem[row*16+col] <= sm_probabilities[row][col];
                            end
                        end
                    end
                    if(&(sm_done_mask | sm_done)) begin
                        state <= CLEAR_PV;
                    end
                end
                CLEAR_PV: begin feed_step <= 0; state <= USE_WS ? LOAD_W_PV : RUN_PV; end
                RUN_PV: begin
                    if (feed_step == LAST_STEP) begin out_index <= 0; state <= EMIT; end
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
