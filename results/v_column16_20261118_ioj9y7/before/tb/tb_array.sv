`timescale 1ns/1ps
module tb_array #(parameter integer N=16, K=16);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clear=0, step=0;
    reg [15:0] a_edge [0:N-1];
    reg [15:0] b_edge [0:N-1];
    reg [N-1:0] av=0,bv=0;
    wire [15:0] accum [0:N-1][0:N-1];
    reg [15:0] before_hold [0:N-1][0:N-1];
    reg [15:0] mat_a [0:65535],mat_b[0:65535],expected[0:65535];
    string a_path,b_path,e_path;
    integer count,frame,t,i,j,idx,hold_count;
    systolic_array #(N) dut(clk,rst_n,clear,step,a_edge,b_edge,av,bv,accum,{(2*N-1){1'b1}},{(2*N-1){1'b0}});
    initial begin
        if(!$value$plusargs("A=%s",a_path) || !$value$plusargs("B=%s",b_path) ||
           !$value$plusargs("EXPECTED=%s",e_path) || !$value$plusargs("COUNT=%d",count))
            $fatal(1,"Missing array plusargs");
        if(count<1 || count*N*K>65536 || count*N*N>65536) $fatal(1,"Bad array count");
        $readmemh(a_path,mat_a,0,count*N*K-1);
        $readmemh(b_path,mat_b,0,count*K*N-1);
        $readmemh(e_path,expected,0,count*N*N-1);
        for(i=0;i<N;i=i+1) begin a_edge[i]=0; b_edge[i]=0; end
        repeat(3) @(negedge clk);
        rst_n=1;
        // Deliberately contaminate every PE, then abort through async reset.
        av='1; bv='1; step=1;
        for(i=0;i<N;i=i+1) begin a_edge[i]=16'h3c00; b_edge[i]=16'h3c00; end
        repeat(2*N+2) @(negedge clk);
        rst_n=0; step=0; av=0; bv=0;
        @(negedge clk);
        for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
            if(accum[i][j]!==16'h0000) $fatal(1,"Array reset did not clear (%0d,%0d)",i,j);
        rst_n=1; hold_count=0;
        for(frame=0;frame<count;frame=frame+1) begin
            @(negedge clk); clear=1; step=1;
            @(negedge clk); clear=0; step=0;
            for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
                if(accum[i][j]!==16'h0000) $fatal(1,"Array clear priority failure");
            for(t=0;t<K+2*(N-1);t=t+1) begin
                for(i=0;i<N;i=i+1) begin
                    idx=t-i;
                    av[i]=(idx>=0 && idx<K);
                    bv[i]=(idx>=0 && idx<K);
                    // NaN on invalid lanes proves arithmetic is gated by valid.
                    a_edge[i]=av[i] ? mat_a[frame*N*K+i*K+idx] : 16'h7e00;
                    b_edge[i]=bv[i] ? mat_b[frame*K*N+idx*N+i] : 16'h7e00;
                end
                if((t%5)==1) begin
                    for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
                        before_hold[i][j]=accum[i][j];
                    step=0;
                    repeat(2) @(negedge clk);
                    for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
                        if(accum[i][j]!==before_hold[i][j]) $fatal(1,"step hold failure");
                    hold_count=hold_count+2;
                end
                step=1;
                @(negedge clk);
            end
            step=0; av=0; bv=0;
            for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
                if(accum[i][j]!==expected[frame*N*N+i*N+j])
                    $fatal(1,"Array mismatch frame=%0d row=%0d col=%0d got=%h expected=%h",frame,i,j,accum[i][j],expected[frame*N*N+i*N+j]);
            // Propagate invalid poison through the array: no accumulator changes.
            step=1;
            repeat(2*N) @(negedge clk);
            step=0;
            for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1)
                if(accum[i][j]!==expected[frame*N*N+i*N+j]) $fatal(1,"Invalid data changed result");
        end
        $display("PASS array N=%0d K=%0d frames=%0d outputs=%0d held_cycles=%0d reset/clear/invalid/continuous",N,K,count,count*N*N,hold_count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Array watchdog timeout"); end
endmodule
