`timescale 1ns/1ps
module tb_fp16 #(parameter integer VECTORS=200000);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, start=0;
    reg [15:0] a=0,b=0,c=0;
    reg sub=0;
    wire [15:0] yfma,yadd,ymul,ydiv;
    wire ready,done;
    fp16_fma u_fma(a,b,c,yfma);
    fp16_addsub u_add(sub,a,b,yadd);
    fp16_mul u_mul(a,b,ymul);
    fp16_div u_div(clk,rst_n,start,a,b,ready,done,ydiv);
    reg [67:0] vectors [0:VECTORS-1];
    reg [15:0] actual,expected;
    reg [3:0] op;
    integer count,idx,waits;
    string path;
    initial begin
        if (!$value$plusargs("VECTORS=%s",path)) $fatal(1,"Missing VECTORS");
        if (!$value$plusargs("COUNT=%d",count) || count<1 || count>VECTORS)
            $fatal(1,"Invalid COUNT");
        $readmemh(path,vectors,0,count-1);
        repeat(3) @(negedge clk);
        rst_n=1;
        // Abort an in-flight nontrivial division; no stale done may survive.
        @(negedge clk); a=16'h3c00; b=16'h4200; start=1;
        @(negedge clk); start=0;
        @(negedge clk); rst_n=0;
        @(negedge clk);
        if (done!==0) $fatal(1,"Divider done during reset");
        rst_n=1;
        @(negedge clk);
        if (ready!==1 || done!==0) $fatal(1,"Divider failed reset recovery");
        for(idx=0;idx<count;idx=idx+1) begin
            @(negedge clk);
            {op,a,b,c,expected}=vectors[idx];
            sub=(op==2);
            #1;
            case(op)
              0: actual=yfma;
              1,2: actual=yadd;
              3: actual=ymul;
              4: begin
                  if(ready!==1) $fatal(1,"Divider not ready at vector %0d",idx);
                  start=1;
                  @(negedge clk); start=0; waits=0;
                  while(done!==1 && waits<100) begin
                      @(negedge clk); waits=waits+1;
                  end
                  if(done!==1) $fatal(1,"Divider timeout at vector %0d",idx);
                  actual=ydiv;
                  // Consume the result before accepting another request.
                  @(negedge clk);
              end
              default: $fatal(1,"Bad op %0d",op);
            endcase
            if (expected[14:10]==5'h1f && expected[9:0]!=0) begin
                if (actual[14:10]!=5'h1f || actual[9:0]==0)
                    $fatal(1,"Expected NaN idx=%0d got=%h",idx,actual);
            end else if(actual!==expected)
                $fatal(1,"Arithmetic mismatch idx=%0d op=%0d a=%h b=%h c=%h actual=%h expected=%h",idx,op,a,b,c,actual,expected);
        end
        $display("ARITHMETIC PASS vectors=%0d, divider reset-abort recovery",count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Arithmetic watchdog timeout"); end
endmodule
