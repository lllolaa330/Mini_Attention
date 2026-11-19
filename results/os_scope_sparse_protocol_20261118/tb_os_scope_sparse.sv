`timescale 1ns/1ps
// OS-SCOPE directed liveness check, with long gaps and restart after drain.
module tb_os_scope_sparse;
    localparam CASES=23, FRAMES=9;
    reg clk=0, rst_n=0, in_valid=0, out_ready=0;
    always #5 clk=~clk;
    reg [255:0] in_data=0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    localparam IN_BEATS=48, OUT_BEATS=31;
    os_scope_attention_fp16 dut (.*);
    reg [15:0] source [0:CASES*768-1], golden [0:CASES*256-1];
    reg [15:0] gold_p [0:CASES*256-1];
    wire norm_valid=dut.norm_valid;
    wire [3:0] norm_row=dut.norm_row;
    integer cycle=0, capture, probabilities=0, total_y=0, starts=0;
    integer bubbles=0, stalls=0, resets=0;
    integer missing_v_at_pv=0;
    always @(posedge clk) if (rst_n && dut.age_valid[120] && !dut.v_full[dut.entering_pv_v]) begin
        if (dut.step!==0) $fatal(1,"PV read an incomplete V");
        missing_v_at_pv++;
    end
    reg last_accepted=0;
    reg [31:0] rng=32'h28ab709d;
    always @(negedge clk) cycle <= cycle+1;

    function automatic [255:0] pack_input(input integer frame, input integer beat);
        integer offset, lane;
        begin
            pack_input='0;
            for (lane=0; lane<16; lane=lane+1) begin
                if (beat<32) offset=16*beat+lane;
                else offset=512+16*lane+beat-32;
                pack_input[16*lane+:16]=source[768*frame+offset];
            end
        end
    endfunction

    task automatic reset_dut;
        begin
            @(negedge clk); rst_n=0; in_valid=0; out_ready=0;
            repeat(2) begin
                @(posedge clk); #1;
                if (out_valid!==0 || done!==0 || busy!==0)
                    $fatal(1,"reset did not flush public outputs");
            end
            @(negedge clk); rst_n=1; last_accepted=0; resets++;
        end
    endtask

    // Read all interface signals at the same edge. Preserve a held valid input.
    task automatic run_batch;
        integer tx, rx, p_rows, cid, lane, row, idx, in_beat, out_beat, frame;
        integer first_in[0:FRAMES-1], last_in[0:FRAMES-1], first_out;
        integer directed_left, previous_blocked_beat, gap, seen;
        reg input_wait,output_wait;
        reg [255:0] held_y;
        reg [15:0] held_mask, mask;
        reg held_last;
        begin
            tx=0; rx=0; p_rows=0; directed_left=0; previous_blocked_beat=-1;
            input_wait=0; output_wait=0; first_out=-1; gap=0; seen=-1;
            while (rx<FRAMES*OUT_BEATS) begin
                @(negedge clk);
                rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
                if (!input_wait && tx!=seen && gap==0) begin
                    case (tx)
                        47: gap=271;              // delay F0 last V col past nominal PV issuance
                        48: gap=640;              // completely drain F0 then resume w/o reset
                        48+11: gap=163;          // pause in F1 Q
                        2*48+31: gap=150;        // delay final K row in F2
                        3*48+40: gap=270;        // delay V columns during F3 processing
                        6*48+34: gap=177;        // V pause while other frames queued
                        default: gap=0;
                    endcase
                    if (gap>0) begin
                        starts++;
                        $display("GAP_START tx=%0d cycle=%0d duration=%0d rx=%0d",tx,cycle,gap,rx);
                    end
                    seen=tx;
                end
                if (!input_wait) begin
                    in_valid=(gap<=0) && (tx<FRAMES*IN_BEATS) && rng[2:0]!=0;
                    if (in_valid) in_data=pack_input(tx/IN_BEATS,tx%IN_BEATS);
                    else if (tx<FRAMES*IN_BEATS) bubbles++;
                end
                if (gap==1) begin
                    $display("GAP_END tx=%0d cycle=%0d rx=%0d busy=%b",tx,cycle,rx,busy);
                    if (tx==48 && (rx!=31 || busy || out_valid || done)) $fatal(1,"F0 failed to retire while source idle");
                end
                if (gap>0) gap--;
                out_beat=rx%OUT_BEATS;
                if (out_valid && (rx/OUT_BEATS==0 || rx/OUT_BEATS==5) && previous_blocked_beat!=rx &&
                    (out_beat==0 || out_beat==OUT_BEATS/2 || out_beat==OUT_BEATS-1)) begin
                    directed_left=96; previous_blocked_beat=rx;
                end
                out_ready=directed_left==0 && rng[6:4]!=0;
                if (directed_left>0) directed_left--;
                @(posedge clk);
                if (output_wait && (out_valid!==1 || held_y!==out_data ||
                    held_mask!==out_lane_valid || held_last!==out_last))
                    $fatal(1,"stalled output changed cycle=%0d",cycle);
                if (done!==last_accepted) $fatal(1,"wrong done cycle=%0d",cycle);
                if (out_valid && !busy) $fatal(1,"out_valid without busy");
                if ((^{out_valid,in_ready,out_last,busy,done})===1'bx) $fatal(1,"unknown control");
                last_accepted=out_valid && out_ready && out_last;
                input_wait=in_valid && !in_ready;
                output_wait=out_valid && !out_ready;
                if (output_wait) begin
                    held_y=out_data; held_mask=out_lane_valid; held_last=out_last;
                    stalls++;
                end
                if (in_valid && in_ready) begin
                    in_beat=tx%IN_BEATS;
                    if (in_beat==0) first_in[tx/IN_BEATS]=cycle;
                    if (in_beat==IN_BEATS-1) last_in[tx/IN_BEATS]=cycle;
                    tx++;
                end
                if (norm_valid) begin
                    if (p_rows>=16*FRAMES || norm_row!==4'(p_rows%16))
                        $fatal(1,"unexpected probability row frame=%0d row=%0d got=%0d",p_rows/16,p_rows%16,norm_row);
                    cid=p_rows/16;
                    for (lane=0; lane<16; lane=lane+1) begin
                        idx=256*cid+16*(p_rows%16)+lane;
                        if (dut.probability[lane]!==gold_p[idx])
                            $fatal(1,"P mismatch frame=%0d row=%0d col=%0d rtl=%h expected=%h",cid,
                                norm_row,lane,dut.probability[lane],gold_p[idx]);
                    end
                    p_rows++; probabilities+=16;
                end
                if (out_valid && out_ready) begin
                    frame=rx/OUT_BEATS; cid=frame;
                    if (out_beat==0) first_out=cycle;
                    mask=0;
                    for (lane=0; lane<16; lane=lane+1) begin
                        row=out_beat-lane;
                        if (row>=0 && row<16) begin
                            mask[lane]=1;
                            idx=16*row+lane;
                            if (out_data[16*lane+:16]!==golden[256*cid+idx])
                                $fatal(1,"Y mismatch frame=%0d idx=%0d rtl=%h expected=%h",
                                     cid,idx,out_data[16*lane+:16],golden[256*cid+idx]);
                            $fdisplay(capture,"%0d %0d %04h",frame,idx,out_data[16*lane+:16]);
                            total_y++;
                        end
                    end
                    if (out_lane_valid!==mask || out_last!==(out_beat==OUT_BEATS-1))
                        $fatal(1,"bad output mask or last frame=%0d beat=%0d",frame,out_beat);
                    if (out_last) $display("FRAME %0d %0d %0d %0d %0d %0d",
                        frame,cid,first_in[frame],last_in[frame],first_out,cycle);
                    rx++;
                end
            end
            if (tx!=FRAMES*IN_BEATS) $fatal(1,"input count");
            if (p_rows!=FRAMES*16) $fatal(1,"missing probability rows");
            @(negedge clk); in_valid=0; out_ready=1;
            @(posedge clk); if (!done || out_valid) $fatal(1,"bad final retirement");
            last_accepted=0;
            repeat (3) begin @(posedge clk); if (out_valid || busy || done) $fatal(1,"extra output after batch"); end
        end
    endtask
    initial begin
        $readmemh("input.hex",source); $readmemh("expected.hex",golden);
        $readmemh("expected_p.hex",gold_p);
        capture=$fopen("actual.txt","w"); if (!capture) $fatal(1,"capture open failed");
        if ($test$plusargs("WAVES")) begin $dumpfile("attention.vcd"); $dumpvars(1,tb_os_scope_sparse); $dumpvars(1,dut); end
        reset_dut();
        run_batch();
        if (bubbles<1600 || stalls<576 || resets!=1 || starts!=6 || missing_v_at_pv<100) $fatal(1,"missing targeted coverage");
        $display("PASS Y=%0d P=%0d bubbles=%0d stalls=%0d resets=%0d wait_v_at_pv=%0d",total_y,probabilities,bubbles,stalls,resets,missing_v_at_pv);
        $fclose(capture); $finish;
    end
    initial begin repeat(12000) @(posedge clk); $fatal(1,"watchdog"); end
endmodule
