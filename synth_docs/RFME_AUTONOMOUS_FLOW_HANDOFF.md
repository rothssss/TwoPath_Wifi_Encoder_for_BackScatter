# RFME Autonomous Flow Handoff

This note is a handoff for the next context window. It summarizes the setup work, code changes, current autonomous Cadence flow, and the remaining blocker.

## 1. High-level status

There are three major workstreams completed or in progress:

1. Verilog-A driver bugfix:
   - A fixed copy of the RDAC driver was created.
2. Virtuoso bridge setup on Rice `opus`:
   - Local Windows machine can talk to the remote Virtuoso CIW through `virtuoso-bridge-lite`.
   - Spectre access was also fixed.
3. Real-cell divider validation flow:
   - A real RFME testbench was created around `2023_PLL/DIV_sub`.
   - Automation exists to create the cell, create Maestro, and attempt a transient run.
   - The remaining issue is the ADE `Update and Run` / `ASSEMBLER-9039` extraction dialog.

## 2. Files created or modified

### In RFME workspace

- [ssb256_8phase_rdac_driver_quantfix.va](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/ssb256_8phase_rdac_driver_quantfix.va)
  - Renamed fixed copy of the original Verilog-A driver.
  - Module name changed to `ssb256_8phase_rdac_driver_quantfix`.
  - Quantizer bug fixed:
    - `tap_idx = tap_real + 0.5;` changed to `tap_idx = tap_real;`
  - Large hex integer literals replaced with decimal/signed-decimal values for parser compatibility.

- [rfme_div23_dff_validation.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_div23_dff_validation.py)
  - Main automation script for the real-cell divider validation flow.
  - Builds a testbench around `2023_PLL/DIV_sub`.
  - Creates a Maestro `TRAN` setup.
  - Attempts the pre-run schematic and extraction steps automatically.
  - Exports waveforms and analyzes divide ratio when the run succeeds.

- [rfme_div23_dff_validation_flow.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_div23_dff_validation_flow.md)
  - Short focused note about the autonomous divider flow.
  - Documents the idea that schematic `Shift+X` plus Maestro pre-extraction must be part of the scripted flow.

### In local `virtuoso-bridge-lite` checkout

- [cli.py](/C:/Users/nav/Documents/virtuoso-bridge-lite/src/virtuoso_bridge/cli.py)
  - Patched earlier so `virtuoso-bridge status` can correctly detect Spectre on Windows without CRLF-induced csh issues.

### Local config files

- [C:\Users\nav\.virtuoso-bridge\.env](/C:/Users/nav/.virtuoso-bridge/.env)
- [C:\Users\nav\.ssh\config](/C:/Users/nav/.ssh/config)

## 3. Virtuoso bridge setup that now works

### Current SSH / bridge target

- Remote host alias: `opus-vb`
- Actual Cadence server: `opus.ece.rice.edu`
- Remote user: `na73`

### Current bridge env

The local env file is:

- [C:\Users\nav\.virtuoso-bridge\.env](/C:/Users/nav/.virtuoso-bridge/.env)

It was configured to point to:

- `VB_REMOTE_HOST=opus-vb`
- `VB_REMOTE_USER=na73`
- `VB_REMOTE_PORT=65081`
- `VB_LOCAL_PORT=65082`
- `VB_REMOTE_SCRATCH_ROOT=/home/na73/.cache`
- `VB_CADENCE_CSHRC=/home/na73/.virtuoso_bridge_cadence.csh`

### Remote Spectre wrapper created on `opus`

- `/home/na73/.virtuoso_bridge_cadence.csh`

Purpose:

- `~/all.setup` is bash-style and could not be sourced by the bridge’s csh-based Spectre probe.
- The wrapper reproduces the Cadence/Spectre path and environment in csh syntax.

### Verified bridge state

The bridge was successfully brought to:

- tunnel running
- daemon connected to Virtuoso CIW
- Spectre found

At one point `virtuoso-bridge status` reported:

- `[daemon] OK`
- `[spectre] OK`

### Important practical note

The user still launches Virtuoso through VNC on `opus`. The bridge does not replace VNC. It just allows Python/SSH control of that already-running Virtuoso session.

## 4. Local repo exploration results used in the flow

The GitHub repo explored was:

