`timescale 1ns/1ps
module tb_array_ws #(
    parameter integer N = 16,
    parameter bit DIRECT_V = 1'b1
);
    localparam integer ROW_W = (N > 1) ? $clog2(N) : 1;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 1, clear = 0, load_weights = 0, step = 0;
    reg [15:0] a_edge [0:N-1], weight_edge [0:N-1];
    reg [N-1:0] a_valid = 0;
    reg row_load = 0;
    reg [ROW_W-1:0] row_addr = 0;
    reg [15:0] row_data [0:N-1];
    wire [15:0] accum [0:N-1][0:N-1];
    ws_systolic_array #(.N(N), .DIRECT_V(DIRECT_V)) dut (.*);

    // Probe the PE registers to check physical residency even with equal outputs.
    wire [15:0] pe_weight [0:N-1][0:N-1];
    for (genvar k = 0; k < N; k = k+1) begin : probe_rows
        for (genvar j = 0; j < N; j = j+1) begin : probe_cols
            assign pe_weight[k][j] = dut.rows[k].cols[j].pe.weight;
        end
    end

    reg [15:0] mat_a [0:65535], mat_b [0:65535], expected [0:65535];
    reg [15:0] weight_expected [0:N-1][0:N-1];
    string a_path, b_path, e_path;
    integer count, held_cycles = 0, capture_fd, direct_capture_fd;
    integer direct_outputs = 0, direct_step_writes = 0, direct_hold_writes = 0;

    task automatic check_expected_weights;
        for (integer k = 0; k < N; k = k+1)
            for (integer j = 0; j < N; j = j+1)
                if (pe_weight[k][j] !== weight_expected[k][j])
                    $fatal(1, "WS direct row isolation k=%0d col=%0d got=%h expected=%h",
                           k, j, pe_weight[k][j], weight_expected[k][j]);
    endtask

    task automatic set_row(input integer frame, k);
        row_load = 1;
        row_addr = ROW_W'(k);
        for (integer j = 0; j < N; j = j+1) begin
            row_data[j] = mat_b[(frame*N+k)*N+j];
            weight_expected[k][j] = row_data[j];
        end
    endtask

    task automatic direct_write_semantics;
        // All weights were reset by abort_in_flight. The write during clear
        // must survive, while clear suppresses shift and computation.
        clear = 1; load_weights = 1; step = 1;
        row_load = 1; row_addr = 0;
        a_valid = '1;
        for (integer k = 0; k < N; k = k+1) begin
            row_data[k] = 16'h3c00;
            a_edge[k] = 16'h3c00;
            weight_edge[k] = 16'h7e00;
            for (integer j = 0; j < N; j = j+1)
                weight_expected[k][j] = k == 0 ? 16'h3c00 : 16'h0000;
        end
        @(negedge clk);
        check_expected_weights();
        check_outputs(0, -1);
        if (dut.rows[0].cols[0].pe.psum_valid_out !== 1'b0)
            $fatal(1, "WS direct clear did not suppress computation");

        // The FMA on the write edge sees old weight=1. The next FMA sees 2.
        clear = 0; load_weights = 0; a_valid = '0; a_valid[0] = 1;
        for (integer j = 0; j < N; j = j+1) begin
            row_data[j] = 16'h4000;
            weight_expected[0][j] = 16'h4000;
        end
        @(negedge clk);
        check_expected_weights();
        if (dut.rows[0].cols[0].pe.psum_valid_out !== 1'b1 ||
            dut.rows[0].cols[0].pe.psum_out !== 16'h3c00)
            $fatal(1, "WS direct same-edge FMA did not use old weight");
        row_load = 0;
        @(negedge clk);
        if (dut.rows[0].cols[0].pe.psum_out !== 16'h4000)
            $fatal(1, "WS direct next-edge FMA did not use new weight");

        // Reset wins over a simultaneous clear, direct load and compute.
        row_load = 1; clear = 1;
        #2 rst_n = 0;
        #1;
        check_outputs(0, -1);
        check_weights(-1);
        @(negedge clk);
        row_load = 0; clear = 0; step = 0; a_valid = '0; rst_n = 1;
    endtask

    task automatic check_weights(input integer frame);
        reg [15:0] want;
        for (integer k = 0; k < N; k = k+1)
            for (integer j = 0; j < N; j = j+1) begin
                want = frame < 0 ? 16'h0000 : mat_b[(frame*N+k)*N+j];
                if (pe_weight[k][j] !== want)
                    $fatal(1, "WS weight frame=%0d k=%0d col=%0d got=%h expected=%h",
                           frame, k, j, pe_weight[k][j], want);
            end
    endtask

    task automatic check_outputs(input integer frame, last_step);
        reg [15:0] want;
        for (integer i = 0; i < N; i = i+1)
            for (integer j = 0; j < N; j = j+1) begin
                // PE[N-1,j] registers its last FMA at i+N-1+j.
                // The column writer captures that registered result one step later.
                want = last_step >= i+N+j ? expected[(frame*N+i)*N+j] : 16'h0000;
                if (accum[i][j] !== want)
                    $fatal(1, "WS result frame=%0d step=%0d row=%0d col=%0d got=%h expected=%h",
                           frame, last_step, i, j, accum[i][j], want);
            end
    endtask

    task automatic load_b(input integer frame);
        load_weights = 1;
        step = 1;       // Weight loading takes priority over compute.
        a_valid = '1;
        for (integer k = N-1; k >= 0; k = k-1) begin
            for (integer j = 0; j < N; j = j+1) begin
                a_edge[j] = 16'h7e00;
                weight_edge[j] = mat_b[(frame*N+k)*N+j];
            end
            @(negedge clk);
        end
        load_weights = 0;
        for (integer j = 0; j < N; j = j+1) weight_edge[j] = 16'h7e00;
        check_weights(frame);
        check_outputs(frame, -1);
    endtask

    task automatic feed_a(input integer frame, t);
        integer i;
        for (integer k = 0; k < N; k = k+1) begin
            i = t-k;
            a_valid[k] = (i >= 0 && i < N);
            a_edge[k] = a_valid[k] ? mat_a[(frame*N+i)*N+k] : 16'h7e00;
        end
        step = 1;
        @(negedge clk);
    endtask

    task automatic clear_array;
        clear = 1;
        step = 1;
        load_weights = 1;
        @(negedge clk);
        clear = 0;
        load_weights = 0;
        step = 0;
        check_outputs(0, -1);
    endtask

    task automatic abort_in_flight(input bit use_reset);
        // Frame 1 contains nonzero products. Stop after the first write-back
        // while other rows/columns still have real work in flight.
        load_b(1);
        for (integer t = 0; t <= N; t = t+1) feed_a(1, t);
        check_outputs(1, N);
        if (use_reset) begin
            #2 rst_n = 0;
            #1;
            check_outputs(0, -1);
            check_weights(-1);
            @(negedge clk);
            rst_n = 1;
        end else begin
            clear_array();
            check_weights(1);
        end
        a_valid = '0;
        step = 1;
        repeat (2*N) @(negedge clk);
        check_outputs(0, -1);
    endtask

    initial begin
        if (!$value$plusargs("A=%s", a_path) || !$value$plusargs("B=%s", b_path) ||
            !$value$plusargs("EXPECTED=%s", e_path) || !$value$plusargs("COUNT=%d", count))
            $fatal(1, "Missing WS array plusargs");
        if (count < 2 || count*N*N > 65536) $fatal(1, "Bad WS array count");
        $readmemh(a_path, mat_a, 0, count*N*N-1);
        $readmemh(b_path, mat_b, 0, count*N*N-1);
        $readmemh(e_path, expected, 0, count*N*N-1);
        capture_fd = $fopen("actual.hex", "w");
        if (!capture_fd) $fatal(1, "Cannot open WS array capture");
        for (integer j = 0; j < N; j = j+1) row_data[j] = 16'h7e00;
        #2 rst_n = 0;
        @(negedge clk);
        rst_n = 1;
        abort_in_flight(0);
        abort_in_flight(1);
        if (DIRECT_V) direct_write_semantics();
        else begin
            // With the optional path disabled, even asserted poison writes
            // cannot change the original shift-load behavior.
            row_load = 1;
            row_addr = 0;
        end

        for (integer frame = 0; frame < count; frame = frame+1) begin
            clear_array();
            load_b(frame);
            for (integer t = 0; t < 3*N-1; t = t+1) begin
                if ((t%5) == 1) begin
                    step = 0;
                    a_valid = '1;
                    for (integer k = 0; k < N; k = k+1) a_edge[k] = 16'h7e00;
                    repeat (2) @(negedge clk);
                    held_cycles = held_cycles + 2;
                    check_outputs(frame, t-1);
                    check_weights(frame);
                end
                feed_a(frame, t);
                check_outputs(frame, t);
            end
            check_weights(frame);
            a_valid = '0;
            repeat (2*N) @(negedge clk);
            check_outputs(frame, 3*N-2);
            for (integer i = 0; i < N; i = i+1)
                for (integer j = 0; j < N; j = j+1)
                    $fdisplay(capture_fd, "%04h", accum[i][j]);
        end
        $fclose(capture_fd);
        if (DIRECT_V) begin
            direct_capture_fd = $fopen("direct_actual.hex", "w");
            if (!direct_capture_fd) $fatal(1, "Cannot open WS direct capture");
            for (integer frame = 0; frame < count; frame = frame+1) begin
                for (integer k = 0; k < N; k = k+1)
                    for (integer j = 0; j < N; j = j+1)
                        weight_expected[k][j] = pe_weight[k][j];
                // Row 0 is installed during clear. Later rows are installed
                // just before their first useful FMA, while earlier rows run.
                clear = 1; load_weights = 1; step = 1;
                set_row(frame, 0);
                @(negedge clk);
                check_expected_weights();
                check_outputs(frame, -1);
                clear = 0; load_weights = 0; row_load = 0;
                for (integer t = 0; t < 3*N-1; t = t+1) begin
                    if (t < N-1) set_row(frame, t+1);
                    if ((t%5) == 1) begin
                        step = 0; a_valid = '1;
                        for (integer k = 0; k < N; k = k+1) a_edge[k] = 16'h7e00;
                        @(negedge clk);
                        if (row_load) direct_hold_writes = direct_hold_writes + 1;
                        row_load = 0;
                        check_expected_weights();
                        check_outputs(frame, t-1);
                        @(negedge clk);
                        held_cycles = held_cycles + 2;
                        check_expected_weights();
                        check_outputs(frame, t-1);
                    end
                    if (row_load) direct_step_writes = direct_step_writes + 1;
                    feed_a(frame, t);
                    row_load = 0;
                    check_expected_weights();
                    check_outputs(frame, t);
                end
                check_weights(frame);
                a_valid = '0;
                repeat (2*N) @(negedge clk);
                check_outputs(frame, 3*N-2);
                for (integer i = 0; i < N; i = i+1)
                    for (integer j = 0; j < N; j = j+1) begin
                        $fdisplay(direct_capture_fd, "%04h", accum[i][j]);
                        direct_outputs = direct_outputs + 1;
                    end
            end
            $fclose(direct_capture_fd);
        end
        $display("PASS array WS N=%0d K=%0d frames=%0d outputs=%0d direct_outputs=%0d held_cycles=%0d direct_step_writes=%0d direct_hold_writes=%0d timed_writeback/resident/clear/reset/invalid",
                 N, N, count, count*N*N, direct_outputs, held_cycles,
                 direct_step_writes, direct_hold_writes);
        $finish;
    end
    initial begin #100000000; $fatal(1, "WS array watchdog timeout"); end
endmodule
