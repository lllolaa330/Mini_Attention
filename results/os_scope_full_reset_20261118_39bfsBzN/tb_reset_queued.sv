`timescale 1ns/1ps
module tb_reset_queued;
    reg clk=0, rst_n=0, in_valid=0, out_ready=0;
    always #5 clk=~clk;
    reg [255:0] in_data=0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    os_scope_attention_fp16 dut (.*);
    localparam N=16, CASES=23, RECOVER=5;
    reg [15:0] source[0:CASES*768-1], y_ref[0:CASES*256-1], p_ref[0:CASES*256-1];
    integer ids[0:RECOVER-1];
    function automatic [255:0] beat(input integer cid,input integer b);
        integer j,offset;
        begin
            for(j=0;j<N;j++) begin
                offset=b<32 ? 16*b+j : 512+16*j+b-32;
                beat[16*j+:16]=source[768*cid+offset];
            end
        end
    endfunction

    integer sent=0, launched=0, preblocked=0, input_blocked=0;
    reg [255:0] saved_y;
    reg [15:0] saved_mask;
    reg saved_last;
    reg full_and_blocked=0;
    reg prev_stall=0, prev_retire=0;
    integer accepted=0, prows=0, nbeat=0, idx, i,j,frame;
    integer wall=0, hold=0, stalls=0;
    reg [15:0] mask;
    initial begin
        $readmemh("input.hex",source);
        $readmemh("expected.hex",y_ref);
        $readmemh("expected_p.hex",p_ref);
        ids[0]=5; ids[1]=4; ids[2]=11; ids[3]=9; ids[4]=5;
        repeat(3) @(negedge clk);
        rst_n=1;
        // Fill outstanding Q/K/P/V state without accepting a single result.
        while(!full_and_blocked) begin
            @(negedge clk); in_valid=1; out_ready=0;
            in_data=beat(sent/48,sent%48);
            @(posedge clk);
            if (dut.step && dut.launch) launched++;
            if (in_valid && in_ready) sent++;
            else input_blocked++;
            if (out_valid) begin
                if (preblocked==0) begin saved_y=out_data; saved_mask=out_lane_valid; saved_last=out_last; end
                else if (out_data!==saved_y || out_lane_valid!==saved_mask || saved_last!==out_last)
                    $fatal(1,"pending old output changed");
                preblocked++;
            end
            if (done) $fatal(1,"retired with downstream permanently blocked");
            full_and_blocked=launched>=3 && sent>=144 && dut.v_full===3'b111 &&
                             out_valid && !in_ready && preblocked>=40;
        end
        $display("PRE_RESET launches=%0d accepted_input_beats=%0d v_full=%b q_full=%b held_outputs=%0d input_blocked=%0d",
                 launched,sent,dut.v_full,dut.q_full,preblocked,input_blocked);
        @(negedge clk); rst_n=0; out_ready=1;
        repeat(3) begin
            @(posedge clk); #1;
            if (out_valid!==0 || out_last!==0 || out_lane_valid!==0 || done!==0 || busy!==0 ||
                in_ready!==0 || dut.history!==0 || dut.v_full!==0 || dut.q_full!==0)
                $fatal(1,"old reservations or output survive reset");
        end
        @(negedge clk); rst_n=1; in_valid=0;
        // Longer than the former frame's entire 166 logical-edge lifetime.
        repeat(210) begin
            @(posedge clk);
            if (out_valid!==0 || done!==0 || busy!==0 || dut.norm_valid!==0 || in_ready!==1)
                $fatal(1,"ghost output or phase after reset");
        end
        launched=0;
        while(accepted<RECOVER*31) begin
            @(negedge clk);
            in_valid=nbeat<48*RECOVER;
            if (in_valid) in_data=beat(ids[nbeat/48],nbeat%48);
            if (out_valid && accepted==42 && hold<36) begin out_ready=0; hold++; end
            else out_ready=(wall%7!=1);
            @(posedge clk);
            if (prev_stall && (!out_valid || saved_y!==out_data ||
                saved_mask!==out_lane_valid || saved_last!==out_last)) $fatal(1,"stalled recovered output changed");
            if (done!==prev_retire) $fatal(1,"spurious or missing done after recovery");
            prev_stall=out_valid && !out_ready; prev_retire=out_valid && out_ready && out_last;
            if(prev_stall) begin saved_y=out_data; saved_mask=out_lane_valid; saved_last=out_last; stalls++; end
            if (in_valid && in_ready) nbeat++;
            if (dut.step && dut.launch) launched++;
            if (dut.norm_valid) begin
                if (prows>=16*RECOVER || dut.norm_row!==4'(prows%16)) $fatal(1,"wrong recovered P tag");
                for (j=0;j<N;j++) begin
                    idx=256*ids[prows/16]+16*(prows%16)+j;
                    if (dut.probability[j]!==p_ref[idx]) $fatal(1,"recovered P mismatch at %0d",idx);
                end
                prows++;
            end
            if (out_valid && out_ready) begin
                frame=accepted/31; mask=0;
                for (j=0;j<N;j++) begin
                    i=(accepted%31)-j;
                    if (i>=0 && i<16) begin
                        mask[j]=1'b1;idx=256*ids[frame]+16*i+j;
                        if (out_data[16*j+:16]!==y_ref[idx]) $fatal(1,"recovered Y mismatch at %0d",idx);
                    end
                end
                if (out_lane_valid!==mask || out_last!==((accepted%31)==30)) $fatal(1,"recovery mask/last");
                accepted++;
            end
            wall++;
        end
        @(negedge clk); in_valid=0;out_ready=1;
        @(posedge clk); if (!done || out_valid) $fatal(1,"wrong final handshake");
        repeat(200) begin @(posedge clk); if(out_valid || done || busy || dut.norm_valid) $fatal(1,"extra result"); end
        if (launched!=RECOVER || nbeat!=48*RECOVER || prows!=16*RECOVER || hold!=36) $fatal(1,"missing recovery coverage");
        $display("PASS empty_after_reset=210 recovered_frames=%0d P=%0d Y=%0d stalled_output_cycles=%0d trailing_idle=200",
                 launched,16*prows,256*RECOVER,stalls);
        $finish;
    end
    initial begin repeat(10000) @(posedge clk); $fatal(1,"watchdog"); end
endmodule
