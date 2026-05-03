# RFME Bridge Waveform And Verilog-A Playbook

This is the short practical playbook for the workflows that actually worked reliably in the recent `testingtopdig` / `ideal4096` bring-up through the Virtuoso bridge on `:96`.

## Goal

Use the bridge for:
- pulling waveform data directly from Maestro PSF
- checking controller outputs and symbol alignment
- updating live Verilog-A in OA safely

Avoid:
- giant one-shot waveform exports
- giant one-shot Verilog-A writes
- relying on the Maestro browser to already expose the signal you need

## Session Pattern

Use the direct bridge client:

```python
from virtuoso_bridge import VirtuosoClient
client = VirtuosoClient.local(host="opus.ece.rice.edu", port=5950, timeout=120)
```

Use the bridge for:
- OA edits
- `ocnPrint` waveform export
- reading remote temporary CSVs back
- updating `veriloga` text views

Use SSH or remote path knowledge only for:
- knowing where the Maestro PSF lives
- sanity-checking remote files if needed

## Waveform Extraction

### Best method

Do **not** wait for PSF browser outputs to be complete. Probe the net yourself by name with:
- `openResults(...)`
- `selectResult('tran)`
- `ocnPrint(...)`

The reliable extraction scripts are:
- [extract_latest_testingtopdig_square16_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/extract_latest_testingtopdig_square16_v96.py)
- [extract_and_compare_testingtopdig_pex_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/extract_and_compare_testingtopdig_pex_v96.py)
- [extract_and_compare_testingtopdig_reextract_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/extract_and_compare_testingtopdig_reextract_v96.py)

### PSF path style

Typical remote PSF paths we used successfully:

```text
/data01/VLSI/Users/Naveed/RFME/RFME/testingtopdig/maestro/results/maestro/Interactive.X/1/RFME_testingtopdig_1/psf
/data01/VLSI/Users/Naveed/RFME/RFME/testingtopdig/maestro/results/maestro/Interactive.X/psf/RFME_testingtopdig_1
```

### Export strategy

Export in chunks, not all at once.

Good working defaults:
- RF chunk: about `0.2 us`
- control chunk: about `1.0 us`
- RF step: around `75 ps`
- control step: around `1 ns`

Typical bridge-side pattern:

```skill
progn(
  openResults("/data01/.../psf")
  selectResult('tran)
  ocnPrint(?output "/tmp/rf_chunk.csv" ?separator "," ?from 5e-7 ?to 7e-7 ?step 75p v("RF"))
  t
)
```

Then read the file back immediately through the bridge.

### Why this worked

This avoided:
- huge bridge payloads
- Maestro UI dependencies
- hanging on missing browser outputs

Instead, we exported exactly the nets we cared about and stitched them locally.

## Symbol Recovery And Comparison

### Best method

Do not judge the run from the raw RF waveform alone.

Always export:
- RF node
- Verilog/controller outputs

Then recover everything locally in Python:
- slot boundaries
- controller one-hot validity
- PRBS alignment
- symbol groups
- desired/image coefficients
- EVM, IRR, HRR

### Why this mattered

This let us distinguish:
- controller/digital errors
- analog/parasitic bank errors
- alignment mistakes

The scripts above already implement this pattern and write:
- `*_summary.txt`
- `*_constellation_points.csv`
- `*_state_extract.csv`
- `*_ctrl_check.txt`

### Comparison hierarchy

When scoring a new run, compare against:
1. ideal LUT target
2. prior no-PEX baseline
3. prior PEX run

This is how we determined whether a change was:
- common-mode only
- truly improving IRR
- truly improving EVM
- mostly digital alignment noise

## Verilog-A Update

### Best method

Generate the `.va` locally, then push it into the OA `veriloga` view in small batches.

The working push scripts are:
- [push_ideal4096_currentpex_square_qam16_bestirr_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/push_ideal4096_currentpex_square_qam16_bestirr_v96.py)
- [push_ideal4096_square_qam16_16phase_bestirr_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/push_ideal4096_square_qam16_16phase_bestirr_v96.py)
- [push_ideal4096_exportingtheimageless_v96.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/push_ideal4096_exportingtheimageless_v96.py)

### Safe update sequence

1. Build the local source file.
2. Open or create the live `veriloga` cellview.
3. Back up the remote text file.
4. Write the new file in small line batches.
5. Read back the first few lines to verify.
6. Reopen or recompile in Virtuoso if needed.

### Remote file used

Typical live file:

```text
/rdf/VLSI/Projects/Naveed/RFME/virtuoso/RFME/ideal4096/veriloga/veriloga.va
```

### Why this worked

Small batches were much safer than one giant bridge write.

Writing about `8` lines per bridge call worked reliably.

## Recommended Workflow

### For extracted performance evaluation

1. Identify newest `Interactive.X` PSF path.
2. Export RF in chunks with `ocnPrint`.
3. Export relevant controller nets in chunks.
4. Stitch locally.
5. Recover symbol timing from controller outputs.
6. Compute EVM/IRR/HRR locally.
7. Compare to prior no-PEX and prior PEX results.

### For changing the modulation model

1. Rebuild LUT locally.
2. Generate local Verilog-A.
3. Push Verilog-A in small batches to live OA.
4. Recompile/reload.
5. Rerun Maestro.
6. Re-extract with the same waveform pipeline.

## Things That Caused Trouble

- Giant one-shot bridge writes to `veriloga`
- Giant one-shot waveform exports
- Depending on PSF browser outputs being present
- Mixing analog diagnosis with controller alignment errors
- Updating analog bank and LUT at the same time without re-extracting

## Short Version

- **Waveforms:** bridge + chunked `ocnPrint`
- **Scoring:** local Python from exported RF + control nets
- **Verilog-A:** generate locally, push remotely in small batches, always back up first
- **Best scripts to reuse:** the three extraction scripts and the `push_ideal4096_*_v96.py` push scripts listed above
