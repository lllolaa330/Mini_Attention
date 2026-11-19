`timescale 1ns/1ps
// 52-edge periodic OS schedule. The age vector contains actual admissions,
// so empty frame slots drain naturally. All mesh/ACC state uses one advance.
module os_scope_attention_fp16 (
    input wire clk, rst_n, in_valid,
    output wire in_ready,
    input wire [255:0] in_data,
    output wire out_valid, input wire out_ready,
    output wire [255:0] out_data, output wire [15:0] out_lane_valid,
    output wire out_last, busy, output reg done
);
    function automatic [1:0] next_v(input [1:0] bank);
        next_v = bank == 2 ? 2'd0 : bank + 1'b1;
    endfunction
    // Index into a 16-beat window, including windows crossing phase 51.
    // Callers gate its use with an admission of the appropriate age.
    function automatic [3:0] window_index(input [5:0] phase_now, origin);
        window_index = phase_now >= origin ? 4'(phase_now-origin)
                                          : 4'(phase_now+6'd52-origin);
    endfunction
    function automatic [15:0] fp_max(input [15:0] a, b);
        if (a[14:0]==0 && b[14:0]==0) fp_max=a;
        else if (a[15]!=b[15]) fp_max=a[15] ? b : a;
        else if (a[15]) fp_max=a[14:0]<=b[14:0] ? a : b;
        else fp_max=a[14:0]>=b[14:0] ? a : b;
    endfunction

    reg [255:0] q_rows [0:1][0:15], k_rows [0:1][0:15];
    reg [255:0] v_columns [0:2][0:15], p_rows [0:1][0:15];
    reg [5:0] in_beat, phase;
    reg write_q, launch_q;
    reg [1:0] write_v, launch_v;
    reg [1:0] q_full;
    reg [2:0] v_full;
    wire input_v = in_beat[5];
    assign in_ready = rst_n && (input_v ? !v_full[write_v] : !q_full[write_q]);
    wire input_fire = in_valid && in_ready;
    wire launch = rst_n && phase==0 && q_full[launch_q];

    // Age 0 issues the first QK MAC, 120 the first PV MAC, and 165 the
    // last PV MAC. At most one frame can occupy any 52 consecutive ages.
    reg [164:0] history;
    wire [165:0] age_valid = {history,launch};
    reg [149:0] q_history, v_low_history, v_high_history;
    wire [150:0] q_tag = {q_history,launch_q};
    wire [150:0] v_low = {v_low_history,launch_v[0]};
    wire [150:0] v_high = {v_high_history,launch_v[1]};
    wire [1:0] entering_pv_v = {v_high[120],v_low[120]};
    wire [1:0] releasing_v = {v_high[150],v_low[150]};
    reg wave_valid;
    reg [4:0] wave_diagonal;
    wire output_space = !wave_valid || out_ready;
    wire step = rst_n && (launch || (|history)) && output_space
                && (!age_valid[120] || v_full[entering_pv_v]);
    assign busy = rst_n && (in_beat!=0 || (|q_full) || (|v_full) || (|history) || wave_valid);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase<=0; history<=0; q_history<=0; v_low_history<=0; v_high_history<=0;
            launch_q<=0; launch_v<=0;
        end else if (step) begin
            history<=age_valid[164:0];
            q_history<=q_tag[149:0]; v_low_history<=v_low[149:0]; v_high_history<=v_high[149:0];
            phase<=phase==51 ? 6'd0 : phase+1'b1;
            if (launch) begin launch_q<=~launch_q; launch_v<=next_v(launch_v); end
        end else if (!(|history)) phase<=0;
    end

    always @(posedge clk) if (input_fire) begin
        case (in_beat[5:4])
            0: q_rows[write_q][in_beat[3:0]] <= in_data;
            1: k_rows[write_q][in_beat[3:0]] <= in_data;
            2: v_columns[write_v][in_beat[3:0]] <= in_data;
            default: ;
        endcase
    end
    // Separate Q/K and V reservations: the following Q/K can arrive while
    // its V slot is still streaming an older frame into the array.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_beat<=0; write_q<=0; write_v<=0; q_full<=0; v_full<=0;
        end else begin
            if (input_fire) begin
                in_beat<=in_beat==47 ? 6'd0 : in_beat+1'b1;
                if (in_beat==31) begin q_full[write_q]<=1; write_q<=~write_q; end
                if (in_beat==47) begin v_full[write_v]<=1; write_v<=next_v(write_v); end
            end
            if (step && age_valid[30]) q_full[q_tag[30]]<=0;
            if (step && age_valid[150]) v_full[releasing_v]<=0;
        end
    end

    wire [30:0] qk_diag_valid, pv_diag_valid, gemm_diag_first, exp_diag_valid;
    wire [30:0] gemm_diag_valid = qk_diag_valid | pv_diag_valid;
    for (genvar d=0; d<31; d=d+1) begin : diagonals
        assign qk_diag_valid[d] = |age_valid[d +: 16];
        assign pv_diag_valid[d] = |age_valid[120+d +: 16];
        assign exp_diag_valid[d] = |age_valid[32+d +: 16];
        assign gemm_diag_first[d] = age_valid[d] || age_valid[120+d];
    end
    wire [255:0] west, north, x_in, exp_out;
    wire [4095:0] accum;
    // Only phases 0..30 read a Q/K slot and 16..46 read a P/V slot.
    wire q_source = q_tag[{2'b0,phase}];
    wire [7:0] pv_age = 8'd104 + {2'b0,phase};
    wire p_source = q_tag[pv_age];
    wire [1:0] v_source = {v_high[pv_age],v_low[pv_age]};
    for (genvar lane=0; lane<16; lane=lane+1) begin : boundary
        wire [3:0] qk_k = 4'(phase-6'(lane));
        wire [3:0] pv_k = 4'(phase-6'(16+lane));
        assign west[16*lane +: 16] = qk_diag_valid[lane] ? q_rows[q_source][lane][16*qk_k +: 16]
              : pv_diag_valid[lane] ? p_rows[p_source][lane][16*pv_k +: 16] : 16'b0;
        assign north[16*lane +: 16] = qk_diag_valid[lane] ? k_rows[q_source][lane][16*qk_k +: 16]
              : pv_diag_valid[lane] ? v_columns[v_source][lane][16*pv_k +: 16] : 16'b0;
    end
    os_scope_array mesh (.clk,.rst_n,.step,.west,.north,.x_in,.gemm_diag_valid,
                         .gemm_diag_first,.exp_diag_valid,.accum,.exp_out);

    reg [15:0] scores [0:15][0:15], row_max [0:15];
    for (genvar i=0; i<16; i=i+1) begin : score_row
        wire [3:0] col = 4'(phase-6'(16+i));
        wire [15:0] scaled;
        fp16_mul scale (.a(accum[256*i+16*col +: 16]),.b(16'h3400),.y(scaled));
        always @(posedge clk) if (step && (|age_valid[16+i +: 16])) begin
            scores[i][col]<=scaled;
            row_max[i]<=col==0 ? scaled : fp_max(row_max[i],scaled);
        end
    end

    wire [3:0] reduce_row = window_index(phase,6'(63%52));
    wire [255:0] exp_row;
    for (genvar j=0; j<16; j=j+1) begin : exp_lane
        localparam integer START=32+8*(j/8)+2*(j%8);
        wire [3:0] row_in=window_index(phase,6'(START%52));
        wire [15:0] delta;
        fp16_addsub shift (.sub(1'b1),.a(scores[row_in][j]),.b(row_max[row_in]),.y(delta));
        assign x_in[16*j +: 16] = (|age_valid[START +: 16]) ? delta : 16'b0;
        if (j==15) begin : latest
            // Direct bypass on t=63+i; this registered value was produced at t=62+i.
            assign exp_row[16*j +: 16]=exp_out[16*j +: 16];
        end else begin : buffered
            reg [15:0] e [0:15];
            wire [3:0] row_out=window_index(phase,6'((START+9)%52));
            always @(posedge clk) if (step && (|age_valid[START+9 +: 16]))
                e[row_out]<=exp_out[16*j +: 16];
            assign exp_row[16*j +: 16]=e[reduce_row];
        end
    end
    wire raw_norm_valid;
    wire [3:0] norm_row;
    wire [15:0] probability [0:15];
    wire norm_valid = step && raw_norm_valid;
    scope_row_acc reduction (.clk,.rst_n,.advance(step),.row_valid(|age_valid[63 +: 16]),
          .row_id(reduce_row),.exp_row,.norm_valid(raw_norm_valid),.norm_row,.probability);
    wire p_dest=q_tag[8'd69+{4'b0,norm_row}];
    for (genvar j=0; j<16; j=j+1) begin : probability_store
        always @(posedge clk) if (norm_valid) p_rows[p_dest][norm_row][16*j +: 16]<=probability[j];
    end

    // The pending diagonal directly reads the registered OS sums. The mesh
    // holds them until accepted, and may produce the next diagonal on that edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wave_valid<=0; wave_diagonal<=0; done<=0; end
        else begin
            done<=out_valid && out_ready && out_last;
            if (output_space) begin
                wave_valid<=step && (|age_valid[135 +: 31]);
                if (step) wave_diagonal<=phase>=31 ? 5'(phase-6'd31) : 5'(phase+6'd21);
            end
        end
    end
    assign out_valid=rst_n && wave_valid;
    assign out_last=out_valid && wave_diagonal==30;
    for (genvar j=0; j<16; j=j+1) begin : output_lanes
        wire [4:0] row_id = wave_diagonal-5'(j);
        assign out_lane_valid[j] = out_valid && row_id<16;
        assign out_data[16*j +: 16] = out_lane_valid[j] ? accum[256*row_id[3:0]+16*j +: 16] : 16'b0;
    end
endmodule
