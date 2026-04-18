// =============================================================================
// sync_2ff : two-flop synchronizer for single-bit control / slow-changing data.
//
// Use ONLY for single-bit signals or multi-bit signals whose bits are guaranteed
// never to change on the same cycle (e.g. gray-coded pointers).
// For arbitrary multi-bit data crossings, use async_fifo or a handshake.
//
// Reset is asynchronous active-low, consistent with the global rst_n strategy.
// =============================================================================
module sync_2ff #(
    parameter WIDTH      = 1,
    parameter RESET_VAL  = 1'b0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [WIDTH-1:0]   d_in,
    output wire [WIDTH-1:0]   d_out
);

    reg [WIDTH-1:0] meta_q;
    reg [WIDTH-1:0] sync_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_q <= {WIDTH{RESET_VAL}};
            sync_q <= {WIDTH{RESET_VAL}};
        end else begin
            meta_q <= d_in;
            sync_q <= meta_q;
        end
    end

    assign d_out = sync_q;

endmodule
