`timescale 1ns/1ps
module tb_attention;
    parameter integer CASES = 25;
    parameter bit USE_WS = 1'b0;
    parameter bit SINGLE_FRAME = 1'b0;
    localparam integer MAX_RUNS = CASES + 40;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 1, in_valid = 0, out_ready = 0;
    logic [15:0] in_data = 0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex"), .USE_WS(USE_WS)) dut (.*);
    logic [15:0] inputs [0:CASES*768-1];
    logic [15:0] expected [0:CASES*256-1];
    string input_path, expected_path, output_path, wave_path;
    integer fd, cycle = 0, stall_mode = 1, seed_arg = 20261022;
    integer input_bubbles = 0, stalled_outputs = 0, completed = 0, reset_count = 0;
    integer no_stall_cycles = 0, planned = 0, rx_diag = 0;
    integer run_case [0:MAX_RUNS-1], run_mode [0:MAX_RUNS-1];
    integer first_in [0:MAX_RUNS-1], first_out [0:MAX_RUNS-1];
    integer tx_slot = -1, tx_word = 0;
    integer accepted_words = 0, retired_frames = 0;
    integer input_blocked = 0, overlap_v_qk = 0, overlap_v_sm = 0;
    integer overlap_next_input_output = 0, first_output_during_pv = 0;
    integer long_stall_cycles = 0, queued_reset_count = 0;
    integer top_reset_mask = 0, softmax_reset_mask = 0;
    logic scoreboard_enabled = 0;
    logic [31:0] rng_in, rng_out;
    logic previous_stall = 0, previous_done = 0;
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

    function automatic logic [15:0] diagonal_mask(input integer diagonal);
        integer lane;
        begin
            diagonal_mask = 0;
            for (lane=0; lane<16; lane=lane+1)
                if (diagonal-lane >= 0 && diagonal-lane < 16) diagonal_mask[lane] = 1'b1;
        end
    endfunction

    // One independent monitor consumes every accepted vector beat, including
    // when the producer is loading another frame. All checks use pre-NBA data.
    always @(posedge clk) begin : monitor
        integer lane, idx, slot, cid, elapsed;
        logic [15:0] lane_word;
        logic last_accepted;
        if (cycle > (CASES+40)*100000)
            $fatal(1, "WATCHDOG cycle=%0d state=%0d", cycle, dut.state);
        last_accepted = rst_n && out_valid && out_ready && out_last;
        if (!rst_n) begin
            previous_stall = 0; previous_done = 0;
            accepted_words = 0; retired_frames = 0; rx_diag = 0;
        end else begin
            if ((^{in_ready, out_valid, out_last, out_lane_valid, busy, done}) === 1'bx)
                $fatal(1, "X/Z on control outputs at cycle %0d", cycle);
            if (previous_stall && (!out_valid || out_data !== held_data ||
                                  out_lane_valid !== held_mask || out_last !== held_last))
                $fatal(1, "Output vector changed while stalled at cycle %0d", cycle);
            if (out_last && !out_valid) $fatal(1, "out_last without out_valid");
            if (done && previous_done) $fatal(1, "done longer than one cycle");
            if (out_valid && !busy) $fatal(1, "Output valid without busy");
            if (in_valid && in_ready) begin
                accepted_words = accepted_words + 1;
                if (scoreboard_enabled && tx_slot == completed && tx_word >= 512 && dut.state == 2)
                    overlap_v_qk = overlap_v_qk + 1;
                if (scoreboard_enabled && tx_slot == completed && tx_word >= 512 && (dut.state == 3 || dut.state == 4))
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
                    if (dut.state == 6) first_output_during_pv = first_output_during_pv + 1;
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
            previous_stall = out_valid && !out_ready;
            held_data = out_data; held_mask = out_lane_valid; held_last = out_last;
            previous_done = done;
        end
        #1;
        if (rst_n) begin
            if (done !== last_accepted) $fatal(1, "done must follow exactly the final accepted vector beat");
            if (accepted_words > retired_frames*768 && !busy)
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
    task automatic send_frame(input integer cid, input integer words, input integer mode, input integer slot);
        integer n, gap, j, timeout;
        logic accepted;
        begin
            for (n=0; n<words; n=n+1) begin
                rng_in = next_rng(rng_in);
                gap = mode == 0 ? 0 : ((rng_in[2:0] == 0) ? integer'(rng_in[5:3])+1 : 0);
                if (mode != 0 && (n == 255 || n == 256 || n == 511 || n == 512 || n == 767)) gap = 5;
                for (j=0; j<gap; j=j+1) begin
                    @(negedge clk); in_valid = 0; in_data = 16'h7e00;
                    @(posedge clk); #1; input_bubbles = input_bubbles+1;
                end
                @(negedge clk);
                in_valid = 1; in_data = inputs[cid*768+n]; tx_slot = slot; tx_word = n;
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

    task automatic stop_input;
        begin
            @(negedge clk); in_valid = 0; in_data = 16'h7e00; tx_slot = -1;
        end
    endtask

    task automatic drive_receiver(input integer base, input integer count, input integer stress);
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
                out_ready = (slot < base+count && run_mode[slot] != 0) ? (rng_out[2:0] != 0) : 1'b1;
                if (slot < base+count && run_mode[slot] != 0 && out_valid) begin
                    if (stress != 0 && slot == base && rx_diag == 0 && long_hold < 2500) begin
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
                        send_frame(run_case[slot], 768, run_mode[slot], slot);
                    stop_input();
                end
                drive_receiver(base,count,kind == 1);
            join
            if (completed != planned) $fatal(1, "Incomplete batch");
            scoreboard_enabled = 0;
        end
    endtask

    task automatic wait_top_phase(input integer phase);
        integer timeout;
        begin
            timeout = 0;
            while (integer'(dut.state) != phase) begin
                @(negedge clk); timeout = timeout+1;
                if (timeout > 100000) $fatal(1, "Reset phase unreachable: %0d", phase);
            end
        end
    endtask

    task automatic abort_at_phase(input integer phase);
        integer beat;
        logic accepted;
        begin
            scoreboard_enabled = 0; out_ready = 0;
            if (phase == 0) begin
                send_frame(2%CASES,37,1,-1); stop_input();
            end else if (phase == 7) begin
                // Drain 30 groups so the array can finish even with a tiny skid
                // buffer, then keep the final group under backpressure.
                send_frame(2%CASES,768,0,-1); stop_input();
                beat = 0;
                while (beat < 30) begin
                    @(negedge clk); out_ready = 1;
                    @(posedge clk); accepted = out_valid && out_ready;
                    if (accepted) beat = beat+1;
                    #1;
                end
                @(negedge clk); out_ready = 0;
                wait_top_phase(7);
                repeat (25) @(negedge clk);
            end else begin
                // QK/Softmax now run concurrently with V loading. Suppress V
                // to reliably stop in the early states and WAIT_V.
                if (phase == 1 || phase == 2 || phase == 3 || phase == 4 || phase == 8 || phase == 10)
                    send_frame(2%CASES,512,0,-1);
                else send_frame(2%CASES,768,0,-1);
                stop_input();
                wait_top_phase(phase);
                if (phase == 2 || phase == 6) repeat (13) @(negedge clk);
                if (phase == 8 || phase == 9) repeat (7) @(negedge clk);
                if (phase == 10) repeat (11) @(negedge clk);
            end
            if (integer'(dut.state) != phase) $fatal(1, "Reset phase drifted: wanted=%0d actual=%0d", phase, dut.state);
            top_reset_mask = top_reset_mask | (1 << phase);
            reset_dut();
            $display("RESET PASS phase=%0d", phase);
            run_batch(1,2,(phase+7)%CASES);
        end
    endtask

    task automatic abort_softmax(input integer phase);
        integer timeout;
        begin
            scoreboard_enabled = 0; out_ready = 0;
            send_frame(3%CASES,512,0,-1); stop_input();
            timeout = 0;
            while (!(dut.state == dut.SM_WAIT && integer'(dut.parallel_softmax[0].sm.state) == phase)) begin
                @(negedge clk); timeout = timeout+1;
                if (timeout > 100000) $fatal(1, "Softmax reset phase unreachable: %0d", phase);
            end
            if (phase == integer'(dut.parallel_softmax[0].sm.DIV_WAIT)) repeat (3) @(negedge clk);
            if (integer'(dut.parallel_softmax[0].sm.state) != phase)
                $fatal(1, "Softmax reset phase drifted: wanted=%0d actual=%0d", phase, dut.parallel_softmax[0].sm.state);
            softmax_reset_mask = softmax_reset_mask | (1 << phase);
            reset_dut();
            $display("SOFTMAX RESET PASS phase=%0d", phase);
            run_batch(1,2,(phase+11)%CASES);
        end
    endtask

    task automatic abort_queued_backpressure;
        integer i;
        begin
            scoreboard_enabled = 0; out_ready = 0;
            send_frame(2%CASES,768,0,-1);
            send_frame(3%CASES,768,0,-1);
            @(negedge clk); in_valid = 1; in_data = inputs[4%CASES*768]; tx_word = 0;
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

    integer i, expected_top_mask;
    initial begin
        if (!$value$plusargs("INPUT=%s", input_path)) $fatal(1, "Missing +INPUT");
        if (!$value$plusargs("EXPECTED=%s", expected_path)) $fatal(1, "Missing +EXPECTED");
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
                $dumpvars(1, tb_attention.dut.parallel_softmax[0].sm);
                $dumpvars(1, tb_attention.dut.array_impl.array_core.rows[0].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_impl.array_core.rows[0].cols[1].pe);
                $dumpvars(1, tb_attention.dut.array_impl.array_core.rows[1].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_impl.array_core.rows[15].cols[15].pe);
            end
        end
        $readmemh(input_path, inputs); $readmemh(expected_path, expected);
        fd = $fopen(output_path, "w");
        if (fd == 0) $fatal(1, "Cannot open output capture");
        if (SINGLE_FRAME && CASES != 1) $fatal(1, "Single-frame mode requires CASES=1");
        reset_dut();
        run_batch(CASES,0,0);
        if (!SINGLE_FRAME) begin
            if (stall_mode != 0) run_batch(4,1,0);
            for (i=0; i<8; i=i+1) abort_at_phase(i);
            for (i=1; i<=6; i=i+1) abort_softmax(i);
            if (USE_WS) begin abort_at_phase(8); abort_at_phase(9); end
            abort_at_phase(10);
            abort_queued_backpressure();
        end
        @(negedge clk); out_ready = 1; in_valid = 0;
        repeat (20) begin
            @(posedge clk); #1;
            if (out_valid || done || busy) $fatal(1, "Extra output or activity after task completion");
        end
        if (SINGLE_FRAME && (completed != 1 || reset_count != 1)) $fatal(1, "Single-frame count mismatch");
        if (!SINGLE_FRAME) begin
            expected_top_mask = USE_WS ? 2047 : 1279; // bits 0..7,10 and WS8,9
            if (reset_count != (USE_WS ? 19 : 17) || top_reset_mask != expected_top_mask || softmax_reset_mask != 126)
                $fatal(1, "Reset coverage missing");
            if (input_bubbles == 0 || stalled_outputs == 0 || input_blocked == 0 || queued_reset_count != 1)
                $fatal(1, "Protocol coverage missing");
            if (overlap_v_qk == 0 || overlap_v_sm == 0 || first_output_during_pv == 0)
                $fatal(1, "Input/compute/output overlap not observed");
            if (CASES >= 2 && overlap_next_input_output == 0) $fatal(1, "Next-frame input did not overlap output");
            if (stall_mode != 0 && long_stall_cycles != 2500) $fatal(1, "Long backpressure coverage missing");
        end
        $display("COVERAGE frames=%0d resets=%0d input_bubbles=%0d output_stall_cycles=%0d no_stall_cycles=%0d",
                 completed, reset_count, input_bubbles, stalled_outputs, no_stall_cycles);
        $display("STREAM_COVERAGE input_blocked=%0d overlap_v_qk=%0d overlap_v_sm=%0d next_input_output=%0d first_output_pv=%0d long_stall_cycles=%0d queued_resets=%0d top_reset_mask=%0d softmax_reset_mask=%0d",
                 input_blocked, overlap_v_qk, overlap_v_sm, overlap_next_input_output, first_output_during_pv,
                 long_stall_cycles, queued_reset_count, top_reset_mask, softmax_reset_mask);
        $display("TB PASS"); $fclose(fd); $finish;
    end
endmodule
