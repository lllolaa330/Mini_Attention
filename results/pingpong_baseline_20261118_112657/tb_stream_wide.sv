`timescale 1ns/1ps
// Wide-output adapter of the scalar saturated-stream benchmark; same source/sink stimulus.
// Source keeps valid asserted between frames and holds data until accepted.
// Sink remains ready. No hierarchical DUT state/timing assumptions are used.
module tb_stream #(parameter integer CASES=25, parameter bit USE_WS=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg in_valid=0;
    wire in_ready;
    reg [15:0] in_data=0;
    wire out_valid,out_last,busy,done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    wire out_ready=1'b1;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex"),.USE_WS(USE_WS)) dut (
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_last(out_last),.out_lane_valid(out_lane_valid),.busy(busy),.done(done));
    reg [15:0] inputs[0:CASES*768-1],expected[0:CASES*256-1];
    integer first_in[0:CASES-1],last_in[0:CASES-1],first_out[0:CASES-1],last_out[0:CASES-1];
    integer cycle=0,sent=0,received=0,done_count=0,frame,ii,fd,actual_fd;
    reg [15:0] held_data;
    reg held=0;
    integer diagonal=0,lane,result_row,element,word;
    reg [15:0] expected_mask;
    reg [15:0] actual_words [0:CASES*256-1];
    always @(negedge clk) begin
        if(rst_n && sent<CASES*768) begin
            in_valid=1;
            in_data=inputs[sent];
        end else begin in_valid=0; in_data=0; end
    end
    always @(posedge clk) begin
        if(rst_n) begin
            cycle=cycle+1;
            if(cycle>1000000) $fatal(1,"Stream timeout sent=%0d received=%0d",sent,received);
            if(held && (!in_valid || in_data!==held_data)) $fatal(1,"Source violated ready/valid");
            held=in_valid && !in_ready; held_data=in_data;
            if(in_valid && in_ready) begin
                frame=sent/768;
                if(sent%768==0) first_in[frame]=cycle;
                if(sent%768==767) last_in[frame]=cycle;
                sent=sent+1;
            end
            if(done) done_count=done_count+1;
            if(out_valid) begin
                if(received>=CASES*256) $fatal(1,"Extra output");
                frame=received/256;
                expected_mask=0;
                for(lane=0;lane<16;lane=lane+1) begin
                    result_row=diagonal-lane;
                    if(result_row>=0 && result_row<16) expected_mask[lane]=1;
                end
                if(out_lane_valid!==expected_mask) $fatal(1,"Incorrect lane mask frame=%0d diag=%0d got=%h expected=%h",frame,diagonal,out_lane_valid,expected_mask);
                if(out_last !== (diagonal==30)) $fatal(1,"Incorrect out_last");
                if(diagonal==0) first_out[frame]=cycle;
                for(lane=0;lane<16;lane=lane+1) begin
                    if(out_lane_valid[lane]) begin
                        result_row=diagonal-lane;
                        element=frame*256+result_row*16+lane;
                        if(out_data[16*lane+:16]!==expected[element]) $fatal(1,"Stream bit mismatch frame=%0d row=%0d col=%0d got=%h expected=%h",frame,result_row,lane,out_data[16*lane+:16],expected[element]);
                        if(out_data[16*lane+10+:5]==5'h1f) $fatal(1,"Nonfinite output");
                        actual_words[element]=out_data[16*lane+:16];
                        received=received+1;
                    end
                end
                if(diagonal==30) begin
                    last_out[frame]=cycle;
                    ii=(frame==0) ? 0 : first_in[frame]-first_in[frame-1];
                    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",frame,first_in[frame],last_in[frame],first_out[frame],last_out[frame],last_out[frame]-first_in[frame]+1,ii);
                    $display("FRAME %0d first_in=%0d first_out=%0d last_out=%0d latency=%0d input_ii=%0d",frame,first_in[frame],first_out[frame],last_out[frame],last_out[frame]-first_in[frame]+1,ii);
                    diagonal=0;
                end else diagonal=diagonal+1;
            end
        end
    end
    initial begin
        $readmemh("input.hex",inputs); $readmemh("expected.hex",expected);
        fd=$fopen("timing.csv","w"); actual_fd=$fopen("actual.hex","w");
        if(fd==0 || actual_fd==0) $fatal(1,"Cannot open output");
        $fdisplay(fd,"frame,first_input,last_input,first_output,last_output,latency,input_ii");
        repeat(3) @(negedge clk); #1 rst_n=1;
        wait(received==CASES*256);
        repeat(10) @(negedge clk);
        if(sent!=CASES*768 || done_count!=CASES || busy || out_valid) $fatal(1,"Final protocol mismatch sent=%0d done=%0d busy=%b",sent,done_count,busy);
        for(word=0;word<CASES*256;word=word+1) $fdisplay(actual_fd,"%04h",actual_words[word]);
        $fclose(fd); $fclose(actual_fd);
        $display("STREAM PASS frames=%0d outputs=%0d",CASES,received);
        $finish;
    end
endmodule