- [Arcadia-1/virtuoso-bridge-lite](https://github.com/Arcadia-1/virtuoso-bridge-lite)

Key findings that matter for future work:

- `client.schematic.edit(...)` already does `schCheck + dbSave` on exit.
- Maestro simulation should run in GUI mode, not only background `maeOpenSetup`.
- Bridge docs explicitly warn:
  - schematic must be checked and saved before simulation
  - GUI dialogs block the SKILL channel
- The repo also includes `dismiss_dialog()` and an X11 dialog helper, but on this Windows/Rice setup it behaved unreliably.

## 5. Real divider / DFF design context discovered in Virtuoso

The user said the standard-cell library is:

- `tcb018gbwp7t_YAN`

What was found:

- `2023_PLL/DIV_sub` is the smallest practical real-cell divide-2/divide-3 block to validate.
- `2023_PLL/DIV_sub` uses real standard cells from `tcb018gbwp7t_YAN`, especially:
  - `DFCND1BWP7T`
  - plus combinational standard cells like `INVD1BWP7T`, `AN2D1BWP7T`

Relevant cell terminals for `2023_PLL/DIV_sub`:

- `RESETB`
- `OUT`
- `IN`
- `MOD_IN`
- `VSS`
- `VDD`
- `MOD_OUT`
- `P`

This is why the autonomous flow targets `2023_PLL/DIV_sub`, not a made-up behavioral divider.

## 6. Existing divider testbench that was inspected

An existing Cadence testbench already present in Virtuoso was found:

- `2023_PLL/DIV_TB`

That testbench was used as the reference source for:

- model file setup
- switch view list
- stop view list
- basic simulator options

This made it possible to create a new RFME-side testbench without inventing the PDK setup from scratch.

## 7. The generated RFME divider validation testbench

The automation created or targeted this RFME testbench cell:

- `RFME/DIV23_DFF_VALID_TB_20260412_020607`

What the script wires:

- DUT: `2023_PLL/DIV_sub`
- `VVDD`: `vdc = 1.1`
- `VVSS`: `vdc = 0`
- `VP`: ties `P` high at `1.1 V`
- `VCLK`: `vpulse`, `10 ns` period, `5 ns` pulse width
- `VRST`: `vpulse`, reset release after startup
- `VMOD`: `vpulse`, toggles `MOD_IN` during transient
- `CLOAD`: `20 fF` on `OUT`

Waveforms intended for export:

- `/IN`
- `/OUT`
- `/MOD_IN`
- `/RESETB`
- `/MOD_OUT`

Analysis target:

- measure `OUT` period before and after `MOD_IN` switches
- estimate whether the block is dividing by 2 in one region and 3 in the other

## 8. Current autonomous-run theory

The current working theory is:

The run must do all of these before `maeRunSimulation`:

1. Build or update the schematic.
2. Explicitly `schCheck + dbSave` the testbench schematic.
3. Open Maestro in GUI/edit mode.
4. Save Maestro setup.
5. Explicitly force a pre-extraction / pre-netlist step:
   - `maeCreateNetlistForCorner("TRAN" "Nominal" "...")`
6. Only then call `maeRunSimulation`.

Why:

- The user pointed out that the popup is not a timeout issue.
- The modal says:
  - `ASSEMBLER-9039`
  - modified since last extraction
  - click `Update and Run`
- That means ADE believes its extracted state is stale even after ordinary check/save.

## 9. Remaining blocker

### What still happens

The flow still gets stuck on:

- `ADE Assembler Update and Run`
- `ERROR (ASSEMBLER-9039)`
- `modified since their last extraction`

Specifically:

- test-associated cellview:
  - `RFME/DIV23_DFF_VALID_TB_20260412_020607/schematic`

### What this means

This is now understood much better than before:

- It is not a random socket timeout.
- It is not simply lack of `schCheck + dbSave`.
- It is an ADE extraction-state freshness issue.

### Why the automation did not finish

Attempts to auto-dismiss the popup were unreliable because:

- once the modal appears, CIW/SKILL can block
- the bridge’s X11 dismissal helper uses SSH and helper upload paths that were flaky on this setup
- at times even plain SSH to `opus` became intermittent from the local PowerShell side

So the current gap is not the testbench construction. The gap is making the extraction-refresh step happen without provoking the modal.

## 10. Good next actions for the next context

The next context should not start from scratch. The right continuation is:

1. Use [rfme_div23_dff_validation.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_div23_dff_validation.py) as the base script.
2. Focus only on solving the extraction-refresh step before run.
3. Prefer a real ADE or Maestro extraction/netlisting API call over popup dismissal.
4. Test on the already-created RFME cell:
   - `RFME/DIV23_DFF_VALID_TB_20260412_020607`
5. Once `maeRunSimulation` succeeds without `ASSEMBLER-9039`, use the existing export/analyze path already in the script.

Specific hypotheses worth testing next:

- whether `maeCreateNetlistForCorner("TRAN" "Nominal" ...)` must be run after GUI Maestro is open and editable, not just after save
- whether the test name or corner context must be reselected before extraction
- whether an `asi*` or `sev*` extraction/netlist call is the real equivalent of `Update and Run`
- whether the testbench schematic must remain the active GUI window when the extraction happens

## 11. Commands the next context can use

### Run the divider validation script

```powershell
& C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_div23_dff_validation.py
```

### Current short flow note

- [rfme_div23_dff_validation_flow.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_div23_dff_validation_flow.md)

## 12. User-facing state at handoff

At the end of this work:

- `RFME/rfpa` schematic and maestro windows were reopened after earlier disruption.
- The divider validation cell exists.
- The automation script exists.
- The bridge setup is usable.
- The unresolved problem is the ADE extraction popup before run.

That is the correct place for the next context to continue.
