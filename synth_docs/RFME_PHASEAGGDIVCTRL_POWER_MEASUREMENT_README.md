# phaseaggdivctrl Power Measurement Flow

This note documents the final working power-measurement flow used for the
`phaseaggdivctrl` digital block on RFME session `:96`.

## Goal

Measure average supply current and average supply power for the current
single-lane low-activity `phaseaggdivctrl` implementation while operating at an
effective carrier of about `10 MHz`.

The two requested cases were:

- `40 MHz / 4 -> 10 MHz`
- `250 MHz / 25 -> 10 MHz`

## Final Working Method

The final flow does **not** rely on a long ADE interactive run. Instead it uses
Virtuoso only to build/export the bench, then runs Spectre X directly on the
exported netlist.

### 1. Generate a temporary testbench

The script
[run_phaseaggdivctrl_power_v96.py](C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_phaseaggdivctrl_power_v96.py)
creates a temporary schematic TB around `RFME/phaseaggdivctrl/symbol`.

The TB drives:

- `clk_if`
- `rst_n`
- `cfg_load`
- `tx_en`
- `lane_en`
- `mod_mode_req`
- `carrier_div_cfg`
- `symbol_div_cfg`
- `base_phase_cfg`
- `ext_bit`
- `ext_symbol`
- `drive_strength_cfg`
- `upper_phase_wave_in`
- `lower_phase_wave_in`

Important TB assumptions:

- `VDD = 1.2 V`
- transient stop time = `2 us`
- symbol divider used in the measurement run = `4`
- the DUT is treated as a **slow-domain** control block, so the upstream clock
  is assumed to be externally divided down before it matters to internal logic

### 2. Copy known-good Maestro setup settings

The script opens a known-good reference Maestro setup from:

- library: `2023_PLL`
- cell: `DIV_TB`
- test: `2023_PLL_DIV_TB_1`

It reuses:

- model files
- switch/stop view lists
- basic Spectre options (`temp`, `tnom`, `reltol`, `vabstol`, `iabstol`)

This avoided fighting stale/manual ADE setup details in the temporary TB.

### 3. Export a batch netlist through Virtuoso

The script launches a short remote batch Virtuoso job that calls
`maeCreateNetlistForCorner("TRAN" "Nominal" ...)`.

This produces a standalone export directory under `/tmp`, for example:

- `/tmp/TB_PHASEAGGDIVCTRL_PWR_fc40_div4_20260424_010508_20260424_010514_netlist`

The actual Spectre working directory is:

- `<export_root>/netlist`

## Key Fixes Required

Several issues had to be fixed before the flow became reliable.

### A. Stale jobs had to be canceled

Old `TB_PHASEAGGDIVCTRL_PWR` jobs and related logging services were still alive
on the server and had to be killed before rerunning.

### B. The generated TB initially shorted sources together

The original helper placed multiple scalar sources at the same coordinates,
which caused overlapping nets and incorrect netlists.

The final script fixes this by placing the scalar sources at distinct locations.

### C. The little export metadata file was flaky

The sidecar `.txt` file written during export sometimes lagged or came back
empty even though the export itself succeeded.

The final script therefore treats the expected remote export directory as the
authoritative `netlist_dir`, and only uses the `.txt` file as optional metadata.

### D. Saving all public signals was too heavy

The initial flow saved too much waveform data.

The final script patches the exported `input.scs` before simulation:

- changes `saveOptions options save=allpub`
- to `saveOptions options save=selected currents=selected`
- appends `save VDD0:p`

That keeps the PSF small and makes the run much more reliable.

## Final Spectre Run

After export, the script runs Spectre X directly from the exported netlist
directory with a low-accuracy fast preset and multithreading:

```text
spectre -64 input.scs +escchars +log spectre.out -format psfxl -raw ./psf +preset=vx +mt=8 -maxw 5 -maxn 5
```

Why this was chosen:

- `Spectre X`
- `+preset=vx` for the lowest-accuracy / fastest preset
- `+mt=8` for multithreading
- only one current branch saved

The run is considered successful only if `spectre.out` contains:

```text
spectre completes with 0 errors
```

## Measurement Extraction

After Spectre finishes, the script opens the transient results and measures the
average supply current through the supply source branch:

```skill
openResults("<results_dir>")
selectResults("tran")
avgI = average(clip(i("VDD0:p") 5e-07 2e-6))
avgP = abs(avgI) * 1.2 * 1e6
```

Notes:

- the current is measured on `VDD0:p`
- the averaging window is `0.5 us` to `2.0 us`
- power is reported in `uW`
- the raw current sign is negative because of Spectre source-current convention
  for the supply source, so power is reported using `abs(avgI)`

## Final Measured Results

From
[C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_phaseaggdivctrl_power_v96_summary.txt](C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_phaseaggdivctrl_power_v96_summary.txt):

### Case 1: `40 MHz / 4 -> 10 MHz`

- average current = `-2.745520e-05 A`
- average current magnitude = `27.4552 uA`
- average power = `32.94624 uW`

### Case 2: `250 MHz / 25 -> 10 MHz`

- average current = `-2.902741e-05 A`
- average current magnitude = `29.02741 uA`
- average power = `34.83289 uW`

## Interpretation

The two power numbers are close.

That is expected for the current RTL partition, because this version of
`phaseaggdivctrl` is a **slow-domain** controller. Most of the block activity is
set by the divided effective operating point near `10 MHz`, not by the original
`40 MHz` versus `250 MHz` upstream source.

So this measurement is mainly telling us:

- the exported/simulated digital control block power at the divided operating
  point
- not the full upstream divider or multiphase front-end power

## Files

- driver script:
  [run_phaseaggdivctrl_power_v96.py](C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_phaseaggdivctrl_power_v96.py)
- summary:
  [\_tmp_phaseaggdivctrl_power_v96_summary.txt](C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_phaseaggdivctrl_power_v96_summary.txt)
- raw JSON:
  [\_tmp_phaseaggdivctrl_power_v96.json](C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_phaseaggdivctrl_power_v96.json)

