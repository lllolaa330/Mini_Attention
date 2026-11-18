`timescale 1ns/1ps
module tb_attention;
    parameter integer CASES = 25;
    parameter bit SINGLE_FRAME = 1'b0;
    localparam integer MAX_RUNS = CASES + 40;
    localparam integer MATRIX_BEATS = 16, QK_BEATS = 2*MATRIX_BEATS;
    localparam integer FRAME_BEATS = 3*MATRIX_BEATS, MATRIX_WORDS = 256;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 1, in_valid = 0, out_ready = 0;
    logic [255:0] in_data = 0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
    logic [15:0] inputs [0:CASES*768-1];
    logic [15:0] expected [0:CASES*256-1];
    logic [15:0] expected_p [0:CASES*256-1];
    string input_path, expected_path, probability_path, output_path, wave_path;
    integer fd, cycle = 0, stall_mode = 1, seed_arg = 20261022;
    integer input_bubbles = 0, stalled_outputs = 0, completed = 0, reset_count = 0;
    integer no_stall_cycles = 0, planned = 0, rx_diag = 0;
    integer run_case [0:MAX_RUNS-1], run_mode [0:MAX_RUNS-1];
    integer first_in [0:MAX_RUNS-1], last_in [0:MAX_RUNS-1], first_out [0:MAX_RUNS-1];
    integer tx_slot = -1, tx_beat = 0;
    integer accepted_beats = 0, retired_frames = 0;
    integer input_blocked = 0, overlap_v_qk = 0, overlap_v_sm = 0;
    integer overlap_next_input_output = 0, first_output_during_pv = 0;
    integer long_stall_cycles = 0, queued_reset_count = 0;
    integer reset_event_mask = 0, pv_wait_resets = 0;
    integer pv_steps_before_v_complete = 0, pv_missing_v_cycles = 0, output_input_bubble_stalls = 0;
    logic partial_output_hold = 0, directed_input_pause = 0;

    // Observe what each physical FMA actually accepts, independently of the
    // scheduler's phase counters. The same accumulator performs 16 QK terms
    // followed by 16 PV terms within a frame.
    wire [255:0] pe_mac;
    genvar pr, pc;
    generate
        for (pr=0; pr<16; pr=pr+1) begin : observe_rows
            for (pc=0; pc<16; pc=pc+1) begin : observe_cols
                assign pe_mac[16*pr+pc] =
                    dut.array_core.rows[pr].cols[pc].pe.step &&
                    dut.array_core.rows[pr].cols[pc].pe.a_valid_in &&
                    dut.array_core.rows[pr].cols[pc].pe.b_valid_in;
            end
        end
    endgenerate
    integer mac_count [0:255], score_count [0:15];
    integer epoch_base, qk_slot, pv_slot, issued, returned;
    integer qk_first [0:MAX_RUNS-1], qk_last [0:MAX_RUNS-1];
    integer pv_first [0:MAX_RUNS-1], pv_last [0:MAX_RUNS-1];
    integer issue_at [0:MAX_RUNS-1][0:15], return_at [0:MAX_RUNS-1][0:15];
    integer same_frame_overlap [0:MAX_RUNS-1], previous_frame_overlap [0:MAX_RUNS-1];
    integer bank_reuse_before_retire = 0, cross_stall_cycles = 0;
    integer cross_frame_mac_cycles = 0;
    logic [255:0] first_mac;
    generate
        for (pr=0; pr<16; pr=pr+1) begin : first_rows
            for (pc=0; pc<16; pc=pc+1) begin : first_cols
                assign first_mac[16*pr+pc] = dut.array_core.rows[pr].cols[pc].pe.first_term;
            end
        end
    endgenerate
    integer resident_slot = -1, resident_count = 0;
    logic scoreboard_enabled = 0;
    logic [31:0] rng_in, rng_out;
    logic previous_stall = 0, previous_done = 0, previous_input_stall = 0;
    logic [255:0] held_input;
    logic [255:0] held_data;
    logic [15:0] held_mask;
    logic held_last;

    always @(negedge clk) cycle <= cycle + 1;

    function automatic logic [31:0] next_rng(input logic [31:0] x);
        logic [31:0] y;
        begin
            y = x ^ (x << 13); y = y ^ (y >> 17); y = y ^ (y << 5);
            next_rng = y;
        end
    endfunction

    // Fixtures contain three row-major matrices. The 48 handshakes carry Q
    // rows, K rows, then V columns; lane 0 is always the low 16 bits.
    function automatic logic [255:0] input_beat(input integer cid, input integer n);
        integer k;
        begin
            for (k=0; k<16; k=k+1) begin
                if (n < QK_BEATS)
                    input_beat[16*k+:16] = inputs[cid*768+n*16+k];
                else
                    input_beat[16*k+:16] = inputs[cid*768+2*MATRIX_WORDS+k*16+(n-QK_BEATS)];
            end
        end
    endfunction

    function automatic logic [15:0] diagonal_mask(input integer diagonal);
        integer lane;
        begin
            diagonal_mask = 0;
            for (lane=0; lane<16; lane=lane+1)
                if (diagonal-lane >= 0 && diagonal-lane < 16) diagonal_mask[lane] = 1'b1;
        end
    endfunction

    task automatic start_pipeline_monitor;
        begin
            epoch_base=completed; qk_slot=epoch_base-1; pv_slot=epoch_base-1;
            issued=0; returned=0;
            for (int n=0; n<256; n++) mac_count[n]=0;
            for (int row=0; row<16; row++) score_count[row]=0;
        end
    endtask

    task automatic check_pipeline(input logic retire, output logic qk_mac, output logic pv_mac,
                                  output logic input_frame_softmax);
        integer d, k, accepted, slot, cid, row;
        logic q, p;
        begin
            qk_mac=0; pv_mac=0; input_frame_softmax=0;
            if (dut.qk_step && dut.qk_age==0) begin
                qk_slot=qk_slot+1;
                if (scoreboard_enabled && qk_slot>=planned) $fatal(1,"Unexpected QK start");
                qk_first[qk_slot]=cycle;
                same_frame_overlap[qk_slot]=0;
                previous_frame_overlap[qk_slot]=0;
            end
            if (dut.pv_step && dut.feed_step==0) begin
                pv_slot=pv_slot+1;
                if (scoreboard_enabled && pv_slot>=planned) $fatal(1,"Unexpected PV start");
                pv_first[pv_slot]=cycle;
            end
            // Each physical PE accepts QK(f,0..15), PV(f,0..15), then
            // QK(f+1,0..15). Retirement can lag these local handoffs.
            if (dut.array_step || (|pe_mac)) begin
                for (int n=0; n<256; n++) begin
                    d=n/16+n%16;
                    q=dut.qk_step && integer'(dut.qk_age)>=d && integer'(dut.qk_age)<d+16;
                    p=dut.pv_step && integer'(dut.feed_step)>=d && integer'(dut.feed_step)<d+16;
                    if ((q && p) || pe_mac[n] !== (q || p))
                        $fatal(1,"PE schedule mismatch cycle=%0d PE=%0d q=%b p=%b mac=%b",cycle,n,q,p,pe_mac[n]);
                    if (pe_mac[n]) begin
                        accepted=mac_count[n];
                        k=(q ? integer'(dut.qk_age) : integer'(dut.feed_step))-d;
                        slot=q ? qk_slot : pv_slot;
                        if (epoch_base+accepted/32 != slot || accepted%32 != (q ? k : 16+k) ||
                            first_mac[n] !== (k==0))
                            $fatal(1,"PE term mismatch cycle=%0d PE=%0d slot=%0d k=%0d count=%0d",cycle,n,slot,k,accepted);
                        mac_count[n]=accepted+1;
                        if (q) qk_mac=1;
                        if (p) pv_mac=1;
                    end
                end
            end
            if (qk_mac) qk_last[qk_slot]=cycle;
            if (pv_mac) pv_last[pv_slot]=cycle;
            if (qk_mac && pv_mac) begin
                if (qk_slot==pv_slot) same_frame_overlap[qk_slot]++;
                else begin
                    if (qk_slot!=pv_slot+1) $fatal(1,"Unexpected wave order");
                    previous_frame_overlap[qk_slot]++;
                    if (scoreboard_enabled) cross_frame_mac_cycles++;
                end
            end
            if (scoreboard_enabled && dut.qk_active && dut.pv_active && !dut.wave_slot_available &&
                qk_slot==pv_slot+1 && qk_slot>=epoch_base && !dut.array_step)
                cross_stall_cycles++;

            for (int i=0; i<16; i++) begin
                if (dut.score_valid[i]) begin
                    if (integer'(dut.score_col[i]) != score_count[i]%16)
                        $fatal(1, "Out-of-order score row=%0d col=%0d",i,dut.score_col[i]);
                    if (tx_slot==epoch_base+score_count[i]/16) input_frame_softmax=1;
                    score_count[i]++;
                end
            end
            if (dut.norm_issue) begin
                slot=epoch_base+issued/16; row=issued%16;
                if (integer'(dut.norm_issue_row)!=row || score_count[row]!=(issued/16+1)*16)
                    $fatal(1, "Unexpected normalization issue run=%0d row=%0d",slot,dut.norm_issue_row);
                if (tx_slot==slot) input_frame_softmax=1;
                issue_at[slot][row]=cycle;
                issued++;
            end
            if (dut.prob_valid) begin
                slot=epoch_base+returned/16; row=returned%16;
                if (returned>=issued || integer'(dut.prob_row)!=row || cycle-issue_at[slot][row]!=3)
                    $fatal(1, "Unexpected normalization return run=%0d row=%0d",slot,dut.prob_row);
                if (tx_slot==slot) input_frame_softmax=1;
                return_at[slot][row]=cycle;
                if (scoreboard_enabled) begin
                    if (slot>=planned) $fatal(1,"Unexpected extra probability row");
                    cid=run_case[slot];
                    for (int n=0; n<16; n++)
                        if (dut.probability[n] !== expected_p[cid*256+row*16+n])
                            $fatal(1, "P MISMATCH run=%0d row=%0d col=%0d got=%04h expected=%04h",
                                   slot,row,n,dut.probability[n],expected_p[cid*256+row*16+n]);
                end
                returned++;
            end
            if (retire && scoreboard_enabled) begin
                slot=completed;
                if (returned < 16*(slot-epoch_base+1)) $fatal(1, "Retired before receiving all P rows");
                for (int n=0; n<256; n++)
                    if (mac_count[n] < 32*(slot-epoch_base+1))
                        $fatal(1, "Retired before all PE terms run=%0d PE=%0d",slot,n);
                $display("PIPELINE run=%0d qk_first=%0d qk_last=%0d issue_first=%0d issue_last=%0d return_first=%0d return_last=%0d pv_first=%0d pv_last=%0d overlap=%0d cross=%0d resident=%0d",
                    slot,qk_first[slot],qk_last[slot],issue_at[slot][0],issue_at[slot][15],
                    return_at[slot][0],return_at[slot][15],pv_first[slot],pv_last[slot],
                    same_frame_overlap[slot],previous_frame_overlap[slot],slot==resident_slot);
                if (slot==resident_slot) begin
                    if (last_in[slot]>=qk_first[slot])
                        $fatal(1,"Queued resident frame did not finish input before compute");
                    if (same_frame_overlap[slot]==0 || pv_first[slot]>=qk_last[slot])
                        $fatal(1,"Missing same-frame wave overlap in queued resident frame");
                    resident_count++;
                end
            end
        end
    endtask

    // One independent monitor consumes every accepted vector beat, including
    // when the producer is loading another frame. All checks use pre-NBA data.
    always @(posedge clk) begin : monitor
        integer lane, idx, slot, cid, elapsed;
        logic [15:0] lane_word;
        logic last_accepted;
        logic missing_v_wait, qk_mac, pv_mac, holding_corner, input_frame_softmax;
        logic [15:0] held_corner;
        logic [5:0] held_feed_step;
        if (cycle > (CASES+40)*100000)
            $fatal(1, "WATCHDOG cycle=%0d", cycle);
        last_accepted = rst_n && out_valid && out_ready && out_last;
        missing_v_wait = rst_n && dut.pv_active && dut.feed_step > 0 && !dut.v_ready;
        holding_corner = rst_n && !dut.array_core.rows[0].cols[0].pe.step;
        held_corner = dut.array_core.rows[0].cols[0].pe.acc;
        held_feed_step = dut.feed_step;
        if (!rst_n) begin
            previous_stall = 0; previous_done = 0; previous_input_stall = 0;
            accepted_beats = 0; retired_frames = 0; rx_diag = 0;
            start_pipeline_monitor();
        end else begin
            if ((^{in_ready, out_valid, out_last, out_lane_valid, busy, done}) === 1'bx)
                $fatal(1, "X/Z on control outputs at cycle %0d", cycle);
            if (previous_input_stall && (!in_valid || in_data !== held_input))
                $fatal(1, "Input beat changed while stalled at cycle %0d", cycle);
            if (previous_stall && (!out_valid || out_data !== held_data ||
                                  out_lane_valid !== held_mask || out_last !== held_last))
                $fatal(1, "Output vector changed while stalled at cycle %0d", cycle);
            if (!dut.wave_slot_available && dut.array_step)
                $fatal(1,"Array moved while a live output diagonal was blocked at cycle %0d",cycle);
            if (out_last && !out_valid) $fatal(1, "out_last without out_valid");
            if (done && previous_done) $fatal(1, "done longer than one cycle");
            if (out_valid && !busy) $fatal(1, "Output valid without busy");
            check_pipeline(last_accepted, qk_mac, pv_mac, input_frame_softmax);
            // After feed step 30 the input bank may already hold a newer frame.
            if (scoreboard_enabled && dut.pv_step && dut.feed_step <= 30 && dut.v_cols_ready < 16 &&
                !(in_valid && in_ready && dut.write_bank == dut.pv_bank && integer'(dut.load_count) == FRAME_BEATS-1))
                pv_steps_before_v_complete = pv_steps_before_v_complete + 1;
            // Count starvation independently of output backpressure. The same
            // compute bank supplies both v_cols_ready and the current PV step.
            if (scoreboard_enabled && missing_v_wait && dut.wave_slot_available && dut.v_cols_ready < 16)
                pv_missing_v_cycles = pv_missing_v_cycles + 1;
            if (directed_input_pause && !in_valid && out_valid && !out_ready)
                output_input_bubble_stalls = output_input_bubble_stalls + 1;
            // Check both QK edges against row-major fixtures, including cases
            // where a later input frame is already occupying the other bank.
            if (scoreboard_enabled && dut.qk_step) begin
                cid = run_case[qk_slot];
                for (lane=0; lane<16; lane=lane+1) begin
                    idx = integer'(dut.qk_age)-lane;
                    if (idx>=0 && idx<16) begin
                        if (dut.a_edge[lane] !== inputs[cid*768+16*lane+idx])
                            $fatal(1, "Q row skew mismatch run=%0d row=%0d k=%0d", qk_slot,lane,idx);
                        if (dut.b_edge[lane] !== inputs[cid*768+MATRIX_WORDS+16*lane+idx])
                            $fatal(1, "K row skew mismatch run=%0d row=%0d k=%0d", qk_slot,lane,idx);
                    end
                end
            end
            // Compare each physical V column-head read with the fixture.
            if (scoreboard_enabled && dut.pv_step) begin
                cid = run_case[pv_slot];
                for (lane=0; lane<16; lane=lane+1) begin
                    idx = integer'(dut.feed_step)-lane;
                    if (idx>=0 && idx<16 &&
                        dut.b_edge[lane] !== inputs[cid*768+2*MATRIX_WORDS+16*idx+lane])
                        $fatal(1, "V column skew mismatch run=%0d k=%0d j=%0d", pv_slot,idx,lane);
                end
            end
            if (in_valid && in_ready) begin
                if (integer'(dut.load_count) != accepted_beats % FRAME_BEATS)
                    $fatal(1, "Frame input beat counter mismatch at cycle %0d", cycle);
                if (scoreboard_enabled && accepted_beats%FRAME_BEATS==0 &&
                    accepted_beats/FRAME_BEATS >= retired_frames+2)
                    bank_reuse_before_retire++;
                if (scoreboard_enabled && tx_beat==FRAME_BEATS-1) last_in[tx_slot]=cycle;
                accepted_beats = accepted_beats + 1;
                if (scoreboard_enabled && tx_slot == qk_slot && tx_beat >= QK_BEATS && qk_mac)
                    overlap_v_qk = overlap_v_qk + 1;
                if (scoreboard_enabled && tx_beat >= QK_BEATS && input_frame_softmax)
                    overlap_v_sm = overlap_v_sm + 1;
                if (scoreboard_enabled && out_valid && out_ready && tx_slot > completed)
                    overlap_next_input_output = overlap_next_input_output + 1;
            end
            if (in_valid && !in_ready) input_blocked = input_blocked + 1;
            if (out_valid) begin
                for (lane=0; lane<16; lane=lane+1) begin
                    lane_word = out_data[16*lane+:16];
                    if (out_lane_valid[lane] && (((^lane_word) === 1'bx) || lane_word[14:10] == 31))
                        $fatal(1, "Non-finite/unknown output lane=%0d", lane);
                end
                if (!out_ready) stalled_outputs = stalled_outputs + 1;
            end
            if (last_accepted) retired_frames = retired_frames + 1;
            if (scoreboard_enabled && out_valid && out_ready) begin
                slot = completed;
                if (slot >= planned) $fatal(1, "Unexpected extra output frame");
                cid = run_case[slot];
                if (out_lane_valid !== diagonal_mask(rx_diag))
                    $fatal(1, "MASK MISMATCH run=%0d diagonal=%0d got=%04h expected=%04h",
                           slot, rx_diag, out_lane_valid, diagonal_mask(rx_diag));
                if (out_last !== (rx_diag == 30)) $fatal(1, "Wrong out_last diagonal=%0d", rx_diag);
                if (rx_diag == 0) begin
                    if (first_in[slot] < 0) $fatal(1, "Output before first input");
                    first_out[slot] = cycle;
                    if (dut.pv_active) first_output_during_pv = first_output_during_pv + 1;
                end
                for (lane=0; lane<16; lane=lane+1) begin
                    if (out_lane_valid[lane]) begin
                        idx = (rx_diag-lane)*16+lane;
                        lane_word = out_data[16*lane+:16];
                        if (lane_word !== expected[cid*256+idx])
                            $fatal(1, "BIT MISMATCH run=%0d case=%0d row=%0d col=%0d got=%04h expected=%04h",
                                   slot, cid, idx/16, idx%16, lane_word, expected[cid*256+idx]);
                        $fdisplay(fd, "%0d %0d %0d %04h %0d", slot, cid, idx, lane_word, cycle);
                    end
                end
                if (rx_diag == 30) begin
                    elapsed = cycle-first_in[slot]+1;
                    if (run_mode[slot] == 0 && no_stall_cycles == 0) no_stall_cycles = elapsed;
                    $display("FRAME PASS run=%0d case=%0d cycles=%0d mode=%0d first_in=%0d first_out=%0d last_out=%0d",
                             slot, cid, elapsed, run_mode[slot], first_in[slot], first_out[slot], cycle);
                    completed = completed+1;
                    rx_diag = 0;
                end else rx_diag = rx_diag+1;
            end
            previous_input_stall = in_valid && !in_ready;
            held_input = in_data;
            previous_stall = out_valid && !out_ready;
            held_data = out_data; held_mask = out_lane_valid; held_last = out_last;
            previous_done = done;
        end
        #1;
        if (rst_n) begin
            if (missing_v_wait && dut.feed_step !== held_feed_step)
                $fatal(1, "PV advanced without its required V data");
            if (holding_corner && dut.array_core.rows[0].cols[0].pe.acc !== held_corner)
                $fatal(1, "OS accumulator changed while its PE was held");
            if (done !== last_accepted) $fatal(1, "done must follow exactly the final accepted vector beat");
            if (accepted_beats > retired_frames*FRAME_BEATS && !busy)
                $fatal(1, "busy dropped with accepted input still in flight");
        end
    end

    task automatic reset_dut;
        begin
            #2; rst_n = 0; in_valid = 0; out_ready = 0;
            #1;
            if (out_valid !== 0 || in_ready !== 0 || busy !== 0 || done !== 0)
                $fatal(1, "Asynchronous reset did not suppress interface");
            repeat (2) @(posedge clk);
            @(negedge clk); rst_n = 1;
            #1;
            if (in_ready !== 1 || out_valid !== 0 || busy !== 0 || done !== 0)
                $fatal(1, "Reset recovery failed");
            reset_count = reset_count+1;
            tx_slot = -1;
        end
    endtask

    // Do not insert a turnaround cycle at the frame boundary: the caller can
    // immediately start the next frame on the next falling edge.
    task automatic send_beats(input integer cid, input integer start_beat, input integer beats,
                              input integer mode, input integer slot);
        integer n, gap, j, timeout;
        logic accepted;
        begin
            for (n=start_beat; n<start_beat+beats; n=n+1) begin
                rng_in = next_rng(rng_in);
                gap = mode == 0 ? 0 : ((rng_in[2:0] == 0) ? integer'(rng_in[5:3])+1 : 0);
                if (mode != 0 && (n == MATRIX_BEATS-1 || n == MATRIX_BEATS ||
                                  n == QK_BEATS-1 || n == QK_BEATS || n == FRAME_BEATS-1)) gap = 5;
                for (j=0; j<gap; j=j+1) begin
                    @(negedge clk); in_valid = 0; in_data = {16{16'h7e00}};
                    @(posedge clk); #1; input_bubbles = input_bubbles+1;
                end
                @(negedge clk);
                in_valid = 1; in_data = input_beat(cid,n); tx_slot = slot; tx_beat = n;
                accepted = 0; timeout = 0;
                while (!accepted) begin
                    @(posedge clk);
                    accepted = in_ready;
                    if (accepted && n == 0 && slot >= 0) first_in[slot] = cycle;
                    #1; timeout = timeout+1;
                    if (timeout > 100000) $fatal(1, "Input timeout case=%0d word=%0d", cid, n);
                end
            end
        end
    endtask

    task automatic send_frame(input integer cid, input integer beats, input integer mode, input integer slot);
        begin send_beats(cid,0,beats,mode,slot); end
    endtask

    task automatic stop_input;
        begin
            @(negedge clk); in_valid = 0; in_data = {16{16'h7e00}}; tx_slot = -1;
        end
    endtask

    task automatic drive_receiver(input integer base, input integer count, input logic stress);
        integer slot, observed_slot, stall_first, stall_middle, stall_last, long_hold;
        begin
            observed_slot = -1; stall_first = 0; stall_middle = 0; stall_last = 0; long_hold = 0;
            while (completed < base+count) begin
                @(negedge clk);
                slot = completed;
                if (slot != observed_slot) begin
                    observed_slot = slot; stall_first = 0; stall_middle = 0; stall_last = 0;
                end
                rng_out = next_rng(rng_out);
                // The queued resident frame has an always-ready sink; the preceding
                // frame already exercises pressure while both slots are occupied.
                out_ready = (slot < base+count && slot != resident_slot && run_mode[slot] != 0)
                    ? (rng_out[2:0] != 0) : 1'b1;
                if (slot < base+count && slot != resident_slot && run_mode[slot] != 0 && out_valid) begin
                    if (partial_output_hold && slot == base && rx_diag == 0) begin
                        out_ready = 0;
                    end else if (stress != 0 && slot == base && rx_diag == 0 && long_hold < 2500) begin
                        out_ready = 0; long_hold = long_hold+1; long_stall_cycles = long_stall_cycles+1;
                    end else if (rx_diag == 0 && stall_first < 25) begin
                        out_ready = 0; stall_first = stall_first+1;
                    end else if (rx_diag == 15 && stall_middle < 25) begin
                        out_ready = 0; stall_middle = stall_middle+1;
                    end else if (rx_diag == 30 && stall_last < 25) begin
                        out_ready = 0; stall_last = stall_last+1;
                    end
                end
            end
            @(negedge clk); out_ready = 1;
        end
    endtask

    // kind 0=main, 1=long-backpressure stress, 2=one reset recovery frame.
    task automatic run_batch(input integer count, input integer kind, input integer recovery_case);
        integer base, n;
        begin
            base = completed;
            for (n=0; n<count; n=n+1) begin
                if (kind == 0) begin
                    run_case[base+n] = n;
                    run_mode[base+n] = SINGLE_FRAME ? stall_mode : (n < 4 ? 0 : stall_mode);
                end else begin
                    run_case[base+n] = kind == 1 ? (9+n)%CASES : recovery_case;
                    run_mode[base+n] = 1;
                end
                first_in[base+n] = -1; first_out[base+n] = -1;
            end
            planned = base+count; scoreboard_enabled = 1;
            if (kind == 0) $display("BATCH START first_run=%0d count=%0d kind=main", base, count);
            else if (kind == 1) $display("BATCH START first_run=%0d count=%0d kind=stress", base, count);
            else $display("BATCH START first_run=%0d count=%0d kind=recovery", base, count);
            fork
                begin : producer
                    integer slot;
                    for (slot=base; slot<base+count; slot=slot+1)
                        send_frame(run_case[slot], FRAME_BEATS, run_mode[slot], slot);
                    stop_input();
                end
                drive_receiver(base,count,kind == 1);
            join
            if (completed != planned) $fatal(1, "Incomplete batch");
            scoreboard_enabled = 0;
        end
    endtask

    // Stream a disposable frame until the named operation is actually active.
    // This catches one-cycle events while V is still arriving at the input.
    function automatic logic at_reset_event(input integer event_id);
        case (event_id)
            0: at_reset_event = dut.load_count==7; // partially loaded Q
            1: at_reset_event = out_valid && dut.qk_step && dut.pv_step && dut.qk_bank!=dut.pv_bank;
            2: at_reset_event = pe_mac[0] && mac_count[0]%32==5;
            3: at_reset_event = dut.score_valid[0] && dut.score_col[0]==5;
            4: at_reset_event = dut.norm_issue && dut.norm_issue_row==3;
            5: at_reset_event = dut.prob_valid && dut.prob_row==3;
            6: at_reset_event = pe_mac[0] && mac_count[0]%32==19;
            7: at_reset_event = out_valid && out_last && !out_ready;
            default: at_reset_event = 0;
        endcase
    endfunction

    task automatic abort_at_event(input integer event_id);
        integer n, timeout;
        logic accepted;
        begin
            scoreboard_enabled=0; out_ready=0; n=0; timeout=0;
            @(negedge clk);
            while (!at_reset_event(event_id)) begin
                in_valid = n < ((event_id==1) ? 2*FRAME_BEATS : FRAME_BEATS);
                if (in_valid) in_data=input_beat((2+n/FRAME_BEATS)%CASES,n%FRAME_BEATS);
                // Release earlier diagonals, then hold the pending frame tail.
                out_ready = event_id==1 || (event_id==7 && !out_last);
                @(posedge clk); accepted=in_valid && in_ready;
                if (accepted) n=n+1;
                @(negedge clk); timeout=timeout+1;
                if (timeout>5000) $fatal(1, "Reset event unreachable id=%0d", event_id);
            end
            reset_event_mask=reset_event_mask | (1 << event_id);
            reset_dut();
            $display("RESET PASS event=%0d", event_id);
            run_batch(1,2,(event_id+7)%CASES);
        end
    endtask

    task automatic wait_pv_missing_v;
        integer timeout;
        begin
            timeout = 0;
            while (!(dut.pv_active && !dut.v_ready && dut.feed_step == 8 &&
                     dut.v_cols_ready == 8 && dut.wave_slot_available)) begin
                @(negedge clk); timeout = timeout+1;
                if (timeout > 100000) $fatal(1, "PV did not wait after consuming partial V");
            end
        end
    endtask

    task automatic abort_pv_missing_v;
        begin
            scoreboard_enabled = 0; out_ready = 0;
            send_frame(2%CASES,QK_BEATS+8,0,-1); stop_input();
            wait_pv_missing_v();
            repeat (11) @(negedge clk);
            if (!dut.pv_active || dut.v_ready || dut.feed_step != 8 || dut.v_cols_ready != 8)
                $fatal(1, "Partial PV starvation reset point drifted");
            pv_wait_resets = pv_wait_resets+1;
            reset_dut();
            $display("PV WAIT RESET PASS");
            run_batch(1,2,17%CASES);
        end
    endtask

    task automatic run_partial_v_batch;
        integer base, n, timeout;
        begin
            base = completed;
            for (n=0; n<2; n=n+1) begin
                run_case[base+n] = (19+n)%CASES; run_mode[base+n] = 1;
                first_in[base+n] = -1; first_out[base+n] = -1;
            end
            // Keep frame 0 blocked while the public input fills the other slot.
            // Frame 1 will then reach the compute core with resident Q/K/V.
            resident_slot = base+1;
            planned = base+2; scoreboard_enabled = 1; partial_output_hold = 1;
            $display("BATCH START first_run=%0d count=2 kind=partial_v", base);
            fork
                begin
                    // Delay columns 4..7 into the normalization window, then
                    // withhold column 8 until PV has used columns 0..7.
                    send_beats(run_case[base],0,QK_BEATS+4,0,base); stop_input();
                    wait (dut.norm_issue);
                    send_beats(run_case[base],QK_BEATS+4,4,0,base); stop_input();
                    wait_pv_missing_v();
                    repeat (8) @(negedge clk);
                    send_beats(run_case[base],QK_BEATS+8,8,1,base);
                    // Begin the next frame while the first output is held.
                    // Its first 16 handshakes must never be replayed after the
                    // forced simultaneous input bubble and output backpressure.
                    send_beats(run_case[base+1],0,16,0,base+1); stop_input();
                    timeout = 0;
                    while (!out_valid) begin
                        @(negedge clk); timeout = timeout+1;
                        if (timeout > 100000) $fatal(1, "Partial V batch did not produce an output");
                    end
                    directed_input_pause = 1;
                    repeat (12) begin
                        @(negedge clk);
                        @(posedge clk); #1; input_bubbles = input_bubbles+1;
                    end
                    directed_input_pause = 0;
                    send_beats(run_case[base+1],16,FRAME_BEATS-16,1,base+1); stop_input();
                    if (dut.bank_full !== 2'b11) $fatal(1, "Resident frame was not queued through the public input");
                    partial_output_hold = 0;
                end
                drive_receiver(base,2,0);
            join
            if (completed != planned) $fatal(1, "Incomplete partial V batch");
            scoreboard_enabled = 0;
        end
    endtask

    task automatic abort_queued_backpressure;
        integer i;
        begin
            scoreboard_enabled = 0; out_ready = 0;
            send_frame(2%CASES,FRAME_BEATS,0,-1);
            send_frame(3%CASES,FRAME_BEATS,0,-1);
            @(negedge clk); in_valid = 1; in_data = input_beat(4%CASES,0); tx_beat = 0;
            repeat (25) begin
                @(posedge clk);
                if (in_ready) $fatal(1, "Double bank accepted a third frame while first output was blocked");
                if (!out_valid || !busy) $fatal(1, "Expected queued frame and blocked output before reset");
                #1;
            end
            queued_reset_count = queued_reset_count+1;
            reset_dut();
            $display("QUEUED RESET PASS");
            run_batch(1,2,18%CASES);
        end
    endtask

    integer i;
    initial begin
        if (!$value$plusargs("INPUT=%s", input_path)) $fatal(1, "Missing +INPUT");
        if (!$value$plusargs("EXPECTED=%s", expected_path)) $fatal(1, "Missing +EXPECTED");
        if (!$value$plusargs("EXPECTED_P=%s", probability_path)) probability_path="expected_p.hex";
        if (!$value$plusargs("OUTPUT=%s", output_path)) $fatal(1, "Missing +OUTPUT");
        if ($value$plusargs("SEED=%d", seed_arg)) begin end
        if ($value$plusargs("STALLS=%d", stall_mode)) begin end
        rng_in = seed_arg == 0 ? 32'd1 : 32'(seed_arg);
        rng_out = rng_in ^ 32'h6d2b79f5;
        if ($value$plusargs("WAVE=%s", wave_path)) begin
            $dumpfile(wave_path);
            if ($test$plusargs("WAVE_FULL")) $dumpvars(0, tb_attention);
            else begin
                $dumpvars(1, tb_attention);
                $dumpvars(1, tb_attention.dut);
                $dumpvars(1, tb_attention.dut.array_core.rows[0].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[0].cols[1].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[1].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[15].cols[15].pe);
            end
        end
        $readmemh(input_path, inputs); $readmemh(expected_path, expected);
        $readmemh(probability_path, expected_p);
        fd = $fopen(output_path, "w");
        if (fd == 0) $fatal(1, "Cannot open output capture");
        if (SINGLE_FRAME && CASES != 1) $fatal(1, "Single-frame mode requires CASES=1");
        reset_dut();
        run_batch(CASES,0,0);
        if (!SINGLE_FRAME) begin
            if (stall_mode != 0) run_batch(4,1,0);
            for (i=0; i<8; i=i+1) abort_at_event(i);
            abort_pv_missing_v();
            abort_queued_backpressure();
            run_partial_v_batch();
        end
        @(negedge clk); out_ready = 1; in_valid = 0;
        repeat (20) begin
            @(posedge clk); #1;
            if (out_valid || done || busy) $fatal(1, "Extra output or activity after task completion");
        end
        if (SINGLE_FRAME && (completed != 1 || reset_count != 1)) $fatal(1, "Single-frame count mismatch");
        if (!SINGLE_FRAME) begin
            if (reset_count!=11 || reset_event_mask!=255 || pv_wait_resets!=1)
                $fatal(1, "Reset/recovery coverage missing");
            if (resident_count!=1) $fatal(1, "Missing resident frame checks");
            if (input_bubbles == 0 || stalled_outputs == 0 || input_blocked == 0 || queued_reset_count != 1)
                $fatal(1, "Protocol coverage missing");
            if (overlap_v_qk == 0 || overlap_v_sm == 0 || first_output_during_pv == 0)
                $fatal(1, "Input/compute/output overlap not observed");
            if (CASES >= 2 && overlap_next_input_output == 0) $fatal(1, "Next-frame input did not overlap output");
            if (stall_mode != 0 && long_stall_cycles != 2500) $fatal(1, "Long backpressure coverage missing");
            if (pv_steps_before_v_complete == 0 || pv_missing_v_cycles == 0 || output_input_bubble_stalls < 12)
                $fatal(1, "Partial V execution/starvation or simultaneous bubble/backpressure coverage missing");
        end
        $display("COVERAGE frames=%0d resets=%0d input_bubbles=%0d output_stall_cycles=%0d no_stall_cycles=%0d",
                 completed, reset_count, input_bubbles, stalled_outputs, no_stall_cycles);
        $display("STREAM_COVERAGE input_blocked=%0d overlap_v_qk=%0d overlap_v_sm=%0d next_input_output=%0d first_output_pv=%0d long_stall_cycles=%0d queued_resets=%0d reset_event_mask=%0d resident_count=%0d",
                 input_blocked, overlap_v_qk, overlap_v_sm, overlap_next_input_output, first_output_during_pv,
                 long_stall_cycles, queued_reset_count, reset_event_mask, resident_count);
        $display("CROSS_COVERAGE cross_frame_mac_cycles=%0d cross_stall_cycles=%0d bank_reuse_before_retire=%0d",
                 cross_frame_mac_cycles,cross_stall_cycles,bank_reuse_before_retire);
        $display("V_COVERAGE pv_steps_before_v_complete=%0d pv_missing_v_cycles=%0d pv_wait_resets=%0d output_input_bubble_stalls=%0d",
                 pv_steps_before_v_complete, pv_missing_v_cycles, pv_wait_resets, output_input_bubble_stalls);
        $display("TB PASS"); $fclose(fd); $finish;
    end
endmodule
