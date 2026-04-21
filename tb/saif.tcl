# =============================================================================
# saif.tcl : dump an SAIF activity file for every signal inside the DUT
# across the whole TB run.  Feed the resulting activity.saif into Joules
# (Cadence) or PrimePower (Synopsys) for dynamic-power estimation.
#
# Usage:
#   xrun -sv -access +rwc -f tb/filelist.f \
#        -top tb_multi_mode_tx_baseband \
#        -input tb/saif.tcl
# =============================================================================

# Open an SAIF database that will capture every toggle while the sim runs.
database -open -saif saifdb -into activity.saif -default

# Probe everything under the DUT instance recursively.  `-depth all` walks
# hierarchy; `-all` includes every net/reg/port at each level.
probe -create -saif -database saifdb tb_multi_mode_tx_baseband.dut \
      -all -depth all

# Run the whole testbench.  The initial block in the TB ends with $finish,
# which closes the database automatically, but we call it explicitly for
# clarity.
run
database -close saifdb
exit
