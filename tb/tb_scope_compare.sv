`timescale 1ns/1ps
// Identical mathematical frames and clock across all native public interfaces.
module tb_scope_compare #(
    parameter integer CASES = 23,
    parameter integer PERF_FRAMES = 12,
    parameter integer SCOPE_STRIPS = 2
);
    reg clk=0, rst_n=0, in_valid=0, out_ready=0;
    always #5 clk=~clk;
    reg [255:0] in_data=0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
`ifdef BASELINE
    localparam IN_BEATS=768, OUT_BEATS=256;
    wire [15:0] scalar_out;
    assign out_data={240'b0,scalar_out};
    assign out_lane_valid=16'h1;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (
        .clk, .rst_n, .in_valid, .in_ready, .in_data(in_data[15:0]),
        .out_valid, .out_ready, .out_data(scalar_out), .out_last, .busy, .done);
`else
    localparam IN_BEATS=48, OUT_BEATS=31;
`ifdef STREAM
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
`elsif OS_SCOPE
    os_scope_attention_fp16 dut (.*);
`else
    scope_attention_fp16 #(.STRIPS(SCOPE_STRIPS)) dut (.*);
`endif
`endif
    reg [15:0] source [0:CASES*768-1], golden [0:CASES*256-1];
`ifndef BASELINE
    reg [15:0] gold_p [0:CASES*256-1];
`ifdef STREAM
    wire norm_valid=dut.prob_valid;
    wire [3:0] norm_row=dut.prob_row;
`else
    wire norm_valid=dut.norm_valid;
    wire [3:0] norm_row=dut.norm_row;
`endif
`endif
    integer cycle=0, capture, probabilities=0, total_y=0;
    integer bubbles=0, stalls=0, resets=0;
`ifdef OS_SCOPE
    integer activity;
`endif
    reg last_accepted=0;
    reg [31:0] rng=32'h28ab709d;
    always @(negedge clk) cycle <= cycle+1;

    function automatic [255:0] pack_input(input integer frame, input integer beat);
        integer offset, lane;
        begin
            pack_input='0;
            if (IN_BEATS==768)
                pack_input[15:0]=source[768*frame+beat];
            else for (lane=0; lane<16; lane=lane+1) begin
                if (beat<32) offset=16*beat+lane;
                else offset=512+16*lane+beat-32;
                pack_input[16*lane+:16]=source[768*frame+offset];
            end
        end
    endfunction

    function automatic integer case_id(input integer frame, input bit stress);
        case_id=stress ? frame : frame%(PERF_FRAMES/2);
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

    task automatic discarded_inputs(input integer beats);
        integer sent;
        begin
            sent=0;
            while (sent<beats) begin
                @(negedge clk); in_valid=1; in_data=pack_input(1,sent); out_ready=0;
                @(posedge clk);
                if (in_ready) sent++;
            end
            @(negedge clk); in_valid=0;
        end
    endtask

    // Runs contiguous frames. A held valid beat keeps its full payload.
    task automatic run_batch(input integer count,input bit stress);
        integer tx, rx, p_rows, cid, lane, row, idx, in_beat, out_beat, frame;
        integer first_in[0:CASES*2-1], last_in[0:CASES*2-1], first_out;
        integer directed_left, previous_blocked_beat;
`ifdef OS_SCOPE
        integer input_pause, longest_hold, hold_length;
        reg paused_k, paused_v;
`endif
        reg input_wait,output_wait;
        reg [255:0] held_y;
        reg [15:0] held_mask, mask;
        reg held_last;
        begin
            tx=0; rx=0; p_rows=0; directed_left=0; previous_blocked_beat=-1;
            input_wait=0; output_wait=0; first_out=-1;
`ifdef OS_SCOPE
            input_pause=0; longest_hold=0; hold_length=0; paused_k=0; paused_v=0;
`endif
            while (rx<count*OUT_BEATS) begin
                @(negedge clk);
                rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
`ifdef OS_SCOPE
                if (stress && tx==3*IN_BEATS+31 && !paused_k) begin
                    input_pause=97; paused_k=1;
                end
                if (stress && tx==6*IN_BEATS+47 && !paused_v) begin
                    input_pause=193; paused_v=1;
                end
`endif
                if (!input_wait) begin
                    in_valid=(tx<count*IN_BEATS) && (!stress || rng[2:0]!=0);
`ifdef OS_SCOPE
                    if (input_pause>0) begin in_valid=0; input_pause--; end
`endif
                    if (in_valid) in_data=pack_input(case_id(tx/IN_BEATS,stress),tx%IN_BEATS);
                    else if (tx<count*IN_BEATS) bubbles++;
                end
                out_beat=rx%OUT_BEATS;
                if (stress && out_valid && rx/OUT_BEATS==0 && previous_blocked_beat!=rx &&
                    (out_beat==0 || out_beat==OUT_BEATS/2 || out_beat==OUT_BEATS-1)) begin
                    directed_left=64; previous_blocked_beat=rx;
                end
`ifdef OS_SCOPE
                // Hold an interior output after the stream has filled the banks.
                if (stress && out_valid && rx==4*OUT_BEATS+OUT_BEATS/2 && previous_blocked_beat!=rx) begin
                    directed_left=320; previous_blocked_beat=rx;
                end
