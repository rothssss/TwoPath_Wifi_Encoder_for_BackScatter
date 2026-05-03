# RFME Context-Window Verilog Server Flow

This README is for future context windows working on the RFME digital flow. It explains how to:

- use the real RFME server paths
- clone or create `verilog/` and `synth/` module folders on the server
- keep the Verilog formatting/style consistent with the current RFME digital blocks
- preserve the "low activity" design style the project is using

Use this when a future context window needs to make a new RTL block, push it to the server, and set up a synth folder correctly without inventing paths or drifting away from the established formatting.

## 1. Source Of Truth

Always use the real RFME server tree:

- Verilog root:
  - `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth root:
  - `/rdf/VLSI/Projects/Naveed/RFME/synth`

Do not invent alternate trees such as:

- `~/projects/naveed/rfme/...`
- ad-hoc scratch paths
- fake mirrored project roots

If a file is meant to be used by Virtuoso or DC, the real server path above is the source of truth.

## 2. Session Rule

Always note which Virtuoso bridge session/profile is being used for the task, for example:

- `V23`
- `V95`
- `:23`

Important distinction:

- If the task is only copying or editing server-side text files under `/rdf/VLSI/Projects/Naveed/RFME/...`, the file tree is the source of truth and the bridge session matters only for coordination.
- If the task also touches live OA cells, symbols, schematics, or layouts, explicitly use the intended bridge session/profile and mention it in notes or scripts.

For future context windows:

- do not assume the default bridge profile is correct
- do not assume the currently open Virtuoso session is the one the user wants
- state the chosen session in the work log or comments before making bridge-driven OA edits

## 3. Local Mirror Convention

Keep a local mirror in this workspace before pushing to the server:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v`
- optionally:
  - `C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth\<module>\<module>.v`

The local mirror is for editing and record-keeping. The remote `/rdf/...` copy is what Virtuoso/DC actually uses.

Important:

- a full local synth mirror is optional
- do not assume the local synth folder contains the server `Makefile` or TCL
- for synth setup, read and edit the real remote synth folder unless a full local mirror was intentionally created

## 4. Naming Rules

Use strict one-to-one naming:

- folder name = module name
- Verilog filename = module name + `.v`
- top module name = folder name = filename stem

Example:

- folder: `resistiveqamhrr`
- file: `resistiveqamhrr.v`
- top module: `module resistiveqamhrr ( ... );`

Avoid:

- wrapper names that differ from folder names
- helper-core split unless absolutely necessary
- stale names copied from earlier experiments

Flat single-module files are preferred unless the user explicitly asks otherwise.

## 5. Low-Activity Verilog Style

The current RFME digital direction favors low-activity, synthesis-friendly RTL.

Future context windows should preserve these principles:

- keep the module flat if possible
- prefer simple register-based `posedge clk_if` logic
- avoid embedding scan chain storage inside the active control block unless the user explicitly wants it there
- expose config bits as external inputs when possible so config/storage power can be accounted for separately
- avoid large dynamic LUT memories when a small fixed mapping or algorithmic mapping is enough
- minimize always-toggling decode logic
- avoid unnecessary combinational fanout or heavy helper pipelines
- keep comments short and only where they help

Formatting should match the project style:

- include `` `timescale 1ns/1ps ``
- align port declarations cleanly
- keep constants grouped near the top
- use straightforward signal names
- prefer one clear top module over wrapper/core hierarchies

Reference style:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\resistiveqamhrr\resistiveqamhrr.v`

## 6. Creating A New Verilog Module

Assume the new module name is `<module>`.

### Step 1: Create local folder

Create:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\`

Put the flat Verilog file there:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v`

### Step 2: Create remote verilog folder

Example command:

```powershell
ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>"
```

### Step 3: Copy the Verilog file to the server

Example command:

```powershell
scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v" `
    opus-vb:/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v
```

### Step 4: Verify the copy

Use one or more of:

```powershell
ssh opus-vb "ls -l /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>"
ssh opus-vb "sed -n '1,40p' /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v"
```

Check:

- file exists
- top module name matches `<module>`
- no accidental wrapper name remains
- no truncated copy occurred

## 7. Creating The Synth Folder Correctly

Always clone from the real blank template on the server:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/blankexample`

Do not invent a synth folder from scratch unless the user specifically asks you to.

