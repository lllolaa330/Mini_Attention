// Second top for the public-port fixture. Stop the receiver on diagonals
// 0, 15 and 30 of each frame, including the earliest old-Y / next-QK handoff.
`timescale 1ns/1ps
module tb_forced_output;
    integer held_beat=-1, left=0, holds=0, stalls=0, full_stalls=0;
    reg previously_stalled=0;
    reg [272:0] held_payload;
    always @(negedge tb_frame52_trace.clk) if (tb_frame52_trace.rst_n) begin
        if (tb_frame52_trace.out_valid && left==0 &&
            tb_frame52_trace.result_beats!=held_beat &&
            (tb_frame52_trace.result_beats%31==0 ||
             tb_frame52_trace.result_beats%31==15 ||
             tb_frame52_trace.result_beats%31==30)) begin
            held_beat=tb_frame52_trace.result_beats;
            left=23;
            holds=holds+1;
        end
        tb_frame52_trace.out_ready=(left==0);
        if (left>0) left=left-1;
    end
    always @(posedge tb_frame52_trace.clk) if (tb_frame52_trace.rst_n) begin
        if (previously_stalled && (tb_frame52_trace.out_valid!==1'b1 ||
            {tb_frame52_trace.out_data,tb_frame52_trace.out_lane_valid,tb_frame52_trace.out_last}!==held_payload))
            $fatal(1,"Output changed before handshake");
        previously_stalled=tb_frame52_trace.out_valid && !tb_frame52_trace.out_ready;
        held_payload={tb_frame52_trace.out_data,tb_frame52_trace.out_lane_valid,tb_frame52_trace.out_last};
        if (previously_stalled) stalls=stalls+1;
        if (previously_stalled && !tb_frame52_trace.dut.wave_slot_available) begin
            full_stalls=full_stalls+1;
            if (tb_frame52_trace.pe_mac!==256'b0) $fatal(1,"Array advanced into blocked output");
        end
    end
    final begin
        $display("HELD groups=%0d stalled_valid_clocks=%0d both_output_slots_full=%0d",holds,stalls,full_stalls);
        if (holds!=18 || stalls!=414 || full_stalls==0) $error("Incomplete stall coverage");
    end
endmodule
