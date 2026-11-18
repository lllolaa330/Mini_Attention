`timescale 1ns/1ps
module tb;
    reg clk=0,rst_n=0,clear=0;
    always #5 clk=!clk;
    reg [15:0] score_valid=0;
    reg [3:0] score_col [0:15];
    reg [15:0] raw_score [0:15];
    wire norm_issue,prob_valid;
    wire [3:0] norm_issue_row,prob_row;
    wire [15:0] probability [0:15];
    online_softmax16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
    reg [15:0] inputs [0:2047], expected [0:2047];
    integer cid, rows, consecutive=0, best_run=0, total_words=0;
    integer expected_issue=-1, delay0=-1,delay1=-1,delay2=-1;
    bit checking=0;
    always @(posedge clk) begin
        if (!rst_n || clear) begin
            expected_issue=-1; delay0=-1; delay1=-1; delay2=-1;
            consecutive=0;
        end else begin
            if (norm_issue !== (expected_issue>=0)) $fatal(1,"Incorrect issue valid");
            if (norm_issue && norm_issue_row !== 4'(expected_issue)) $fatal(1,"Incorrect issue tag");
            if (prob_valid !== (delay2>=0)) $fatal(1,"Incorrect normalized row valid");
            if (prob_valid && prob_row !== 4'(delay2)) $fatal(1,"Incorrect result tag");
            if (checking && prob_valid) begin
                if (prob_row !== 4'(rows)) $fatal(1,"Wrong row order");
                for (int j=0;j<16;j++) begin
                    if (probability[j] !== expected[cid*256+rows*16+j])
                        $fatal(1,"case %0d row %0d col %0d raw=%h got=%h expect=%h max=%h den=%h",
                               cid,rows,j,inputs[cid*256+rows*16+j],probability[j],
                               expected[cid*256+rows*16+j],dut.row_max[rows],dut.row_sum[rows]);
                    total_words++;
                end
                rows++; consecutive++;
                if (consecutive>best_run) best_run=consecutive;
            end else consecutive=0;
            delay2=delay1; delay1=delay0; delay0=expected_issue; expected_issue=-1;
            for (int r=0;r<16;r++)
                if (score_valid[r] && score_col[r]==15) expected_issue=r;
        end
    end
    task automatic diagonal(input integer case_id, input integer t);
        @(negedge clk);
        score_valid=0;
        for (int r=0;r<16;r++) begin
            if (t>=r && t-r<16) begin
                score_valid[r]=1; score_col[r]=4'(t-r); raw_score[r]=inputs[256*case_id+r*16+(t-r)];
            end else begin score_col[r]='x; raw_score[r]='x; end
        end
    endtask
    initial begin
        $readmemh("raw.hex",inputs); $readmemh("expected.hex",expected);
        repeat(3) @(negedge clk); rst_n=1;
        // Abort a frame with one row in each normalization pipeline stage.
        for(int t=0;t<20;t++) diagonal(2,t);
        @(negedge clk); score_valid=0; clear=1;
        @(negedge clk); clear=0;
        for(cid=0;cid<8;cid++) begin
            rows=0; checking=1;
            for(int t=0;t<31;t++) begin
                if(cid[0] && t%3==0) diagonal(cid,-1);
                diagonal(cid,t);
            end
            repeat(7) diagonal(cid,-1);
            if(rows!=16) $fatal(1,"Incomplete frame");
            checking=0;
        end
        if(best_run!=16 || total_words!=2048) $fatal(1,"Missing full-window throughput coverage");
        $display("ONLINE SOFTMAX PASS rows=128 words=%0d longest_consecutive_rows=%0d",total_words,best_run);
        $finish;
    end
endmodule