### Step 1: Clone blankexample

```powershell
ssh opus-vb "cp -r /rdf/VLSI/Projects/Naveed/RFME/synth/blankexample /rdf/VLSI/Projects/Naveed/RFME/synth/<module>"
```

### Step 2: Rename the TCL

Many past mistakes happened here. Fix it immediately.

```powershell
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/<module> && if [ -f clocking.tcl ]; then mv clocking.tcl <module>.tcl; fi"
```

### Step 3: Retarget the Makefile and TCL

The server synth folder should point at:

- top module: `<module>`
- Verilog source:
  - `../../verilog/<module>/<module>.v`

At minimum, verify and update:

- `TOP_LEVEL=<module>`
- TCL filename references
- `read_verilog "../../verilog/<module>/<module>.v"`
- clock port name if needed, usually `clk_if`

Check the folder contents first:

```powershell
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/<module> && ls -l"
```

Then inspect:

```powershell
ssh opus-vb "sed -n '1,200p' /rdf/VLSI/Projects/Naveed/RFME/synth/<module>/Makefile"
ssh opus-vb "sed -n '1,200p' /rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.tcl"
```

## 8. Typical Retargeting Edits

The exact template may vary, but the intent should be:

- make `make syn` synthesize `<module>`
- read the Verilog file from the real server `verilog/<module>/`
- use the correct clock port name

Common fields to verify:

- top-level module name
- verilog path
- current TCL filename
- output file prefix
- clock port
- clock name

If the design uses:

- `clk_if`
- active-low async reset `rst_n`

then preserve that naming unless the user explicitly wants a rename.

## 9. Verification Before Synthesis

Before telling the user the module is ready, verify:

```powershell
ssh opus-vb "test -f /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v && echo VERILOG_OK"
ssh opus-vb "test -f /rdf/VLSI/Projects/Naveed/RFME/synth/<module>/Makefile && echo MAKEFILE_OK"
ssh opus-vb "test -f /rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.tcl && echo TCL_OK"
ssh opus-vb "grep -n \"module <module>\" /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v"
ssh opus-vb "grep -n \"../../verilog/<module>/<module>.v\" /rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.tcl"
```

If desired, compare hashes:

```powershell
Get-FileHash "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v" -Algorithm SHA256
ssh opus-vb "sha256sum /rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v"
```

## 10. Running Synthesis

Once the remote synth folder is correct:

```powershell
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/<module> && make syn"
```

If the user wants to run synthesis manually, stop after verification and tell them the remote paths are ready.

Do not claim synthesis is ready unless:

- Verilog file is present remotely
- `Makefile` is retargeted
- TCL is retargeted
- top module name matches the file and folder name

## 11. Common Mistakes To Avoid

These are the mistakes that future context windows should actively avoid:

- using fake project roots instead of `/rdf/VLSI/Projects/Naveed/RFME/...`
- forgetting to state or respect the intended Virtuoso session/profile
- creating mismatched names between folder, file, and module
- copying an older wrapper/core hierarchy when a flat file is preferred
- leaving stale module names inside the file
- assuming the local synth folder contains the server `Makefile`
- forgetting to clone from `blankexample`
- forgetting to rename `clocking.tcl`
- forgetting to retarget `read_verilog`
- pushing a file but not verifying the remote contents

## 12. Recommended Short Workflow

For a future context window, the recommended sequence is:

1. Confirm the intended bridge session/profile if OA edits are involved.
2. Create or update the local flat Verilog file in:
   - `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v`
3. Create the remote verilog folder under:
   - `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>`
4. Copy the Verilog file to the server.
5. Clone:
   - `/rdf/VLSI/Projects/Naveed/RFME/synth/blankexample`
   into:
   - `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>`
6. Rename `clocking.tcl` to `<module>.tcl`.
7. Retarget `Makefile` and `<module>.tcl`.
8. Verify the remote files and names.
9. Only then run `make syn`, or hand off to the user.

## 13. Use This README Together With

If a future context window needs bridge specifics too, also read:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_ACCESS_README.md`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_VERILOG_SYNTH_DEPLOY_README.md`

This file is the short "do it correctly next time" guide focused on:

- real server paths
- session awareness
- low-activity flat RTL formatting
- correct `verilog/` and `synth/` folder creation flow
