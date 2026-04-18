// =============================================================================
// pulse_sync : cross a 1-cycle pulse from src_clk to dst_clk domains.
//
// Mechanism:
//   - Source pulse toggles a level on src_clk.
//   - Level is 2FF-synchronized into dst_clk.
//   - Edge detector in dst_clk regenerates a single-cycle pulse.
//
// Requirement: src_pulse must not assert faster than dst_clk / 3, otherwise
// toggles can be missed. For tx_enable (rising-edge event) this is fine.
// =============================================================================
module pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg toggle_src;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)      toggle_src <= 1'b0;
        else if (src_pulse)  toggle_src <= ~toggle_src;
    end

    wire toggle_dst;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync (
        .clk   (dst_clk),
        .rst_n (dst_rst_n),
        .d_in  (toggle_src),
        .d_out (toggle_dst)
    );

    reg toggle_dst_q;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) toggle_dst_q <= 1'b0;
        else            toggle_dst_q <= toggle_dst;
    end

    assign dst_pulse = toggle_dst ^ toggle_dst_q;

endmodule
