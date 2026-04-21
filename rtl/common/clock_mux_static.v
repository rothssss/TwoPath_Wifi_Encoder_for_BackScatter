// =============================================================================
// clock_mux_static : 2:1 clock mux intended for STATIC select only.
//
// USAGE CONSTRAINT (critical for tape-out):
//   `sel` must NOT change while either clk0 or clk1 is toggling.  The
//   project-level integration guarantees this because `mod_config` is a
//   static configuration register that is programmed BEFORE either of
//   clk_b_chip/clk_custom is un-gated.
//
// For production silicon, REPLACE this wrapper with the standard-cell
// library's glitch-free clock mux (e.g. CKMUX2D* in most foundry kits)
// and declare it as a clock in SDC.  Do not leave a generic MUX on a clock
// path in the final netlist.
// =============================================================================
module clock_mux_static (
    input  wire sel,       // 0 -> clk0, 1 -> clk1
    input  wire clk0,
    input  wire clk1,
    output wire clk_out
);
    assign clk_out = sel ? clk1 : clk0;
endmodule
