`timescale 1ns/1ps
// N x N weight-stationary matrix multiplier for square A and B.
//
// Load: N cycles with weight_edge[j]=B[N-1-load_cycle][j]. Each cycle shifts
// one B row down neighboring weight registers. PE[k,j] then holds B[k,j].
// Compute: logical step t feeds A[t-k][k] into left edge k, valid iff
// 0 <= t-k < N. A travels right; partial sums travel down from FP16 +0.
// PE[k,j] performs FMA16(A[i,k],B[k,j],partial) at t=i+k+j, preserving the
// sequential k=0..N-1 arithmetic order used by the software model.
//
// The bottom PE result is registered at t=i+(N-1)+j and captured below
// on t+1. Thus N=16 requires t=0..46 (47 enabled steps) after weight loading.
// Completed outputs are retained; extra invalid steps cannot overwrite them.
module ws_systolic_array #(parameter integer N = 16) (
    input wire clk, rst_n, clear, load_weights, step,
    input wire [15:0] weight_edge [0:N-1],
    input wire [15:0] a_edge [0:N-1],
    input wire [N-1:0] a_valid,
    output reg [15:0] accum [0:N-1][0:N-1]
);
    localparam integer COUNT_W = $clog2(N+1);
    wire [15:0] weight_link [0:N][0:N-1];
    wire [15:0] a_link [0:N-1][0:N];
    wire a_valid_link [0:N-1][0:N];
    wire [15:0] psum_link [0:N][0:N-1];
    wire psum_valid_link [0:N][0:N-1];
    reg [COUNT_W-1:0] write_row [0:N-1];

    genvar k,j;
    generate
        for (k=0; k<N; k=k+1) begin : edges
            assign a_link[k][0] = a_edge[k];
            assign a_valid_link[k][0] = a_valid[k];
            assign weight_link[0][k] = weight_edge[k];
            assign psum_link[0][k] = 16'h0000;
            assign psum_valid_link[0][k] = 1'b1;
        end
        for (k=0; k<N; k=k+1) begin : rows
            for (j=0; j<N; j=j+1) begin : cols
                fp16_ws_pe pe (
                    .clk(clk), .rst_n(rst_n), .clear(clear),
                    .load_weights(load_weights), .step(step),
                    .weight_in(weight_link[k][j]),
                    .a_in(a_link[k][j]), .psum_in(psum_link[k][j]),
                    .a_valid_in(a_valid_link[k][j]),
                    .psum_valid_in(psum_valid_link[k][j]),
                    .weight(weight_link[k+1][j]),
                    .a_out(a_link[k][j+1]), .psum_out(psum_link[k+1][j]),
                    .a_valid_out(a_valid_link[k][j+1]),
                    .psum_valid_out(psum_valid_link[k+1][j]));
            end
        end
        for (j=0; j<N; j=j+1) begin : capture_columns
            integer row;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    write_row[j] <= 0;
                    for (row=0; row<N; row=row+1) accum[row][j] <= 16'h0000;
                end else if (clear) begin
                    write_row[j] <= 0;
                    for (row=0; row<N; row=row+1) accum[row][j] <= 16'h0000;
                end else if (step && !load_weights) begin
                    // Saturate the write count at N, never wrap on extra steps.
                    if (psum_valid_link[N][j] && (write_row[j] < COUNT_W'(N))) begin
                        accum[int'(write_row[j])][j] <= psum_link[N][j];
                        write_row[j] <= write_row[j] + 1'b1;
                    end
                end
            end
        end
    endgenerate
endmodule
