`timescale 1ns/1ps
module tb_attention;
    parameter integer CASES = 25;
    parameter bit SINGLE_FRAME = 1'b0;
    localparam integer MAX_RUNS = CASES + 40;
    localparam integer QK_BEATS = 512, FRAME_BEATS = QK_BEATS+16;
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
    integer first_in [0:MAX_RUNS-1], first_out [0:MAX_RUNS-1];
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
    integer mac_count [0:255], score_count [0:15], issue_at [0:15], return_at [0:15];
    integer issued, returned, qk_first, qk_last, pv_first, mac_overlap;
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

    // Keep the software fixtures row-major. During V, beat 512+j carries
    // V[0,j] in the low lane through V[15,j] in the high lane.
    function automatic logic [255:0] input_beat(input integer cid, input integer n);
        integer k;
        begin
            if (n < QK_BEATS) begin
                input_beat = {16{16'h7e00}}; // unused Q/K lanes
                input_beat[15:0] = inputs[cid*768+n];
            end else begin
                for (k=0; k<16; k=k+1)
                    input_beat[16*k+:16] = inputs[cid*768+QK_BEATS+k*16+(n-QK_BEATS)];
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
        integer n;
        begin
            issued=0; returned=0; qk_first=-1; qk_last=-1; pv_first=-1; mac_overlap=0;
            for (n=0; n<256; n=n+1) mac_count[n]=0;
            for (n=0; n<16; n=n+1) score_count[n]=0;
        end
    endtask

    task automatic check_pipeline(input logic retire, output logic qk_mac, output logic pv_mac);
        integer n, row, cid;
        begin
            qk_mac=0; pv_mac=0;
            if (dut.array_step) begin
                for (n=0; n<256; n=n+1) begin
                    if (pe_mac[n]) begin
                        if (mac_count[n] < 16) qk_mac=1;
                        else if (mac_count[n] < 32) pv_mac=1;
                        else $fatal(1, "Extra FMA on PE[%0d,%0d]", n/16, n%16);
                        mac_count[n]=mac_count[n]+1;
                    end
                end
            end
            if (qk_mac) begin
                if (qk_first < 0) qk_first=cycle;
                qk_last=cycle;
            end
            if (pv_mac && pv_first < 0) pv_first=cycle;
            if (qk_mac && pv_mac) mac_overlap=mac_overlap+1;

            for (row=0; row<16; row=row+1) begin
                if (dut.score_valid[row]) begin
                    if (score_count[row] >= 16 || integer'(dut.score_col[row]) != score_count[row])
                        $fatal(1, "Duplicate or out-of-order score row=%0d col=%0d", row, dut.score_col[row]);
                    score_count[row]=score_count[row]+1;
                end
            end
            if (dut.norm_issue) begin
                if (issued>=16 || integer'(dut.norm_issue_row)!=issued || score_count[issued]!=16)
                    $fatal(1, "Unexpected normalization issue row=%0d expected=%0d", dut.norm_issue_row, issued);
                issue_at[issued]=cycle; issued=issued+1;
            end
            if (dut.prob_valid) begin
                if (returned>=issued || integer'(dut.prob_row)!=returned)
                    $fatal(1, "Unexpected normalization return row=%0d issued=%0d returned=%0d", dut.prob_row, issued, returned);
                return_at[returned]=cycle;
                if (returned>0 && cycle-issue_at[returned] != return_at[0]-issue_at[0])
                    $fatal(1, "Normalization latency changed at row %0d", returned);
                if (scoreboard_enabled) begin
                    cid=run_case[completed];
                    for (n=0; n<16; n=n+1) begin
                        if (dut.probability[n] !== expected_p[cid*256+returned*16+n])
                            $fatal(1, "P MISMATCH case=%0d row=%0d col=%0d got=%04h expected=%04h",
                                   cid, returned, n, dut.probability[n], expected_p[cid*256+returned*16+n]);
                    end
                end
                returned=returned+1;
            end
            if (retire) begin
                if (issued!=16 || returned!=16) $fatal(1, "Retired frame before 16 normalized rows");
                if (issue_at[15]-issue_at[0]!=15 || return_at[15]-return_at[0]!=15)
                    $fatal(1, "Normalization did not issue and return all 16 rows on consecutive clocks");
                for (n=0; n<256; n=n+1)
                    if (mac_count[n]!=32) $fatal(1, "PE[%0d,%0d] MAC count=%0d", n/16, n%16, mac_count[n]);
                if (scoreboard_enabled) begin
                    $display("PIPELINE run=%0d qk_first=%0d qk_last=%0d issue_first=%0d issue_last=%0d return_first=%0d return_last=%0d pv_first=%0d overlap=%0d resident=%0d",
                        completed, qk_first, qk_last, issue_at[0], issue_at[15], return_at[0], return_at[15],
                        pv_first, mac_overlap, completed==resident_slot);
                    if (completed == resident_slot) begin
                        if (mac_overlap==0 || pv_first>=qk_last)
                            $fatal(1, "No physical QK/PV MAC overlap in resident frame");
                        resident_count=resident_count+1;
                    end
                end
                start_pipeline_monitor();
            end
        end
    endtask

    // One independent monitor consumes every accepted vector beat, including
    // when the producer is loading another frame. All checks use pre-NBA data.
    always @(posedge clk) begin : monitor
        integer lane, idx, slot, cid, elapsed;
        logic [15:0] lane_word;
        logic last_accepted;
        logic missing_v_wait, qk_mac, pv_mac, holding_corner;
        logic [15:0] held_corner;
        logic [5:0] held_feed_step;
        if (cycle > (CASES+40)*100000)
            $fatal(1, "WATCHDOG cycle=%0d state=%0d", cycle, dut.state);
        last_accepted = rst_n && out_valid && out_ready && out_last;
        missing_v_wait = rst_n && dut.state == dut.COMPUTE && dut.feed_step > 0 && !dut.v_ready;
        holding_corner = rst_n && dut.state == dut.COMPUTE && !dut.array_core.rows[0].cols[0].pe.step;
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
            if (out_last && !out_valid) $fatal(1, "out_last without out_valid");
            if (done && previous_done) $fatal(1, "done longer than one cycle");
            if (out_valid && !busy) $fatal(1, "Output valid without busy");
            check_pipeline(last_accepted, qk_mac, pv_mac);
            if (scoreboard_enabled && dut.pv_step && dut.v_cols_ready < 16 &&
                !(in_valid && in_ready && dut.write_bank == dut.compute_bank && dut.load_count == FRAME_BEATS-1))
                pv_steps_before_v_complete = pv_steps_before_v_complete + 1;
            // Count starvation independently of output backpressure. The same
            // compute bank supplies both v_cols_ready and the current PV step.
            if (scoreboard_enabled && missing_v_wait && dut.wave_slot_available && dut.v_cols_ready < 16)
                pv_missing_v_cycles = pv_missing_v_cycles + 1;
            if (directed_input_pause && !in_valid && out_valid && !out_ready)
                output_input_bubble_stalls = output_input_bubble_stalls + 1;
            // Compare the physical column-head read with the independent
            // row-major V fixture before each successful array injection.
            if (scoreboard_enabled && dut.pv_step) begin
                cid = run_case[completed];
                for (lane=0; lane<16; lane=lane+1) begin
                    idx = integer'(dut.feed_step)-lane;
                    if (idx>=0 && idx<16 &&
                        dut.b_edge[lane] !== inputs[cid*768+QK_BEATS+16*idx+lane])
                        $fatal(1, "V column skew mismatch run=%0d k=%0d j=%0d", completed,idx,lane);
                end
            end
            if (in_valid && in_ready) begin
                if (integer'(dut.load_count) != accepted_beats % FRAME_BEATS)
                    $fatal(1, "Frame input beat counter mismatch at cycle %0d", cycle);
                accepted_beats = accepted_beats + 1;
                if (scoreboard_enabled && tx_slot == completed && tx_beat >= 512 && qk_mac)
                    overlap_v_qk = overlap_v_qk + 1;
                if (scoreboard_enabled && tx_slot == completed && tx_beat >= 512 && (|dut.score_valid || dut.norm_issue || dut.prob_valid))
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
                    if (dut.state == dut.COMPUTE) first_output_during_pv = first_output_during_pv + 1;
                end
                for (lane=0; lane<16; lane=lane+1) begin
                    if (out_lane_valid[lane]) begin
                        idx = (rx_diag-lane)*16+lane;
                        lane_word = out_data[16*lane+:16];
                        if (lane_word !== expected[cid*256+idx])
                            $fatal(1, "BIT MISMATCH run=%0d case=%0d row=%0d col=%0d got=%04h expected=%04h state=%0d",
                                   slot, cid, idx/16, idx%16, lane_word, expected[cid*256+idx], dut.state);
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
                if (mode != 0 && (n == 255 || n == 256 || n == 511 || n == 512 || n == FRAME_BEATS-1)) gap = 5;
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
            0: at_reset_event = dut.load_count==37;
            1: at_reset_event = dut.state==dut.CLEAR;
            2: at_reset_event = pe_mac[0] && mac_count[0]==5;
            3: at_reset_event = dut.score_valid[0] && dut.score_col[0]==5;
            4: at_reset_event = dut.norm_issue && dut.norm_issue_row==3;
            5: at_reset_event = dut.prob_valid && dut.prob_row==3;
            6: at_reset_event = pe_mac[0] && mac_count[0]==19;
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
                in_valid = n<FRAME_BEATS;
                if (in_valid) in_data=input_beat(2%CASES,n);
                // Release earlier diagonals, then hold the pending frame tail.
                out_ready = event_id==7 && !out_last;
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
            while (!(dut.state == dut.COMPUTE && !dut.v_ready && dut.feed_step == 8 &&
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
            if (dut.state != dut.COMPUTE || dut.v_ready || dut.feed_step != 8 || dut.v_cols_ready != 8)
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
        $display("V_COVERAGE pv_steps_before_v_complete=%0d pv_missing_v_cycles=%0d pv_wait_resets=%0d output_input_bubble_stalls=%0d",
                 pv_steps_before_v_complete, pv_missing_v_cycles, pv_wait_resets, output_input_bubble_stalls);
        $display("TB PASS"); $fclose(fd); $finish;
    end
endmodule
