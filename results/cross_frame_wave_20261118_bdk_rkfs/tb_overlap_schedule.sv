// No-stall scheduling experiment. Reuse the production OS array and normalizer.
// Input matrices are resident, and the consumer captures every finished diagonal.
`timescale 1ns/1ps
module tb_overlap_schedule #(
    parameter integer II = 52, PV_OFFSET = 36, FRAMES = 6
);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer t = -1;
    reg [15:0] words [0:768*FRAMES-1], p_gold [0:256*FRAMES-1], y_gold [0:256*FRAMES-1];
    reg [15:0] stored_p [0:256*FRAMES-1];
    wire [15:0] a_edge [0:15], b_edge [0:15], accum [0:15][0:15];
    wire [15:0] edge_valid;
    wire [30:0] diagonal_enable, diagonal_first;
    wire [15:0] score_valid, raw_score [0:15], probability [0:15];
    wire [3:0] score_col [0:15], norm_issue_row, prob_row;
    wire norm_issue, prob_valid;
    integer p_count = 0, y_count = 0, handoffs = 0;
    reg [255:0] checked_y [0:FRAMES-1];
    wire [255:0] first_mac;
    for (genvar i=0; i<16; i=i+1) begin : observe_rows
        for (genvar j=0; j<16; j=j+1) begin : observe_columns
            assign first_mac[16*i+j] = array_core.rows[i].cols[j].pe.step &&
                array_core.rows[i].cols[j].pe.first_term &&
                array_core.rows[i].cols[j].pe.a_valid_in &&
                array_core.rows[i].cols[j].pe.b_valid_in;
        end
    end
    function automatic bit active(input integer offset);
        active = offset >= 0 && offset/II < FRAMES && offset%II < 16;
    endfunction
    for (genvar n=0; n<16; n=n+1) begin : edges
        wire signed [31:0] qt = t - integer'(n);
        wire signed [31:0] pt = qt - PV_OFFSET;
        wire q = active(qt), p = active(pt);
        wire [31:0] qbase = (qt/II)*768;
        wire [31:0] vbase = (pt/II)*768 + 512;
        wire [31:0] pbase = (pt/II)*256;
        assign edge_valid[n] = q || p;
        assign a_edge[n] = q ? words[qbase + 16*n + (qt%II)] :
                           p ? stored_p[pbase + 16*n + (pt%II)] : 0;
        assign b_edge[n] = q ? words[qbase + 256 + 16*n + (qt%II)] :
                           p ? words[vbase + 16*(pt%II) + n] : 0;
        // Read the old accumulator on the next edge after its k=15 MAC.
        wire signed [31:0] score_age = qt - 16;
        assign score_valid[n] = active(score_age);
        assign score_col[n] = 4'(score_age%II);
        assign raw_score[n] = accum[n][score_col[n]];
        always @(posedge clk) if (rst_n && q && p)
            $fatal(1, "Edge contention t=%0d lane=%0d",t,n);
    end
    for (genvar d=0; d<31; d=d+1) begin : diagonals
        wire signed [31:0] qt = t - integer'(d);
        wire signed [31:0] pt = qt - PV_OFFSET;
        wire q = active(qt), p = active(pt);
        assign diagonal_enable[d] = q || p;
        assign diagonal_first[d] = (q && qt%II == 0) || (p && pt%II == 0);
        always @(posedge clk) if (rst_n && q && p)
            $fatal(1, "PE contention t=%0d diagonal=%0d",t,d);
    end
    systolic_array #(.N(16), .DIAGONAL_CONTROL(1'b1)) array_core (
        .clk, .rst_n, .clear(1'b0), .step(|diagonal_enable),
        .a_edge, .b_edge, .a_valid(edge_valid), .b_valid(edge_valid),
        .diagonal_enable, .diagonal_first, .accum
    );
    online_softmax16 #(.EXP_FILE("exp_fp16.hex")) normalizer (
        .clk, .rst_n, .clear(1'b0), .score_valid, .score_col, .raw_score,
        .norm_issue, .norm_issue_row, .prob_valid, .prob_row, .probability
    );
    always @(posedge clk) if (rst_n) begin : monitor
        integer age, f, i, idx;
        if (prob_valid !== active(t-35))
            $fatal(1, "Probability timing mismatch t=%0d",t);
        if (prob_valid) begin
            f = (t-35)/II;
            if (integer'(prob_row) != (t-35)%II) $fatal(1, "Bad probability row");
            for (integer j=0; j<16; j=j+1) begin
                idx = f*256 + integer'(prob_row)*16 + j;
                if (probability[j] !== p_gold[idx]) $fatal(1, "P mismatch t=%0d idx=%0d",t,idx);
                stored_p[idx] <= probability[j];
                p_count = p_count+1;
            end
        end
        for (integer j=0; j<16; j=j+1) begin
            age = t-PV_OFFSET-16-j;
            if (active(age)) begin
                f = age/II; i = age%II; idx = i*16+j;
                if (checked_y[f][idx] || accum[i][j] !== y_gold[f*256+idx])
                    $fatal(1, "Y mismatch or duplicate t=%0d frame=%0d index=%0d",t,f,idx);
                checked_y[f][idx] = 1'b1;
                y_count = y_count+1;
                // Y(f) read before NBA; QK(f+1), k=0 writes that PE after NBA.
                if (t == (f+1)*II+i+j && f+1<FRAMES) begin
                    if (first_mac[idx] !== 1'b1) $fatal(1, "Missing next-frame first term");
                    handoffs = handoffs+1;
                end
            end
        end
    end
    initial begin
        string wave_path;
        if ($value$plusargs("WAVE=%s",wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(1, tb_overlap_schedule);
            $dumpvars(1, array_core.rows[0].cols[0].pe);
            $dumpvars(1, array_core.rows[15].cols[15].pe);
        end
        $readmemh("input.hex", words);
        $readmemh("expected_p.hex", p_gold);
        $readmemh("expected.hex", y_gold);
        for (integer f=0; f<FRAMES; f=f+1) checked_y[f] = '0;
        repeat (2) @(negedge clk);
        rst_n = 1; t = 0;
        repeat ((FRAMES-1)*II+PV_OFFSET+47) begin @(negedge clk); t=t+1; end
        if (p_count != 256*FRAMES || y_count != 256*FRAMES) $fatal(1, "Wrong totals");
        for (integer f=0; f<FRAMES; f=f+1)
            if (!(&checked_y[f])) $fatal(1, "Missing output");
        if (II == PV_OFFSET+16 && handoffs != (FRAMES-1)*256) $fatal(1,"Wrong handoff count");
        $display("PASS II=%0d PV_OFFSET=%0d frames=%0d P=%0d Y=%0d same_edge_handoffs=%0d",
            II,PV_OFFSET,FRAMES,p_count,y_count,handoffs);
        $finish;
    end
endmodule
