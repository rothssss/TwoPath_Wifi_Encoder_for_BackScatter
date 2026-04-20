// =============================================================================
// reset_sync : async-assert, sync-deassert reset synchronizer.
//
// The input `async_rst_n` is the chip-level asynchronous reset (typically
// POR + pin).  It is immediately asserted (flush the domain) but is
// re-released synchronously with `clk`, so no flop in the domain can see
// a reset-release edge violating its recovery/removal window.
//
// Instantiate ONE per clock domain that needs synchronous de-assertion
// (i.e., every functional clock in the design).
//
// SDC handling: declare async_rst_n as an async reset.  The recovery/removal
// arcs from the second stage are valid sync paths to all loads.
// =============================================================================
module reset_sync (
    input  wire clk,
    input  wire async_rst_n,
    output wire sync_rst_n
);

    reg meta_q;
    reg sync_q;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            meta_q <= 1'b0;
            sync_q <= 1'b0;
        end else begin
            meta_q <= 1'b1;
            sync_q <= meta_q;
        end
    end

    assign sync_rst_n = sync_q;

endmodule
