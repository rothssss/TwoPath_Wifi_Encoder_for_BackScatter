// =============================================================================
// tb_phy_a_rotator : Path A QPSK rotator checks.
//
// Behaviour (see rtl/path_a/phy_a_rotator.v):
//   phi1_acc resets to 0 on start_pulse.
//   phi1_next = phi1_acc + delta_phi1 (2-bit wrap).
//   phi1_eff  = update_phi1 ? phi1_next : phi1_acc   (lookahead).
//   chip_phase = base_phase + phi1_eff  (2-bit wrap).
//   chip_i/chip_q are REGISTERED (1-cycle latency) via phase_to_iq mapping:
//     00->(1,1)  01->(0,1)  10->(1,0)  11->(0,0)
//
// Test plan:
//   T1 start_pulse zeroes phi1, base_phase=00 delta=00 update=1 -> chip=(1,1).
//   T2 base=00 delta=01 update=1 -> chip_phase=01 -> chip=(0,1).
//   T3 next cycle without update: phase still 01 -> chip=(0,1).
//   T4 Accumulate another +01 -> phase 10 -> chip=(1,0).
//   T5 Accumulate +10 -> phase 10+10=00 (wrap) -> chip=(1,1).
//   T6 chip_valid tracks valid_chip with 1-cycle latency.
// =============================================================================
`timescale 1ns/1ps

module tb_phy_a_rotator;

    reg         clk         = 1'b0;
    reg         rst_n       = 1'b0;
    reg         start_pulse = 1'b0;
    reg  [1:0]  base_phase  = 2'd0;
    reg  [1:0]  delta_phi1  = 2'd0;
    reg         update_phi1 = 1'b0;
    reg         valid_chip  = 1'b0;

    wire        chip_i;
    wire        chip_q;
    wire        chip_valid;

    phy_a_rotator dut (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse),
        .base_phase(base_phase),
        .delta_phi1(delta_phi1),
        .update_phi1(update_phi1),
        .valid_chip(valid_chip),
        .chip_i(chip_i), .chip_q(chip_q),
        .chip_valid(chip_valid)
    );

    always #5 clk = ~clk;

    integer total = 0;
    integer fails = 0;

    task automatic chk_eq_iq(input [255:0] label, input exp_i, input exp_q);
        begin
            total = total + 1;
            if (chip_i === exp_i && chip_q === exp_q) begin
                $display("  [PASS] %0s  got=(%0b,%0b) exp=(%0b,%0b)",
                         label, chip_i, chip_q, exp_i, exp_q);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] %0s  got=(%0b,%0b) exp=(%0b,%0b)",
                         label, chip_i, chip_q, exp_i, exp_q);
            end
        end
    endtask

    task automatic chk(input [255:0] label, input bit cond);
        begin
            total = total + 1;
            if (cond) $display("  [PASS] %0s", label);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s", label);
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_phy_a_rotator : phi1 accumulator + phase-to-IQ");
        $display("============================================================");

        // Reset
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // T1: start_pulse clears phi1_acc; feed delta=00 update=1 valid=1.
        @(posedge clk); #1;
        start_pulse = 1'b1;
        base_phase  = 2'b00;
        delta_phi1  = 2'b00;
        update_phi1 = 1'b1;
        valid_chip  = 1'b1;
        @(posedge clk); #1;
        start_pulse = 1'b0;
        update_phi1 = 1'b0;
        // Outputs are registered: inputs at the edge just passed -> chip_i/q now show phase (00+00)=00
        chk_eq_iq("T1 phase=00 -> (1,1)", 1'b1, 1'b1);
        chk("T1 chip_valid=1", chip_valid === 1'b1);

        // T2: base=00, delta=01, update=1, valid=1.  phi1_next = 01, phase = 01.
        @(posedge clk); #1;
        base_phase  = 2'b00;
        delta_phi1  = 2'b01;
        update_phi1 = 1'b1;
        valid_chip  = 1'b1;
        @(posedge clk); #1;
        update_phi1 = 1'b0;
        chk_eq_iq("T2 phase=01 -> (0,1)", 1'b0, 1'b1);

        // T3: no update -> phi1_acc=01 stays, phase=01.
        @(posedge clk); #1;
        chk_eq_iq("T3 phase=01 held -> (0,1)", 1'b0, 1'b1);

        // T4: update=1 delta=01 -> phi1_acc 01+01=10, phase=10.
        @(posedge clk); #1;
        base_phase  = 2'b00;
        delta_phi1  = 2'b01;
        update_phi1 = 1'b1;
        valid_chip  = 1'b1;
        @(posedge clk); #1;
        update_phi1 = 1'b0;
        chk_eq_iq("T4 phase=10 -> (1,0)", 1'b1, 1'b0);

        // T5: update=1 delta=10 -> phi1_acc 10+10=00 wrap, phase=00.
        @(posedge clk); #1;
        base_phase  = 2'b00;
        delta_phi1  = 2'b10;
        update_phi1 = 1'b1;
        valid_chip  = 1'b1;
        @(posedge clk); #1;
        update_phi1 = 1'b0;
        chk_eq_iq("T5 phase=00 (wrap) -> (1,1)", 1'b1, 1'b1);

        // T6: drop valid_chip and expect chip_valid to go low on next cycle.
        @(posedge clk); #1;
        valid_chip = 1'b0;
        @(posedge clk); #1;
        chk("T6 chip_valid=0 when valid_chip=0", chip_valid === 1'b0);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #200_000;
        $display("[TB-FATAL] phy_a_rotator timeout");
        $fatal(1, "timeout");
    end

endmodule
