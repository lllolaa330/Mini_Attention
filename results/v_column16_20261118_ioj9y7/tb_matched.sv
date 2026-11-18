`timescale 1ns/1ps
module tb_matched;
    localparam N = 16;
`ifdef COLUMN_INPUT
    localparam INPUT_BEATS = 528;
    logic [255:0] in_data;
`else
    localparam INPUT_BEATS = 768;
    logic [15:0] in_data;
`endif
    logic clk = 0, rst_n = 0, in_valid = 0, out_ready = 1;
    always #5 clk = ~clk;
    wire in_ready, out_valid, out_last, busy, done;
    wire [255:0] out_data;
    wire [15:0] out_lane_valid;
    attention_fp16 #(.EXP_FILE("exp_fp16.hex")) dut (.*);
    logic [15:0] inputs[0:767], expected[0:255], expected_p[0:255];
    wire qk_step = dut.qk_step;
    wire pv_step = dut.pv_step;
    wire v_ready = dut.v_ready;
    wire wave_slot_available = dut.wave_slot_available;
    wire prob_valid = dut.prob_valid;
    wire [3:0] prob_row = dut.prob_row;
    wire [255:0] pe_mac;
    genvar i,j;
    generate for(i=0;i<N;i=i+1) begin: pe_rows
        for(j=0;j<N;j=j+1) begin: pe_cols
            assign pe_mac[N*i+j] = dut.array_core.rows[i].cols[j].pe.step &&
                dut.array_core.rows[i].cols[j].pe.a_valid_in &&
                dut.array_core.rows[i].cols[j].pe.b_valid_in;
        end
    end endgenerate

    integer input_beats=0, groups=0, blocked=0, held_cycles=0, words=0, p_rows=0, cycles=0;
    reg previous_stall=0, held_last=0;
    reg [255:0] held_data;
    reg [15:0] held_mask;
    initial begin
        if (!$value$plusargs("HOLD=%d",held_cycles)) $fatal;
        $readmemh("input.hex",inputs);
        $readmemh("expected.hex",expected);
        $readmemh("expected_p.hex",expected_p);
        $dumpfile("attention.vcd");
        $dumpvars(1,tb_matched);
        repeat(2) @(negedge clk);
        rst_n=1;
    end

    always @(negedge clk) begin
        if(rst_n) begin
            in_valid=input_beats<INPUT_BEATS;
            in_data='0;
            if(in_valid) begin
`ifdef COLUMN_INPUT
                if(input_beats<512) in_data[15:0]=inputs[input_beats];
                else for(integer k=0;k<N;k=k+1)
                    in_data[16*k+:16]=inputs[512+16*k+input_beats-512];
`else
                in_data=inputs[input_beats];
`endif
            end
            // Hold output group 5 for exactly HOLD valid cycles in either DUT.
            out_ready=!(out_valid && groups==5 && blocked<held_cycles);
        end
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>3000) $fatal(1,"Timeout");
        if(rst_n) begin
            if(previous_stall && (!out_valid || out_data!==held_data || out_lane_valid!==held_mask || out_last!==held_last))
                $fatal(1,"Unstable stalled group");
            if(done) begin
                if(input_beats!=INPUT_BEATS || groups!=31 || words!=256 || p_rows!=16 || blocked!=held_cycles)
                    $fatal(1,"Counts %0d %0d %0d %0d %0d",input_beats,groups,words,p_rows,blocked);
                $display("PASS beats=%0d output_words=%0d prob_rows=%0d blocked=%0d",input_beats,words,p_rows,blocked);
                $finish;
            end
            if(in_valid && in_ready) input_beats=input_beats+1;
            if(prob_valid) begin
                if(prob_row!==4'(p_rows)) $fatal(1,"P row ordering");
                for(integer k=0;k<N;k=k+1)
                    if(dut.probability[k]!==expected_p[16*p_rows+k]) $fatal(1,"P mismatch row %0d k %0d",p_rows,k);
                p_rows=p_rows+1;
            end
            previous_stall=out_valid && !out_ready;
            if(previous_stall) begin
                held_data=out_data; held_mask=out_lane_valid; held_last=out_last; blocked=blocked+1;
            end
            if(out_valid && out_ready) begin
                if(out_last!==(groups==30)) $fatal(1,"Frame end");
                for(integer col=0;col<N;col=col+1) begin
                    if(out_lane_valid[col]!==((groups>=col)&&(groups-col<N))) $fatal(1,"Lane mask");
                    if(out_lane_valid[col]) begin
                        if(out_data[16*col+:16]!==expected[16*(groups-col)+col]) $fatal(1,"Y mismatch on group %0d col %0d",groups,col);
                        words=words+1;
                    end
                end
                groups=groups+1;
            end
        end
    end
endmodule
