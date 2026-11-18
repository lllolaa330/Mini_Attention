`timescale 1ns/1ps
// Public-port continuous source and ready sink. Observe P and each actual MAC.
// Fixture inputs are row-major words from the archived six-frame baseline.
module tb_frame52_trace;
    parameter integer NFRAMES = 6;
    reg clk=0, rst_n=0, in_valid=0, out_ready=1;
    reg [255:0] in_data=0;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
    always #5 clk = ~clk;

    reg [15:0] source [0:NFRAMES*768-1];
    reg [15:0] y_gold [0:NFRAMES*256-1], p_gold [0:NFRAMES*256-1];
    integer sent=0, norm_rows=0, result_beats=0, result_words=0, done_count=0;
    wire [255:0] pe_mac;
    for (genvar i=0;i<16;i=i+1) begin
        for (genvar j=0;j<16;j=j+1)
            assign pe_mac[i*16+j] = dut.array_core.rows[i].cols[j].pe.step
                 && dut.array_core.rows[i].cols[j].pe.a_valid_in
                 && dut.array_core.rows[i].cols[j].pe.b_valid_in;
    end
    function automatic [255:0] beat_data(input integer n);
        integer word0, beat, slot;
        begin
            word0=(n/48)*768;
            beat=n%48;
            for (integer lane=0;lane<16;lane=lane+1) begin
                if (beat<32) slot=beat*16+lane;
                else slot=512+lane*16+beat-32;
                beat_data[16*lane+:16]=source[word0+slot];
            end
        end
    endfunction
    initial begin
        $readmemh("input.hex",source);
        $readmemh("expected.hex",y_gold);
        $readmemh("expected_p.hex",p_gold);
        $dumpfile("attention.vcd");
        $dumpvars(1,tb_frame52_trace);
        $dumpvars(1,dut);
        $dumpvars(1,dut.array_core.rows[0].cols[0].pe);
        $dumpvars(1,dut.array_core.rows[15].cols[15].pe);
        repeat (3) @(negedge clk);
        rst_n=1;
        while(sent<NFRAMES*48) begin
            in_valid=1; in_data=beat_data(sent);
            @(posedge clk);
            if (in_ready) sent=sent+1;
            @(negedge clk);
        end
        in_valid=0;
        wait(done_count==NFRAMES);
        repeat(5) @(negedge clk);
        if (norm_rows!=NFRAMES*16 || result_words!=NFRAMES*256 || busy!==0 || out_valid!==0)
            $fatal(1,"Bad retirement: P rows=%0d Y words=%0d busy=%b",norm_rows,result_words,busy);
        $display("PASS frames=%0d input_beats=%0d P=%0d Y=%0d done=%0d",NFRAMES,sent,norm_rows*16,result_words,done_count);
        $finish;
    end

    always @(posedge clk) if (rst_n) begin : capture
        integer row, d, base;
        reg [15:0] mask;
        if (dut.prob_valid) begin
            if (norm_rows>=NFRAMES*16 || dut.prob_row!==4'(norm_rows%16))
                $fatal(1,"Unexpected probability row %0d",norm_rows);
            for (integer j=0; j<16; j=j+1)
                if (dut.probability[j]!==p_gold[norm_rows*16+j])
                    $fatal(1,"P frame=%0d row=%0d col=%0d",norm_rows/16,norm_rows%16,j);
            norm_rows=norm_rows+1;
        end
        if (out_valid && out_ready) begin
            d=result_beats%31; base=(result_beats/31)*256; mask=0;
            if (base>=NFRAMES*256) $fatal(1,"Unexpected output beat");
            for (integer j=0; j<16; j=j+1) begin
                row=d-j;
                if (row>=0 && row<16) begin
                    mask[j]=1;
                    if(out_data[j*16+:16]!==y_gold[base+row*16+j])
                        $fatal(1,"Y frame=%0d row=%0d col=%0d",base/256,row,j);
                    result_words=result_words+1;
                end
            end
            if(out_last!==(d==30) || out_lane_valid!==mask)
                $fatal(1,"Output sideband mismatch diagonal=%0d",d);
            result_beats=result_beats+1;
        end
        if(done) done_count=done_count+1;
    end
    initial begin #20000; $fatal(1,"Timeout sent=%0d returned=%0d",sent,result_beats); end
endmodule
