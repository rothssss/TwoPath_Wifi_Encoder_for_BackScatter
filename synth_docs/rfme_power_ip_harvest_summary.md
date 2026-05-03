# RFME Power IP Harvest Summary

- target RFME library: `RFME`
- Virtuoso bridge profile: default
- Virtuoso display: `:96`

## Generated RFME Testbenches

### RFME_PWR_20260413_135835_LDO_TB

- role: `ldo`
- source IP: `2023_LDO/LDO_v3`
- source path: `/rdf/VLSI/Projects/HCL_neural_recording/180/2023_LDO`
- key outputs: `VOUT`
- bench notes: PWL VIN ramp to 2 V, both config buses tied low, 100 uA output load and 11 kohm shunt.

### RFME_PWR_20260413_135835_VMUL2_TB

- role: `voltage_multiplier_2x`
- source IP: `ME_System_2025/Local_voltage_doubler`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- key outputs: `VO`
- bench notes: Single 0.6 V input rail with VIN1 shorted to VIN, 10 MHz complementary clocks, 100 pF and 100 kohm output loading.

### RFME_PWR_20260413_135835_RECT_TB

- role: `rectifier`
- source IP: `ME_System_2025/Rectifier`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- key outputs: `VRECT, WDA, WDB`
- bench notes: Two 1 MHz opposite-phase 0.6 V sine drives, 10 nF reservoir cap, 10 kohm load.

### RFME_PWR_20260413_135835_ME_MODEL_TB

- role: `me_equivalent_model`
- source IP: `ME_MPPT_2023/ME_Model_3rd_order`
- source path: `/rdf/VLSI/Projects/Yiwei/ME_MPPT_proj/ME_MPPT_2023`
- key outputs: `BACK`
- bench notes: Single-ended 1 MHz, 50 mV sine excitation across VP/VN with a light BACK load.

### RFME_PWR_20260413_135835_VREF_TB

- role: `voltage_reference`
- source IP: `ME_System_2025/VREF_Gen_0P8`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- key outputs: `VREF_PRE, B0P8`
- bench notes: All trim buses held low, VDD/VLDO/BUFFER_SPLY tied together at 1.8 V, light 1 Mohm loads on both reference outputs.

### RFME_PWR_20260413_135835_IREF_TB

- role: `current_reference`
- source IP: `ME_System_2025/Current_reference`
- source path: `/rdf/VLSI/Projects/ME_Implant_2025/virtuoso/ME_System_2025`
- key outputs: `VPCMIRROR, VNCMIRROR`
- bench notes: 1.8 V supply, VPCMIRROR loaded to ground and VNCMIRROR loaded back to VDD through 100 kohm resistors.
