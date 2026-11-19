`timescale 1ns/1ps
// Single-tile FP16 adaptation of SCOPE (MICRO 2026, Figs. 9-11).
// QK, SCNA Exp and PV time-share the same 16x16 weight-stationary mesh.
module scope_attention_fp16 #(
    parameter integer STRIPS = 2 // 1: 8 Exp lanes plus standard PEs; 2: 16 Exp lanes
) (
    input wire clk, rst_n, in_valid,
    output wire in_ready,
    input wire [255:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [255:0] out_data,
    output wire [15:0] out_lane_valid,
    output wire out_last, busy,
    output reg done
);
    `include "scope_exp_coeffs.svh"
    localparam [3:0] IDLE=0, LOAD_K=1, COMMIT_K=2, QK=3, COMMIT_COEFF=4,
                     EXP=5, COMMIT_V=6, PV=7, DRAIN=8;
    localparam integer EXP_LANES=8*STRIPS;
    localparam integer EXP_BEATS=256/EXP_LANES;
    localparam [5:0] LAST_EXP_CAPTURE=6'(EXP_BEATS+8);
    reg [3:0] state;
    reg [5:0] tick, input_beat;
    reg write_bank, read_bank;
    reg [1:0] k_ready, full;
    reg [4:0] v_preloads;
    reg [255:0] q_rows [0:1][0:15], k_rows [0:1][0:15], v_columns [0:1][0:15];
    reg [15:0] scores [0:15][0:15], row_max [0:15];
    reg [15:0] p_rows [0:15][0:15];
    reg [15:0] p_ready;

    assign in_ready = rst_n && !full[write_bank];
    wire input_fire = in_ready && in_valid;
    wire retire = out_valid && out_ready && out_last;
    assign busy = rst_n && (state!=IDLE || input_beat!=0 || (|full) || (|k_ready));
    always @(posedge clk) if (input_fire) begin
        case (input_beat[5:4])
            0: q_rows[write_bank][input_beat[3:0]] <= in_data;
            1: k_rows[write_bank][input_beat[3:0]] <= in_data;
            2: v_columns[write_bank][input_beat[3:0]] <= in_data;
            default: ;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_beat<=0; write_bank<=0; k_ready<=0; full<=0;
        end else begin
            if (input_fire) begin
                if (input_beat==31) k_ready[write_bank]<=1;
                if (input_beat==47) begin
                    full[write_bank]<=1; write_bank<=~write_bank; input_beat<=0;
                end else input_beat<=input_beat+1'b1;
            end
            if (retire) begin full[read_bank]<=0; k_ready[read_bank]<=0; end
        end
    end

    // Shift W[k,j] rightward in reverse j order. The QK input wave ends at
    // tick 30. Coefficients can enter immediately behind it during its drain.
    wire preload_coeff = state==QK && tick>=31;
    wire preload_v = (state==EXP || state==COMMIT_V) && full[read_bank] && v_preloads<16;
    wire array_load = state==LOAD_K || preload_coeff || preload_v;
    wire commit_v = state==COMMIT_V && v_preloads==16 && p_ready[0];
    wire array_commit = state==COMMIT_K || state==COMMIT_COEFF || commit_v;
    reg wave_valid;
    reg [4:0] wave_diagonal;
    wire wave_space = !wave_valid || out_ready;
    wire [3:0] newest_p = tick<16 ? tick[3:0] : 4'd15;
    wire pv_step = state==PV && wave_space && (tick>30 || p_ready[newest_p]);
    wire qk_step = state==QK && tick<=45;
    wire array_gemm = qk_step || pv_step;
    wire array_scna = state==EXP && tick<LAST_EXP_CAPTURE;
    wire [255:0] west, x_in, gemm_out, exp_out;
    for (genvar k=0; k<16; k=k+1) begin : west_edge
        wire [5:0] row_index = tick-6'(k);
        wire [15:0] operand = state==QK ? q_rows[read_bank][row_index[3:0]][16*k +: 16]
                                        : p_rows[row_index[3:0]][k];
        // t=31 loads column 15 (bias); t=46 loads column 0 (weight).
        wire [15:0] coeff = tick[0] ? scope_exp_bias(3'(k%8)) : scope_exp_weight(3'(k%8));
        assign west[16*k +: 16] =
            state==LOAD_K ? k_rows[read_bank][4'd15-tick[3:0]][16*k +: 16] :
            preload_coeff ? coeff :
            preload_v ? v_columns[read_bank][4'd15-v_preloads[3:0]][16*k +: 16] :
            array_gemm && row_index<16 ? operand : 16'b0;
    end
    scope_array #(.STRIPS(STRIPS)) mesh (.clk,.rst_n,.load(array_load),.commit(array_commit),
        .gemm(array_gemm),.scna(array_scna),.west,.x_in,.gemm_out,.exp_out);

    function automatic [15:0] fp_max(input [15:0] a, b);
        if (a[14:0]==0 && b[14:0]==0) fp_max=a;
        else if (a[15]!=b[15]) fp_max=a[15] ? b : a;
        else if (a[15]) fp_max=a[14:0]<=b[14:0] ? a : b;
        else fp_max=a[14:0]>=b[14:0] ? a : b;
    endfunction

    // At t=16+i+j the registered bottom result is available to the ACC.
    // Every row sees j in ascending order, so its maximum reduces on arrival.
    for (genvar i=0; i<16; i=i+1) begin : score_rows
        wire [5:0] j = tick-6'(16+i);
        wire [15:0] scaled;
        fp16_mul scale (.a(gemm_out[16*j[3:0] +: 16]),.b(16'h3400),.y(scaled));
        always @(posedge clk) if (state==QK && tick>=16 && j<16) begin
            scores[i][j[3:0]] <= scaled;
            row_max[i] <= j==0 ? scaled : fp_max(row_max[i],scaled);
        end
    end

    // ACC restreams each row (or half-row for one strip) shifted by its max.
    wire [3:0] exp_input_row = STRIPS==2 ? tick[3:0] : tick[4:1];
    for (genvar j=0; j<16; j=j+1) begin : exp_input
        if (j<EXP_LANES) begin : active_lane
            wire [3:0] col = STRIPS==2 ? 4'(j) : {tick[0],3'(j)};
            wire [15:0] delta;
            fp16_addsub subtract_max (.sub(1'b1),.a(scores[exp_input_row][col]),
                .b(row_max[exp_input_row]),.y(delta));
            assign x_in[16*j +: 16] = tick<6'(EXP_BEATS) ? delta : 16'b0;
        end else begin : unused_lane
            assign x_in[16*j +: 16]=16'b0;
        end
    end
    // Eight paired rows give nine enabled edges from x to Exp. Capture the
    // registered result on the following edge (input beat 0 at tick 0 -> 9).
    wire [4:0] exp_index = 5'(tick-6'd9);
    wire exp_capture = state==EXP && tick>=9;
    wire [3:0] exp_output_row = STRIPS==2 ? exp_index[3:0] : exp_index[4:1];
    wire row_valid = exp_capture && (STRIPS==2 || exp_index[0]);
    wire [255:0] complete_exp;
    if (STRIPS==1) begin : half_rows
        wire [127:0] unused_exp_lanes = exp_out[255:128];
        reg [127:0] lower;
        always @(posedge clk) if (exp_capture && !exp_index[0]) lower<=exp_out[127:0];
        assign complete_exp={exp_out[127:0],lower};
    end else begin : whole_rows
        assign complete_exp=exp_out;
    end

    wire norm_valid;
    wire [3:0] norm_row;
    wire [15:0] probability [0:15];
    scope_row_acc acc (.clk,.rst_n,.advance(1'b1),.row_valid,.row_id(exp_output_row),.exp_row(complete_exp),
                       .norm_valid,.norm_row,.probability);
    always @(posedge clk) if (norm_valid)
        for (integer j=0; j<16; j=j+1) p_rows[norm_row][j]<=probability[j];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p_ready<=0;
        else if (retire) p_ready<=0;
        else if (norm_valid) p_ready[norm_row]<=1'b1;
    end

    // Hold the bottom registers and the diagonal tag together under backpressure.
    assign out_valid=rst_n && wave_valid;
    assign out_last=out_valid && wave_diagonal==30;
    for (genvar j=0; j<16; j=j+1) begin : output_cols
        wire [4:0] row_id=wave_diagonal-5'(j);
        assign out_lane_valid[j]=out_valid && row_id < 16;
        assign out_data[16*j +: 16]=out_lane_valid[j] ? gemm_out[16*j +: 16] : 16'b0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wave_valid<=0; wave_diagonal<=0; end
        else if (wave_space) begin
            wave_valid<=pv_step && tick>=15;
            if (pv_step && tick>=15) wave_diagonal<=5'(tick-6'd15);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state<=IDLE; tick<=0; read_bank<=0; v_preloads<=0; done<=0; end
        else begin
            done<=retire;
            if (preload_v) v_preloads<=v_preloads+1'b1;
            case (state)
                IDLE: if (k_ready[read_bank]) begin state<=LOAD_K; tick<=0; v_preloads<=0; end
                LOAD_K: if (tick==15) begin state<=COMMIT_K; tick<=0; end
                        else tick<=tick+1'b1;
                COMMIT_K: state<=QK;
                QK: if (tick==46) begin state<=COMMIT_COEFF; tick<=0; end
                    else tick<=tick+1'b1;
                COMMIT_COEFF: state<=EXP;
                EXP: if (tick==LAST_EXP_CAPTURE) begin state<=COMMIT_V; tick<=0; end
                     else tick<=tick+1'b1;
                COMMIT_V: if (commit_v) state<=PV;
                PV: if (pv_step) begin
                    if (tick==45) begin state<=DRAIN; tick<=0; end
                    else tick<=tick+1'b1;
                end
                DRAIN: if (retire) begin state<=IDLE; read_bank<=~read_bank; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
