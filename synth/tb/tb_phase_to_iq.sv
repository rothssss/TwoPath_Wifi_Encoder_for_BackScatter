// =============================================================================
// tb_phase_to_iq : exhaustive truth-table check of phase_to_iq.
//
// Expected mapping (Gray QPSK, see rtl/common/phase_to_iq.v header):
//   phase  | chip_i | chip_q
//   00     |   1    |   1
//   01     |   0    |   1
//   11     |   0    |   0
//   10     |   1    |   0
// =============================================================================
`timescale 1ns/1ps

module tb_phase_to_iq;

    reg  [1:0] phase;
    wire       chip_i;
    wire       chip_q;

    phase_to_iq dut (.phase(phase), .chip_i(chip_i), .chip_q(chip_q));

    integer fails = 0;
    integer total = 0;

    task automatic chk(input [1:0] p, input exp_i, input exp_q);
        begin
            total = total + 1;
            phase = p;
            #1;
            if (chip_i === exp_i && chip_q === exp_q) begin
                $display("  [PASS] phase=%02b  got (i,q)=(%0b,%0b)  exp=(%0b,%0b)",
                         p, chip_i, chip_q, exp_i, exp_q);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] phase=%02b  got (i,q)=(%0b,%0b)  exp=(%0b,%0b)",
                         p, chip_i, chip_q, exp_i, exp_q);
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_phase_to_iq : Gray QPSK phase truth table");
        $display("============================================================");
        chk(2'b00, 1'b1, 1'b1);
        chk(2'b01, 1'b0, 1'b1);
        chk(2'b11, 1'b0, 1'b0);
        chk(2'b10, 1'b1, 1'b0);
        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
