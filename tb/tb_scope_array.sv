`timescale 1ns/1ps
module tb_scope_array #(parameter integer STRIPS = 2);
    localparam integer WIDTH = 8*STRIPS, INPUT_GROUPS = 256/WIDTH;
    reg clk=0, rst_n=0, load=0, commit=0, gemm=0, scna=0;
    always #5 clk=~clk;
    reg [255:0] west=0, x_in=0;
    wire [255:0] gemm_out, exp_out;
    scope_array #(.STRIPS(STRIPS)) dut (.*);
    `include "rtl/scope_exp_coeffs.svh"

    reg [15:0] q [0:255], k [0:255], v [0:255], p [0:255];
    reg [15:0] qk_gold [0:255], y_gold [0:255];
    reg [15:0] x [0:255], exp_gold [0:255];
    integer qk_count=0, exp_count=0, y_count=0;

    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic activate_weights;
        load=0; gemm=0; scna=0; commit=1;
        tick();
        commit=0;
    endtask

    // One output for each (i,j) on edge t=i+j+15. Next coefficients
    // enter from the west immediately behind Q's last activation in row 15.
    task automatic run_gemm(input bit with_q);
        integer t, i, j, row;
        begin
            for (t=0; t<(with_q ? 47 : 46); t=t+1) begin
                gemm=t<=45;
                load=with_q && t>=31;
                west=0;
                for (row=0; row<16; row=row+1) begin
                    i=t-row;
                    if (load) begin
                        j=46-t;
                        west[16*row+:16]=j%2==0 ? scope_exp_weight(3'(row)) : scope_exp_bias(3'(row));
                    end else if (i>=0 && i<16)
                        west[16*row+:16]=with_q ? q[16*i+row] : p[16*i+row];
                end
                tick();
                for (j=0; j<16; j=j+1) begin
                    i=t-15-j;
                    if (i>=0 && i<16) begin
                        if (gemm_out[16*j+:16] !== (with_q ? qk_gold[16*i+j] : y_gold[16*i+j]))
                            $fatal(1,"GEMM phase=%0d i=%0d j=%0d got=%h",with_q,i,j,gemm_out[16*j+:16]);
                        if (with_q) qk_count++; else y_count++;
                    end
                end
            end
            gemm=0;
        end
    endtask

    integer t, wall, lane;
    reg [255:0] prior_exp;
    initial begin
        $readmemh("q.hex",q); $readmemh("k.hex",k); $readmemh("v.hex",v); $readmemh("p.hex",p);
        $readmemh("qk.hex",qk_gold); $readmemh("y.hex",y_gold);
        $readmemh("x.hex",x); $readmemh("exp.hex",exp_gold);
        repeat(2) tick();
        rst_n=1; load=1;
        for (t=0; t<16; t=t+1) begin
            for (lane=0; lane<16; lane=lane+1) west[16*lane+:16]=k[16*(15-t)+lane];
            tick();
        end
        activate_weights();
        run_gemm(1);
        activate_weights();
        t=0; wall=0;
        while (t<INPUT_GROUPS+8) begin
            // V preload advances on wall clocks, including SCNA hold cycles.
            load=wall<16;
            scna=wall%5!=3;
            west=0; x_in=0;
            for (lane=0; lane<16; lane=lane+1) begin
                if (load) west[16*lane+:16]=v[16*lane+15-wall];
                if (lane<WIDTH && t<INPUT_GROUPS) x_in[16*lane+:16]=x[WIDTH*t+lane];
            end
            prior_exp=exp_out;
            tick();
            if (!scna && exp_out!==prior_exp) $fatal(1,"SCNA result changed while held");
            if (scna) begin
                if (t>=8) begin
                    for (lane=0; lane<WIDTH; lane=lane+1) begin
                        if (exp_out[16*lane+:16] !== exp_gold[(t-8)*WIDTH+lane])
                            $fatal(1,"SCNA mismatch group=%0d lane=%0d got=%h exp=%h",
                                   t-8,lane,exp_out[16*lane+:16],exp_gold[(t-8)*WIDTH+lane]);
                        exp_count++;
                    end
                end
                t++;
            end
            wall++;
        end
        activate_weights();
        run_gemm(0);
        if (qk_count!=256 || exp_count!=256 || y_count!=256) $fatal(1,"Incomplete coverage");
        $display("PASS STRIPS=%0d raw_QK=%0d Exp=%0d PV=%0d",STRIPS,qk_count,exp_count,y_count);
        $finish;
    end
endmodule