`endif
                out_ready=!stress || (directed_left==0 && rng[6:4]!=0);
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
`ifdef OS_SCOPE
                $fdisplay(activity,"%0d %0d %b %b %h %h %h %h %b %h %b",stress,cycle,
                          dut.step,dut.launch,dut.qk_diag_valid,dut.pv_diag_valid,dut.exp_diag_valid,
                          dut.gemm_diag_first,norm_valid,norm_row,output_wait);
                if (output_wait) begin
                    hold_length++;
                    if (hold_length>longest_hold) longest_hold=hold_length;
                end else hold_length=0;
`endif
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
`ifndef BASELINE
                if (norm_valid) begin
                    if (p_rows>=16*count || norm_row!==4'(p_rows%16))
                        $fatal(1,"unexpected probability row frame=%0d row=%0d got=%0d",p_rows/16,p_rows%16,norm_row);
                    cid=case_id(p_rows/16,stress);
                    for (lane=0; lane<16; lane=lane+1) begin
                        idx=256*cid+16*(p_rows%16)+lane;
                        if (dut.probability[lane]!==gold_p[idx])
                            $fatal(1,"P mismatch frame=%0d row=%0d col=%0d rtl=%h expected=%h",cid,
                                norm_row,lane,dut.probability[lane],gold_p[idx]);
                    end
                    p_rows++; probabilities+=16;
                end
`endif
                if (out_valid && out_ready) begin
                    frame=rx/OUT_BEATS; cid=case_id(frame,stress);
                    if (out_beat==0) first_out=cycle;
                    mask=0;
                    for (lane=0; lane<16; lane=lane+1) begin
                        row=out_beat-lane;
                        if ((OUT_BEATS==256 && lane==0) || (OUT_BEATS==31 && row>=0 && row<16)) begin
                            mask[lane]=1;
                            idx=(OUT_BEATS==256) ? out_beat : 16*row+lane;
                            if (out_data[16*lane+:16]!==golden[256*cid+idx])
                                $fatal(1,"Y mismatch stress=%0d frame=%0d idx=%0d rtl=%h expected=%h",
                                     stress,cid,idx,out_data[16*lane+:16],golden[256*cid+idx]);
                            $fdisplay(capture,"%0d %0d %0d %04h",stress,frame,idx,out_data[16*lane+:16]);
                            total_y++;
                        end
                    end
                    if (out_lane_valid!==mask || out_last!==(out_beat==OUT_BEATS-1))
                        $fatal(1,"bad output mask or last frame=%0d beat=%0d",frame,out_beat);
                    if (out_last) $display("FRAME %0d %0d %0d %0d %0d %0d %0d",
                        stress,frame,cid,first_in[frame],last_in[frame],first_out,cycle);
                    rx++;
                end
            end
            if (tx!=count*IN_BEATS) $fatal(1,"input count");
`ifdef OS_SCOPE
            if (stress && (longest_hold<320 || !paused_k || !paused_v))
                $fatal(1,"hybrid directed input/output coverage");
`endif
`ifndef BASELINE
            if (p_rows!=count*16) $fatal(1,"missing probability rows");
`endif
            @(negedge clk); in_valid=0; out_ready=1;
            @(posedge clk); if (!done || out_valid) $fatal(1,"bad final retirement");
            last_accepted=0;
            repeat (3) begin @(posedge clk); if (out_valid || busy || done) $fatal(1,"extra output after batch"); end
        end
    endtask
    initial begin
        $readmemh("input.hex",source); $readmemh("expected.hex",golden);
`ifndef BASELINE
        $readmemh("expected_p.hex",gold_p);
`endif
        capture=$fopen("actual.txt","w"); if (!capture) $fatal(1,"capture open failed");
`ifdef OS_SCOPE
        activity=$fopen("mesh_activity.txt","w"); if (!activity) $fatal(1,"mesh activity file open failed");
`endif
        if ($test$plusargs("WAVES")) begin $dumpfile("attention.vcd"); $dumpvars(1,tb_scope_compare); $dumpvars(1,dut); end
        reset_dut();
        run_batch(PERF_FRAMES,0);
        discarded_inputs(7); reset_dut(); // partially loaded Q
        discarded_inputs(IN_BEATS);
`ifdef BASELINE
        wait(dut.sm_done);
`else
        wait(norm_valid);
`endif
        reset_dut(); // in-flight computation
        discarded_inputs(IN_BEATS); wait(out_valid); repeat(4) @(posedge clk);
        reset_dut(); // captured output awaiting downstream handshake
        run_batch(CASES,1);
        if (bubbles<1 || stalls<192 || resets!=4) $fatal(1,"missing stress coverage");
        $display("PASS Y=%0d P=%0d bubbles=%0d stalls=%0d resets=%0d",total_y,probabilities,bubbles,stalls,resets);
`ifdef OS_SCOPE
        $fclose(activity);
`endif
        $fclose(capture); $finish;
    end
    initial begin repeat((CASES+PERF_FRAMES+8)*30000) @(posedge clk); $fatal(1,"watchdog"); end
endmodule
