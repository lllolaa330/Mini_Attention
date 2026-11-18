`timescale 1ns/1ps
module tb_overlap_bench #(parameter integer CASES=4, parameter bit USE_WS=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, in_valid=0;
    reg [15:0] in_data=0;
    wire in_ready,out_valid,out_last,busy,done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    wire out_ready=1'b1;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex"),.USE_WS(USE_WS)) dut (.*);

    reg [15:0] inputs [0:CASES*768-1], expected [0:CASES*256-1], actual [0:CASES*256-1];
    integer origin [0:CASES-1], first_out [0:CASES-1], last_out [0:CASES-1];
    integer resident=0, sent=0, completed=0, diag=0, done_count=0, cycle=0;
    integer timing_fd, schedule_fd, capture_fd;
    wire input_fire = in_valid && in_ready;
    wire output_fire = out_valid && out_ready;
    wire [8:0] available_v = dut.bank_full[dut.compute_bank] ? 9'd256 :
        ((dut.write_bank == dut.compute_bank && dut.load_count[9:8] == 2) ? {1'b0,dut.load_count[7:0]} : 9'd0);
`ifdef NEW_V_SCHEDULER
    wire direct_v_load;
    wire [3:0] direct_row;
    if (USE_WS) begin : ws_probe
        assign direct_v_load=dut.array_impl.ws_row_load;
        assign direct_row=dut.array_impl.ws_load_row;
    end else begin : os_probe
        assign direct_v_load=0;
        assign direct_row=0;
    end
    wire pv_ready = dut.pv_inputs_ready;
    localparam OLD_SCHEDULER=0;
`else
    wire direct_v_load = 0;
    wire [3:0] direct_row = 0;
    wire pv_ready = 0;
    localparam OLD_SCHEDULER=1;
`endif

    always @(posedge clk) begin : monitor
        integer lane,row,idx,i,source_frame,source_word,frame,ii;
        reg [15:0] mask;
        reg was_last;
        cycle=cycle+1;
        if (cycle>100000) $fatal(1,"Timeout");
        if (rst_n) begin
            was_last = output_fire && out_last;
            frame = completed;
            source_frame = input_fire ? sent/768 : -1;
            source_word = input_fire ? sent%768 : -1;
            if (input_fire) begin
                if (resident || sent>=CASES*768) $fatal(1,"Unexpected input");
                if (source_word==0) origin[source_frame]=cycle;
                sent=sent+1;
            end
            if (resident && dut.state==dut.CLEAR_QK) begin
                if (frame>=CASES || origin[frame]>=0) $fatal(1,"Unexpected core dispatch");
                origin[frame]=cycle;
            end
            if (frame==0 && origin[0]>=0)
                $fdisplay(schedule_fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%04h,%0d",
                    cycle,cycle-origin[0]+1,dut.state,dut.feed_step,dut.array_step,dut.parallel_softmax[0].sm.state,
                    input_fire,source_frame,source_word,input_fire && source_word>=512,available_v,
                    OLD_SCHEDULER ? -1 : int'(pv_ready),USE_WS && dut.state==8,OLD_SCHEDULER && USE_WS && dut.state==9,
                    direct_v_load,direct_v_load ? int'(direct_row) : -1,output_fire,out_lane_valid,out_last);
            if (output_fire) begin
                if (frame>=CASES || origin[frame]<0) $fatal(1,"Extra or premature output");
                if (diag==0) first_out[frame]=cycle;
                mask=0;
                for (lane=0;lane<16;lane=lane+1) begin
                    row=diag-lane;
                    if (row>=0 && row<16) begin
                        mask[lane]=1;
                        idx=frame*256+row*16+lane;
                        if (out_data[16*lane+:16]!==expected[idx])
                            $fatal(1,"Mismatch frame=%0d row=%0d col=%0d got=%04h expected=%04h",
                                   frame,row,lane,out_data[16*lane+:16],expected[idx]);
                        actual[idx]=out_data[16*lane+:16];
                    end
                end
                if (mask!==out_lane_valid || out_last!==(diag==30)) $fatal(1,"Diagonal protocol error");
                if (diag==30) begin
                    last_out[frame]=cycle;
                    ii = (frame==0 || resident) ? -1 : origin[frame]-origin[frame-1];
                    $fdisplay(timing_fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,31,256",
                              frame,origin[frame],first_out[frame],cycle,first_out[frame]-origin[frame]+1,
                              cycle-origin[frame]+1,ii);
                    completed=completed+1;
                    diag=0;
                end else diag=diag+1;
            end
            #1;
            if (done!==was_last) $fatal(1,"Wrong done pulse");
            if (done) done_count=done_count+1;
        end
    end

    task automatic reset_core;
        @(negedge clk);
        rst_n=0;
        in_valid=0;
        repeat (2) @(negedge clk);
        rst_n=1;
    endtask

    task automatic preload(input integer frame);
        // Model the memory contents and control bits just before dispatching a
        // ready bank. Calculation, array stepping and output use the real DUT.
        reset_core();
        for (integer i=0;i<256;i=i+1) begin
            dut.q_mem[i]=inputs[frame*768+i];
            dut.k_mem[i]=inputs[frame*768+256+i];
            dut.v_mem[i]=inputs[frame*768+512+i];
        end
        dut.qk_ready=2'b01;
        dut.bank_full=2'b01;
        dut.write_bank=1'b1;
        if (dut.compute_bank!==0 || dut.state!==dut.LOAD || dut.load_count!==0)
            $fatal(1,"Incorrect fixture initial state");
        wait(completed==frame+1);
    endtask

    initial begin
        if (!$value$plusargs("RESIDENT=%d",resident)) $fatal(1,"Missing timing mode");
        $readmemh("input.hex",inputs);
        $readmemh("expected.hex",expected);
        for (integer f=0;f<CASES;f=f+1) origin[f]=-1;
        timing_fd=$fopen("timing.csv","w");
        schedule_fd=$fopen("schedule.csv","w");
        capture_fd=$fopen("actual.hex","w");
        if (!timing_fd || !schedule_fd || !capture_fd) $fatal(1,"Cannot create captures");
        $fdisplay(timing_fd,"frame,origin,first_output,last_output,first_output_latency,last_output_latency,input_ii,output_beats,output_words");
        $fdisplay(schedule_fd,"cycle,relative_cycle,state,feed_step,array_step,sm_state,input_fire,input_frame,input_word,v_input,v_words_ready,pv_inputs_ready,ws_shift_qk,ws_shift_v,ws_row_load,ws_load_row,out_fire,out_mask,out_last");
        if (resident) begin
            for (integer frame=0;frame<CASES;frame=frame+1) preload(frame);
        end else begin
            reset_core();
            while (sent<CASES*768) begin
                in_valid=1; in_data=inputs[sent];
                @(negedge clk);
            end
            in_valid=0;
            wait(completed==CASES);
        end
        repeat (4) @(negedge clk);
        if (done_count!=CASES || busy || out_valid || sent!=(resident ? 0 : CASES*768))
            $fatal(1,"Wrong final protocol counts");
        for (integer i=0;i<CASES*256;i=i+1) $fdisplay(capture_fd,"%04h",actual[i]);
        $fclose(schedule_fd); $fclose(timing_fd); $fclose(capture_fd);
        $display("BENCH PASS frames=%0d beats=%0d words=%0d done=%0d",CASES,CASES*31,CASES*256,done_count);
        $finish;
    end
endmodule
