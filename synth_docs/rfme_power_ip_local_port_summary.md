# RFME Power IP Local Port Summary

- target RFME library: `RFME`
- Virtuoso bridge profile: default
- Virtuoso display: `:96`

## Imported Editable Cells

### RFME_EDIT_20260413_143253_LDO_EA

- role: `ldo_error_amp`
- source IP: `ME_System_2025/Two_stage_EA_fully_diff_input`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- copied views: `schematic, symbol, layout`
- notes: Error amplifier used by the editable local LDO copy.

### RFME_EDIT_20260413_143253_LDO

- role: `ldo`
- source IP: `ME_System_2025/LDO_offchip_cap`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- copied views: `schematic, symbol, layout`
- notes: Editable local LDO choice with a small dependency chain.

### RFME_EDIT_20260413_143253_VMUL2

- role: `voltage_multiplier_2x`
- source IP: `ME_System_2025/Local_voltage_doubler`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- copied views: `schematic, symbol`
- notes: Standalone 2x local voltage doubler.

### RFME_EDIT_20260413_143253_RECT

- role: `rectifier`
- source IP: `ME_MPPT_2023/Bulk_adaptation_rectifier`
- source path: `/rdf/VLSI/Projects/Yiwei/ME_MPPT_proj/ME_MPPT_2023`
- copied views: `schematic, symbol`
- notes: Editable 2 V-only bulk-adaptation rectifier.

### RFME_EDIT_20260413_143253_ME_MODEL

- role: `me_equivalent_model`
- source IP: `ME_MPPT_2023/ME_Model_3rd_order`
- source path: `/rdf/VLSI/Projects/Yiwei/ME_MPPT_proj/ME_MPPT_2023`
- copied views: `schematic, symbol`
- notes: Standalone ME equivalent circuit model.

### RFME_EDIT_20260413_143253_BIAS_REF

- role: `bias_reference`
- source IP: `Photoacoustic_power/Current_ref`
- source path: `/rdf/VLSI/Projects/Photoacoustic_power/virtuoso/Photoacoustic_power`
- copied views: `schematic, symbol, layout`
- notes: Editable 2 V-only bias/reference block; use VBN as voltage reference and IREF0 as current reference.

## Local RFME Testbenches

### RFME_EDIT_20260413_143253_LDO_TB

- role: `ldo`
- DUT: `RFME/RFME_EDIT_20260413_143253_LDO`
- key outputs: `VLDO`
- notes: Local editable LDO bench using fixed VDD, VREF, and VBN biases with light RC loading.

### RFME_EDIT_20260413_143253_VMUL2_TB

- role: `voltage_multiplier_2x`
- DUT: `RFME/RFME_EDIT_20260413_143253_VMUL2`
- key outputs: `VO`
- notes: Local editable 2x doubler bench with complementary clocks and light output loading.

### RFME_EDIT_20260413_143253_RECT_TB

- role: `rectifier`
- DUT: `RFME/RFME_EDIT_20260413_143253_RECT`
- key outputs: `VRECT`
- notes: Local editable 2 V-only rectifier bench with MODE forced high and differential sine drive.

### RFME_EDIT_20260413_143253_ME_MODEL_TB

- role: `me_equivalent_model`
- DUT: `RFME/RFME_EDIT_20260413_143253_ME_MODEL`
- key outputs: `BACK`
- notes: Local editable ME model bench with small-signal sine excitation.

### RFME_EDIT_20260413_143253_VREF_TB

- role: `voltage_reference`
- DUT: `RFME/RFME_EDIT_20260413_143253_BIAS_REF`
- key outputs: `VBN`
- notes: Local editable 2 V-only bias-voltage bench using the VBN output of the imported bias/reference block.

### RFME_EDIT_20260413_143253_IREF_TB

- role: `current_reference`
- DUT: `RFME/RFME_EDIT_20260413_143253_BIAS_REF`
- key outputs: `IREF0, VBN`
- notes: Local editable 2 V-only current-reference bench using the IREF0 output of the imported bias/reference block.
