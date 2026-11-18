`timescale 1ns/1ps
// Interface-only saturated-stream benchmark, shared unchanged by old/new RTL.
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
    wire [15:0] out_data;
    wire out_ready=1'b1;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex"),.USE_WS(USE_WS)) dut (
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_last(out_last),.busy(busy),.done(done));
    reg [15:0] inputs[0:CASES*768-1],expected[0:CASES*256-1];
    integer first_in[0:CASES-1],last_in[0:CASES-1],first_out[0:CASES-1],last_out[0:CASES-1];
    integer cycle=0,sent=0,received=0,done_count=0,frame,ii,fd,actual_fd;
    reg [15:0] held_data;
    reg held=0;
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
                if(out_data!==expected[received]) $fatal(1,"Stream bit mismatch frame=%0d element=%0d got=%h expected=%h",frame,received%256,out_data,expected[received]);
                if(out_data[14:10]==5'h1f) $fatal(1,"Nonfinite output");
                if(out_last !== (received%256==255)) $fatal(1,"Incorrect out_last");
                $fdisplay(actual_fd,"%04h",out_data);
                if(received%256==0) first_out[frame]=cycle;
                if(received%256==255) begin
                    last_out[frame]=cycle;
                    ii=(frame==0) ? 0 : first_in[frame]-first_in[frame-1];
                    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",frame,first_in[frame],last_in[frame],first_out[frame],last_out[frame],last_out[frame]-first_in[frame]+1,ii);
                    $display("FRAME %0d first_in=%0d first_out=%0d last_out=%0d latency=%0d input_ii=%0d",frame,first_in[frame],first_out[frame],last_out[frame],last_out[frame]-first_in[frame]+1,ii);
                end
                received=received+1;
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
        $fclose(fd); $fclose(actual_fd);
        $display("STREAM PASS frames=%0d outputs=%0d",CASES,received);
        $finish;
    end
endmodule
