`timescale 1ns/1ps
module tb_prob_div;
    reg clk = 0;
    always #5 clk = !clk;
    reg stage1_enable = 0, stage2_enable = 0;
    reg [15:0] a = 0, b = 16'h3c00;
    wire [15:0] y;
    fp16_prob_div dut (.*);

    reg pending = 0;
    reg [15:0] pending_expected, pending_a, pending_b;
    integer checked = 0, consecutive = 0, max_consecutive = 0;
    task automatic drive(input bit accept, input [47:0] word);
        @(negedge clk);
        stage1_enable = accept; stage2_enable = pending;
        a = word[47:32]; b = word[31:16];
        @(posedge clk); #1;
        if (pending) begin
            if (y !== pending_expected)
                $fatal(1, "%h / %h produced %h, expected %h", pending_a, pending_b, y, pending_expected);
            checked = checked+1;
            consecutive = consecutive+1;
            if (consecutive > max_consecutive) max_consecutive = consecutive;
        end else consecutive = 0;
        pending = accept;
        pending_expected = word[15:0];
        pending_a = a; pending_b = b;
    endtask

    integer fd, total, parsed, sent = 0;
    reg [47:0] word;
    initial begin
        if (!$value$plusargs("COUNT=%d",total)) $fatal(1,"Missing vector count");
        fd = $fopen("vectors.hex","r");
        if (!fd) $fatal(1,"Missing test vectors");
        repeat (total) begin
            parsed = $fscanf(fd,"%h",word);
            if (parsed != 1) $fatal(1,"Incomplete test vectors");
            if (sent%97 == 0) drive(0,0);
            drive(1, word);
            sent = sent+1;
        end
        drive(0,0);
        if (checked != total || max_consecutive < 90) $fatal(1,"Missing check/burst coverage");
        $display("PROB DIV PASS cases=%0d consecutive=%0d",checked,max_consecutive);
        $fclose(fd);
        $finish;
    end
endmodule
