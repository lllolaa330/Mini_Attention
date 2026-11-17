`timescale 1ns/1ps
module tb_attention;
    parameter integer CASES = 25;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 1, in_valid = 0, out_ready = 0;
    logic [15:0] in_data = 0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [15:0] out_data;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
    logic [15:0] inputs [0:CASES*768-1];
    logic [15:0] expected [0:CASES*256-1];
    string input_path, expected_path, output_path, wave_path;
    integer fd, cycle = 0, run_id = 0, stall_mode = 1;
    integer seed_arg = 20261022, first_cycle;
    integer input_bubbles = 0, stalled_outputs = 0, completed = 0, reset_count = 0;
    integer no_stall_cycles = 0;
    logic [31:0] rng;
    logic previous_stall = 0, previous_done = 0;
    logic [15:0] held_data;
    logic held_last;

    // Count on the opposite edge, so all posedge consumers see one stable value.
    // This removes scheduling-order dependence from measured task latency.
    always @(negedge clk) cycle <= cycle + 1;

    function automatic logic [31:0] next_rng(input logic [31:0] x);
        logic [31:0] y;
        begin
            y = x ^ (x << 13); y = y ^ (y >> 17); y = y ^ (y << 5);
            next_rng = y;
        end
    endfunction

    // Sample at posedge before NBA; drive at negedge, inspect registered done after NBA.
    always @(posedge clk) begin
        if (cycle > (CASES+16)*100000)
            $fatal(1, "WATCHDOG cycle=%0d state=%0d", cycle, dut.state);
        if (!rst_n) begin
            previous_stall = 0; previous_done = 0;
        end else begin
            // Reduction-X test avoids Icarus 12's $isunknown(concatenation) bug.
            if ((^{in_ready, out_valid, out_last, busy, done}) === 1'bx)
                $fatal(1, "X/Z on control outputs at cycle %0d controls=%b", cycle, {in_ready, out_valid, out_last, busy, done});
            if (previous_stall && (!out_valid || out_data !== held_data || out_last !== held_last))
                $fatal(1, "Output changed while stalled at cycle %0d", cycle);
            if (out_valid && (((^out_data) === 1'bx) || out_data[14:10] == 31))
                $fatal(1, "Non-finite/unknown output at cycle %0d", cycle);
            if (out_valid && (!busy || in_ready))
                $fatal(1, "Invalid busy/in_ready during output");
            if (out_last && !out_valid) $fatal(1, "out_last without out_valid");
            if (done && previous_done) $fatal(1, "done longer than one cycle");
            if (dut.state != 0 && in_ready) $fatal(1, "Input accepted during computation");
            if (out_valid && !out_ready) stalled_outputs = stalled_outputs + 1;
            previous_stall = out_valid && !out_ready;
            held_data = out_data; held_last = out_last; previous_done = done;
        end
    end

    task automatic reset_dut;
        begin
            #2;
            rst_n = 0; in_valid = 0; out_ready = 0;
            #1;
            if (out_valid !== 0 || in_ready !== 0 || busy !== 0 || done !== 0)
                $fatal(1, "Asynchronous reset did not suppress interface");
            repeat (2) @(posedge clk);
            @(negedge clk); rst_n = 1;
            #1;
            if (in_ready !== 1 || out_valid !== 0 || busy !== 0 || done !== 0)
                $fatal(1, "Reset recovery failed");
            reset_count = reset_count + 1;
        end
    endtask

    task automatic load_frame(input integer case_id, input integer words, input integer mode);
        integer n, gap, j, timeout;
        logic accepted;
        begin
            for (n = 0; n < words; n = n + 1) begin
                rng = next_rng(rng);
                gap = mode == 0 ? 0 : ((rng[2:0] == 0) ? integer'(rng[5:3])+1 : 0);
                // Explicit stalls adjacent to matrix boundaries.
                if (mode != 0 && (n == 255 || n == 256 || n == 511 || n == 512 || n == 767)) gap = 5;
                for (j = 0; j < gap; j = j + 1) begin
                    @(negedge clk); in_valid = 0; in_data = 16'h7e00;
                    @(posedge clk); #1; input_bubbles = input_bubbles + 1;
                end
                @(negedge clk); in_valid = 1; in_data = inputs[case_id*768+n];
                accepted = 0; timeout = 0;
                while (!accepted) begin
                    @(posedge clk);
                    accepted = in_ready;
                    if (accepted && n == 0) first_cycle = cycle;
                    #1;
                    timeout = timeout + 1;
                    if (timeout > 100000) $fatal(1, "Input timeout case=%0d word=%0d", case_id, n);
                end
            end
            @(negedge clk); in_valid = 0; in_data = 16'h7e00;
        end
    endtask

    task automatic receive_frame(input integer case_id, input integer mode);
        integer n, timeout, force_stall, elapsed;
        logic accepted;
        begin
            n = 0; timeout = 0; force_stall = 0;
            while (n < 256) begin
                @(negedge clk);
                rng = next_rng(rng);
                out_ready = mode == 0 ? 1'b1 : (rng[2:0] != 0);
                // Hold first and last output for 25 cycles, including valid onset.
                if (mode != 0 && out_valid && (n == 0 || n == 255) && force_stall < 25) begin
                    out_ready = 0; force_stall = force_stall + 1;
                end
                @(posedge clk);
                accepted = out_valid && out_ready;
                if (accepted) begin
                    if (out_data !== expected[case_id*256+n])
                        $fatal(1, "BIT MISMATCH run=%0d case=%0d row=%0d col=%0d got=%04h expected=%04h state=%0d",
                               run_id, case_id, n/16, n%16, out_data, expected[case_id*256+n], dut.state);
                    if (out_last !== (n == 255)) $fatal(1, "Wrong out_last at index %0d", n);
                    $fdisplay(fd, "%0d %0d %0d %04h %0d", run_id, case_id, n, out_data, cycle);
                    if (n == 0) force_stall = 0;
                    n = n + 1;
                end
                #1;
                if (done !== (accepted && n == 256)) $fatal(1, "Unexpected done pulse index=%0d", n);
                timeout = timeout + 1;
                if (timeout > 100000) $fatal(1, "Output timeout case=%0d index=%0d", case_id, n);
            end
            if (busy !== 0 || in_ready !== 1 || out_valid !== 0)
                $fatal(1, "Last transfer did not return to idle");
            elapsed = cycle - first_cycle + 1;
            if (mode == 0 && no_stall_cycles == 0) no_stall_cycles = elapsed;
            $display("FRAME PASS run=%0d case=%0d cycles=%0d mode=%0d", run_id, case_id, elapsed, mode);
            completed = completed + 1; run_id = run_id + 1;
        end
    endtask

    task automatic run_frame(input integer case_id, input integer mode);
        begin
            out_ready = 0;
            load_frame(case_id, 768, mode);
            receive_frame(case_id, mode);
        end
    endtask

    task automatic abort_at_phase(input integer phase);
        integer timeout;
        begin
            out_ready = 0;
            if (phase == 0) load_frame(2 % CASES, 37, 1);
            else begin
                load_frame(2 % CASES, 768, 0);
                timeout = 0;
                while (integer'(dut.state) != phase) begin
                    @(negedge clk); timeout = timeout + 1;
                    if (timeout > 100000) $fatal(1, "Reset phase unreachable: %0d", phase);
                end
                if (phase == 2 || phase == 6) repeat (13) @(negedge clk);
                if (phase == 7) repeat (31) @(negedge clk);
            end
            if (integer'(dut.state) != phase) $fatal(1, "Reset phase drifted: wanted=%0d actual=%0d", phase, dut.state);
            reset_dut();
            $display("RESET PASS phase=%0d", phase);
            // Different content and input bubbles reveal stale memory/control.
            run_frame((phase+7) % CASES, 1);
        end
    endtask

    task automatic abort_softmax(input integer phase);
        integer timeout;
        begin
            out_ready = 0;
            load_frame(3 % CASES, 768, 0);
            timeout = 0;
            while (!(integer'(dut.state) == 4 && integer'(dut.sm.state) == phase)) begin
                @(negedge clk); timeout = timeout+1;
                if (timeout > 100000) $fatal(1, "Softmax reset phase unreachable: %0d", phase);
            end
            if (phase == 4) repeat (3) @(negedge clk);
            reset_dut();
            $display("SOFTMAX RESET PASS phase=%0d", phase);
            run_frame((phase+11) % CASES, 1);
        end
    endtask

    integer i;
    initial begin
        if (!$value$plusargs("INPUT=%s", input_path)) $fatal(1, "Missing +INPUT");
        if (!$value$plusargs("EXPECTED=%s", expected_path)) $fatal(1, "Missing +EXPECTED");
        if (!$value$plusargs("OUTPUT=%s", output_path)) $fatal(1, "Missing +OUTPUT");
        if ($value$plusargs("SEED=%d", seed_arg)) begin end
        if ($value$plusargs("STALLS=%d", stall_mode)) begin end
        rng = seed_arg == 0 ? 32'd1 : 32'(seed_arg);
        if ($value$plusargs("WAVE=%s", wave_path)) begin
            $dumpfile(wave_path);
            if ($test$plusargs("WAVE_FULL")) begin
                $dumpvars(0, tb_attention);
            end else begin
                // Compact teaching trace: controls and four local PE interfaces.
                // Depth 1 excludes the large combinational HardFloat internals.
                $dumpvars(1, tb_attention);
                $dumpvars(1, tb_attention.dut);
                $dumpvars(1, tb_attention.dut.sm);
                $dumpvars(1, tb_attention.dut.array_core.rows[0].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[0].cols[1].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[1].cols[0].pe);
                $dumpvars(1, tb_attention.dut.array_core.rows[15].cols[15].pe);
            end
        end
        $readmemh(input_path, inputs); $readmemh(expected_path, expected);
        fd = $fopen(output_path, "w");
        if (fd == 0) $fatal(1, "Cannot open output capture");
        reset_dut();
        // First two tasks are back-to-back with no stalls, no inter-frame reset.
        for (i = 0; i < CASES; i = i + 1) run_frame(i, i < 2 ? 0 : stall_mode);
        // One reset in every FSM state, with full post-reset frame validation.
        for (i = 0; i < 8; i = i + 1) abort_at_phase(i);
        for (i = 1; i <= 5; i = i + 1) abort_softmax(i);
        @(negedge clk); out_ready = 1; in_valid = 0;
        repeat (20) begin
            @(posedge clk); #1;
            if (out_valid || done || busy) $fatal(1, "Extra output or activity after task completion");
        end
        if (input_bubbles == 0 || stalled_outputs == 0 || reset_count != 14)
            $fatal(1, "Required protocol coverage not reached");
        $display("COVERAGE frames=%0d resets=%0d input_bubbles=%0d output_stall_cycles=%0d no_stall_cycles=%0d",
                 completed, reset_count, input_bubbles, stalled_outputs, no_stall_cycles);
        $display("TB PASS"); $fclose(fd); $finish;
    end
endmodule
