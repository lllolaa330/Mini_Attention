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
    output wire [255:0] out_data,
    output wire [15:0] out_lane_valid,
    output wire out_last, busy,
    output reg done
);
    localparam LOAD=0, CLEAR_QK=1, RUN_QK=2, SM_START=3,
               SM_WAIT=4, CLEAR_PV=5, RUN_PV=6, DRAIN=7,
               LOAD_W_QK=8;
    // WS captures the registered bottom-row result one step after its last FMA.
    localparam [5:0] LAST_STEP = USE_WS ? 6'd46 : 6'd45;
    localparam [5:0] FIRST_RESULT = USE_WS ? 6'd16 : 6'd15;
    reg [3:0] state;
    reg [9:0] load_count;
    reg [5:0] feed_step;
    reg write_bank, compute_bank;
    reg [1:0] qk_ready, bank_full;
    reg [15:0] q_mem [0:511], k_mem [0:511], v_mem [0:511];
    reg [15:0] p_mem [0:255];
    reg wave_valid, skid_valid;
    reg [4:0] wave_diagonal;
    wire wave_ready = !skid_valid || out_ready;
    wire wave_slot_available = !wave_valid || wave_ready;
    wire [8:0] v_words_ready = bank_full[compute_bank] ? 9'd256 :
        (write_bank == compute_bank && load_count[9:8] == 2 ? {1'b0, load_count[7:0]} : 9'd0);
    wire pv_inputs_ready;
    wire pv_step = state == RUN_PV && pv_inputs_ready && wave_slot_available;
    wire [15:0] accum [0:15][0:15];
    wire [15:0] sm_probabilities [0:15][0:15];
    wire [15:0] sm_done;
    reg [15:0] sm_done_mask;

    wire array_clear = (state == CLEAR_QK || state == CLEAR_PV);
    wire array_step = (state == RUN_QK) || pv_step;

    // The largest inner index needed for the first time by step t is min(t,15).
    wire [3:0] newest_k = feed_step < 16 ? feed_step[3:0] : 4'd15;
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
            wire load_weights = state == LOAD_W_QK;
            wire [15:0] v_row_data [0:15];
            // Installed V rows form a prefix. QK still owns the weights until
            // its last step; from SM_START onward, complete V rows can replace K.
            reg [4:0] rows_installed;
            wire [3:0] ws_load_row = rows_installed[3:0];
            wire ws_row_load = (state == SM_START || state == SM_WAIT ||
                                  state == CLEAR_PV || state == RUN_PV)
                                 && v_words_ready > {rows_installed, 4'hf};
            assign pv_inputs_ready = rows_installed > {1'b0, newest_k};
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) rows_installed <= 0;
                else if (state == CLEAR_QK) rows_installed <= 0;
                else if (ws_row_load) rows_installed <= rows_installed + 1'b1;
            end
            wire [3:0] weight_k = 4'd15 - feed_step[3:0];
            wire [15:0] weight_edge [0:15], a_edge [0:15];

            for (lane=0; lane<16; lane=lane+1) begin : edges
                // Load bottom k first. One shift per cycle puts B[k,j] in PE[k,j].
                assign weight_edge[lane] = k_mem[{compute_bank, 4'(lane), weight_k}];
                assign v_row_data[lane] = v_mem[{compute_bank, ws_load_row, 4'(lane)}];

                // At step t, physical row k receives A[i,k] where i = t-k.
                wire [3:0] input_row = edge_index[lane];
                assign a_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? q_mem[{compute_bank, input_row, 4'(lane)}]
                                       : p_mem[int'(input_row)*16 + lane])
                    : 16'h0000;
            end

            ws_systolic_array #(.N(16), .DIRECT_V(1'b1)) array_core (
                .clk(clk), .rst_n(rst_n), .clear(array_clear), .load_weights(load_weights),
                .row_load(ws_row_load), .row_addr(ws_load_row), .row_data(v_row_data),
                .step(array_step), .weight_edge(weight_edge), .a_edge(a_edge),
                .a_valid(edge_valid), .accum(accum)
            );
        end else begin : array_impl
            // Required OS top-edge words have k+j=t. In row-major memory the
            // biggest address is in the newest row, at column t-newest_k.
            wire [3:0] first_col = 4'(feed_step - {2'b00, newest_k});
            wire [7:0] last_needed_address = {newest_k, first_col};
            assign pv_inputs_ready = feed_step > 30 || v_words_ready > {1'b0, last_needed_address};
            wire [15:0] a_edge [0:15], b_edge [0:15];
            for (lane=0; lane<16; lane=lane+1) begin : edges
                // At step t, lane l sends the inner term k = t-l.
                wire [3:0] k = edge_index[lane];
                assign a_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? q_mem[{compute_bank, 4'(lane), k}] : p_mem[lane*16 + int'(k)])
                    : 16'h0000;
                assign b_edge[lane] = edge_valid[lane]
                    ? (state == RUN_QK ? k_mem[{compute_bank, 4'(lane), k}] : v_mem[{compute_bank, k, 4'(lane)}])
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

    // The writer owns an input bank until word 767. It may fill the other
    // bank while this frame computes or waits for its last output handshake.
    assign in_ready = rst_n && !bank_full[write_bank];
    wire input_fire = in_valid && in_ready;
    wire end_k = input_fire && load_count == 511;
    wire end_v = input_fire && load_count == 767;
    wire current_k_ready = qk_ready[compute_bank] || (write_bank == compute_bank && end_k);
    wire retire = out_valid && out_ready && out_last;
    assign busy = rst_n && (load_count != 0 || (|bank_full) || state != LOAD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_bank <= 0;
            load_count <= 0;
            qk_ready <= 0;
            bank_full <= 0;
        end else begin
            if (input_fire) begin
                case (load_count[9:8])
                    0: q_mem[{write_bank, load_count[7:0]}] <= in_data;
                    1: k_mem[{write_bank, load_count[7:0]}] <= in_data;
                    2: v_mem[{write_bank, load_count[7:0]}] <= in_data;
                    default: ;
                endcase
                if (end_k) qk_ready[write_bank] <= 1;
                if (end_v) begin
                    bank_full[write_bank] <= 1;
                    write_bank <= ~write_bank;
                    load_count <= 0;
                end else load_count <= load_count + 1'b1;
            end
            if (retire) begin
                bank_full[compute_bank] <= 0;
                qk_ready[compute_bank] <= 0;
            end
        end
    end

    // A registered array result is available immediately after its producing
    // step. On diagonal d, lane j holds Y[d-j,j] when that row exists.
    wire [255:0] wave_data;
    wire [15:0] wave_mask;
    wire wave_last = wave_valid && wave_diagonal == 30;
    generate
        for (lane=0; lane<16; lane=lane+1) begin : output_lanes
            // Negative rows wrap into [17,31], above the valid range [0,15].
            wire [4:0] result_row = wave_diagonal - 5'(lane);
            assign wave_mask[lane] = wave_valid && !result_row[4];
            assign wave_data[16*lane +: 16] = wave_mask[lane] ? accum[result_row[3:0]][lane] : 16'b0;
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wave_valid <= 0;
            wave_diagonal <= 0;
        end else if (wave_slot_available) begin
            // A consumed group must clear even if missing V holds feed_step.
            wave_valid <= pv_step && feed_step >= FIRST_RESULT;
            if (pv_step && feed_step >= FIRST_RESULT)
                wave_diagonal <= 5'(feed_step - FIRST_RESULT);
        end
    end

    // Bypass when the sink is ready. On the first stalled beat the skid
    // register takes that whole beat; a second pending beat holds the array.
    reg [255:0] skid_data;
    reg [15:0] skid_mask;
    reg skid_last;
    wire save_wave = wave_valid && (skid_valid || !out_ready);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_valid <= 0;
            skid_data <= 0;
            skid_mask <= 0;
            skid_last <= 0;
        end else if (wave_ready) begin
            skid_valid <= save_wave;
            if (save_wave) begin
                skid_data <= wave_data;
                skid_mask <= wave_mask;
                skid_last <= wave_last;
            end
        end
    end
    assign out_valid = rst_n && (skid_valid || wave_valid);
    assign out_lane_valid = skid_valid ? skid_mask : wave_mask;
    assign out_data = skid_valid ? skid_data : wave_data;
    assign out_last = out_valid && (skid_valid ? skid_last : wave_last);

    integer row, col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LOAD;
            compute_bank <= 0;
            feed_step <= 0;
            sm_done_mask <= 0;
            done <= 0;
        end else begin
            done <= retire;
            case (state)
                LOAD: if (current_k_ready) state <= CLEAR_QK;
                CLEAR_QK: begin feed_step <= 0; state <= USE_WS ? LOAD_W_QK : RUN_QK; end
                LOAD_W_QK: begin
                    if (feed_step == 15) begin
                        feed_step <= 0;
                        state <= RUN_QK;
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
                CLEAR_PV: begin feed_step <= 0; state <= RUN_PV; end
                RUN_PV: if (pv_step) begin
                    if (feed_step == LAST_STEP) state <= DRAIN;
                    else feed_step <= feed_step + 1'b1;
                end
                DRAIN: if (retire) begin
                    compute_bank <= ~compute_bank;
                    state <= LOAD;
                end
                default: state <= LOAD;
            endcase
        end
    end
endmodule
