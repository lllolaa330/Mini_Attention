`timescale 1ns/1ps
// 一个 16*16 的 OS PE 阵列 实现 QKT 与 PV
// online_softmax16 单元 +  16个prob_div单元实现 online softmax
module attention_fp16 #(
    parameter EXP_FILE = "rtl/exp_fp16.hex"
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
    localparam [1:0] LOAD=0, CLEAR=1, COMPUTE=2, DRAIN=3;
    reg [1:0] state;
    reg [9:0] load_count;
    reg [5:0] qk_age, feed_step;
    reg write_bank, compute_bank;
    reg [1:0] qk_ready, bank_full;
    reg [15:0] q_mem [0:511], k_mem [0:511], v_mem [0:511];
    reg [15:0] p_mem [0:15][0:15];   // Each row head takes 16 words in parallel.
    reg [15:0] p_ready;
    reg wave_valid, skid_valid;
    reg [4:0] wave_diagonal;
    wire wave_ready = !skid_valid || out_ready;
    wire wave_slot_available = !wave_valid || wave_ready;

    // All row and column inputs have injected their last Q/K word after step
    // 30. QK tokens can still be computing in the lower-right corner until 45.
    wire array_clear = state == CLEAR;
    wire qk_step = state == COMPUTE && qk_age <= 6'd45;
    wire [8:0] v_words_ready = bank_full[compute_bank] ? 9'd256 :
        (write_bank == compute_bank && load_count[9:8] == 2 ? {1'b0,load_count[7:0]} : 9'd0);
    wire [3:0] newest = feed_step < 16 ? feed_step[3:0] : 4'd15;
    wire [3:0] first_col = 4'(feed_step - {2'b0,newest});
    wire v_ready = feed_step > 30 || v_words_ready > {1'b0,newest,first_col};
    // Rows return in order. If the newest active row is ready, earlier ones
    // are also ready. After boundary injection ends, only internal tokens move.
    wire pv_inputs_ready = v_ready && p_ready[newest];
    wire pv_step = state == COMPUTE && qk_age >= 31 && pv_inputs_ready && wave_slot_available;
    wire array_step = qk_step || pv_step;

    wire [15:0] a_edge [0:15], b_edge [0:15];
    wire [15:0] edge_valid;
    wire [30:0] diagonal_enable, diagonal_first;
    wire [15:0] accum [0:15][0:15];
    genvar lane, d;
    generate
        for (lane=0; lane<16; lane=lane+1) begin : edges
            wire [5:0] q_idx = qk_age - 6'(lane);
            wire [5:0] p_idx = feed_step - 6'(lane);
            wire q_input = qk_step && q_idx < 16;
            wire p_input = pv_step && p_idx < 16;
            assign edge_valid[lane] = q_input || p_input;
            assign a_edge[lane] = q_input ? q_mem[{compute_bank,4'(lane),q_idx[3:0]}] :
                                  p_input ? p_mem[lane][p_idx[3:0]] : 16'b0;
            assign b_edge[lane] = q_input ? k_mem[{compute_bank,4'(lane),q_idx[3:0]}] :
                                  p_input ? v_mem[{compute_bank,p_idx[3:0],4'(lane)}] : 16'b0;
        end
        for (d=0; d<31; d=d+1) begin : diagonals
            // PE[i,j] consumes k at logical step i+j+k of either wave. Once
            // PV can start, these two intervals can never coincide at one PE.
            // A negative offset wraps to at least 34 in these six-bit counters.
            wire [5:0] q_term = qk_age - 6'(d);
            wire [5:0] p_term = feed_step - 6'(d);
            wire q_active = qk_step && q_term < 16;
            wire p_active = pv_step && p_term < 16;
            assign diagonal_enable[d] = q_active || p_active;
            assign diagonal_first[d] = (qk_step && q_term == 0) || (pv_step && p_term == 0);
        end
    endgenerate
    systolic_array #(.N(16), .DIAGONAL_CONTROL(1'b1)) array_core (
        .clk(clk), .rst_n(rst_n), .clear(array_clear), .step(array_step),
        .a_edge(a_edge), .b_edge(b_edge), .a_valid(edge_valid), .b_valid(edge_valid),
        .accum(accum), .diagonal_enable(diagonal_enable), .diagonal_first(diagonal_first)
    );

    // Read each completed QK sum exactly once on the following clock. Scores
    // have already been saved by the time PV can reuse that PE's accumulator.
    reg score_wave;
    reg [4:0] score_diagonal;
    wire [15:0] score_valid;
    wire [3:0] score_col [0:15];
    wire [15:0] raw_score [0:15];
    generate
        for (lane=0; lane<16; lane=lane+1) begin : scores
            wire [4:0] col = score_diagonal - 5'(lane);
            assign score_col[lane] = col[3:0];
            assign score_valid[lane] = score_wave && !col[4];
            assign raw_score[lane] = accum[lane][col[3:0]];
        end
    endgenerate

    wire norm_issue /* verilator public_flat_rd */;
    wire [3:0] norm_issue_row /* verilator public_flat_rd */;
    wire prob_valid;
    wire [3:0] prob_row;
    wire [15:0] probability [0:15];
    online_softmax16 #(.EXP_FILE(EXP_FILE)) normalizer (
        .clk(clk), .rst_n(rst_n), .clear(array_clear),
        .score_valid(score_valid), .score_col(score_col), .raw_score(raw_score),
        .norm_issue(norm_issue), .norm_issue_row(norm_issue_row),
        .prob_valid(prob_valid), .prob_row(prob_row), .probability(probability)
    );
    always @(posedge clk) begin
        if (prob_valid)
            for (integer j=0; j<16; j=j+1) p_mem[prob_row][j] <= probability[j];
    end

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
            wave_valid <= pv_step && feed_step >= 6'd15;
            if (pv_step && feed_step >= 6'd15)
                wave_diagonal <= 5'(feed_step - 6'd15);
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LOAD;
            compute_bank <= 0;
            qk_age <= 0;
            feed_step <= 0;
            score_wave <= 0;
            score_diagonal <= 0;
            p_ready <= 0;
            done <= 0;
        end else begin
            done <= retire;
            score_wave <= qk_step && qk_age >= 15;
            if (qk_step && qk_age >= 15)
                score_diagonal <= 5'(qk_age - 6'd15);
            if (prob_valid) p_ready[prob_row] <= 1'b1;
            case (state)
                LOAD: if (current_k_ready) state <= CLEAR;
                CLEAR: begin
                    qk_age <= 0;
                    feed_step <= 0;
                    p_ready <= 0;
                    state <= COMPUTE;
                end
                COMPUTE: begin
                    if (qk_step) qk_age <= qk_age + 1'b1;
                    if (pv_step) begin
                        if (feed_step == 45) state <= DRAIN;
                        else feed_step <= feed_step + 1'b1;
                    end
                end
                DRAIN: if (retire) begin
                    compute_bank <= ~compute_bank;
                    state <= LOAD;
                end
            endcase
        end
    end
endmodule
