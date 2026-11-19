`timescale 1ns/1ps
module tb_mesh;
    reg clk=0, rst_n=0, step=0;
    reg [255:0] west=0, north=0, x_in=0, exp_expected;
    reg [30:0] gemm_diag_valid=0, gemm_diag_first=0, exp_diag_valid=0;
    reg [4095:0] expected;
    wire [4095:0] accum;
    wire [255:0] exp_out;
    integer fd, n, edge_id;
    os_scope_array dut (.*);
    initial begin
        fd=$fopen("stimulus.txt","r");
        if (!fd) $fatal(1,"missing stimulus");
        n=$fscanf(fd,"%d %b %b %h %h %h %h %h %h %h %h",edge_id,rst_n,step,
                   west,north,x_in,gemm_diag_valid,gemm_diag_first,exp_diag_valid,expected,exp_expected);
        while (n==11) begin
            #5; clk=1; #1;
            if (expected!==accum) begin
                for (integer p=0;p<256;p=p+1)
                    if (expected[16*p+:16]!==accum[16*p+:16])
                        $fatal(1,"ACC slot=%0d r=%0d c=%0d actual=%h expected=%h",edge_id,p/16,p%16,accum[16*p+:16],expected[16*p+:16]);
            end
            if (exp_expected!==exp_out)
                $fatal(1,"EXP slot=%0d actual=%h expected=%h",edge_id,exp_out,exp_expected);
            #4; clk=0; #1;
            n=$fscanf(fd,"%d %b %b %h %h %h %h %h %h %h %h",edge_id,rst_n,step,
                      west,north,x_in,gemm_diag_valid,gemm_diag_first,exp_diag_valid,expected,exp_expected);
        end
        if (!$feof(fd)) $fatal(1,"malformed stimulus");
        $display("PASS all physical OS accumulators and 16 strip outputs through edge %0d",edge_id);
        $finish;
    end
endmodule
