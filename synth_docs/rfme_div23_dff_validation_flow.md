# RFME DIV2/DIV3 Autonomous Flow

This flow builds and runs a real-cell validation testbench for `2023_PLL/DIV_sub` from the `RFME` library.

## Key automation rule

Before launching Maestro, the testbench schematic must be explicitly checked and saved.

In the Virtuoso GUI, this is the same action as:

- `Shift+X`
- `Check and Save`

In the script, the equivalent is:

```skill
let((cv)
  cv = dbOpenCellViewByType("RFME" "DIV23_DFF_VALID_TB_..." "schematic" "schematic" "a")
  schCheck(cv)
  dbSave(cv))
```

If this step is skipped, ADE Assembler raises:

- `ASSEMBLER-9039`
- `Update and Run`
- `modified since their last extraction`

## Autonomous sequence

1. Create the RFME testbench schematic around `2023_PLL/DIV_sub`.
2. Set source parameters and load capacitance.
3. Create the Maestro `TRAN` test with the same model/view setup style as `2023_PLL/DIV_TB`.
4. Open the RFME testbench schematic in GUI mode and run `schCheck + dbSave`.
5. From Maestro, run an explicit pre-extraction/netlist step with `maeCreateNetlistForCorner("TRAN" "Nominal" ...)`.
6. Save setup and call `maeRunSimulation`.
7. Wait with `maeWaitUntilDone('All)`.
8. Export `IN`, `OUT`, `MOD_IN`, `RESETB`, and `MOD_OUT`.
9. Measure the pre-switch and post-switch divide ratio from exported waveforms.

## Current script

Script:

- [rfme_div23_dff_validation.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_div23_dff_validation.py)

Generated testbench style:

- DUT: `2023_PLL/DIV_sub`
- VDD: `1.1 V`
- `IN`: `10 ns` clock
- `RESETB`: released after startup
- `MOD_IN`: toggles during the transient
- `P`: tied high
- `OUT`: loaded with `20 fF`

## Run command

From the RFME folder:

```powershell
& C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe .\rfme_div23_dff_validation.py
```

## Why this matters

The important proof point is not just that Maestro can be opened remotely. The autonomous flow works only when the scripted launch treats both of these as pre-run steps:

- schematic-side `Shift+X` equivalent: `schCheck + dbSave`
- Maestro-side extraction refresh: `maeCreateNetlistForCorner(...)`
