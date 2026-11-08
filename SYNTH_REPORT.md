# Synthesis comparison report

Unverified: this file is not CI output and its numbers have not been
independently reproduced. Regenerate it locally with `make synth_report`.
Numbers are post-synthesis, pre-place-and-route.
Vendor flows (Vivado / Quartus) usually pack tighter than the open-source flow,
so the Yosys numbers should be read as upper bounds.

| Toolchain                | Target                  | Result                       |
|--------------------------|-------------------------|------------------------------|
| Yosys 0.x synth_ice40    | iCE40 UP5K              | (timed out: 25 min cap; design too large for iCE40 UP5K) |
| Yosys 0.x synth_ecp5     | ECP5 LFE5UM-25          | (timed out: 25 min cap; rerun with `YOSYS_TIMEOUT=7200`) |
| Yosys 0.x synth_xilinx   | Xilinx 7-series         | 560943 LUT / 22974 FF / 18722 DSP48E1 |
| Vivado synth_design      | Artix-7 xc7a35tcsg324-1 | (skipped: vivado not on PATH)|
| Quartus Pro              | Cyclone V 5CSEMA5F31C6  | (skipped: quartus_sh not on PATH)|

## Notes

* The dominant area is the 256x256 -> 512-bit modular multiplier
  (`field_secp256k1.sv` and `scalar_field.sv`). On Yosys generic
  Xilinx mapping the partial-product tree fans out across 18722 DSP48E1
  blocks; the Artix-7 35T part has only 90 DSP48E1, so this design
  WILL NOT FIT on a -35T part. No device has been confirmed to fit;
  larger parts such as Kintex-7 / -UltraScale, Zynq-7100, or
  UltraScale+ / Versal devices with DSP58 blocks would be needed.
* The 22974 FF count is dominated by the 256-bit working registers in
  the scalar-mult engine (P, Q, accumulator, inversion accumulator),
  the ECDSA signing / verification state (r, s, h, lambda, sum_x,
  sum_y, ...), and the FSM control. For a single-engine variant the
  FF cost is fairly constant; variants that add pipelining or a second
  engine (not implemented) would add to this.
* The iCE40 / ECP5 generic synth flows on this design are reported to
  run for over an hour each on a developer laptop (unverified) because
  the 256x256 schoolbook multiplier expands to a deep adder tree under
  Yosys's `abc` pass. We cap each at 25 minutes by default; rerun with
  `YOSYS_TIMEOUT=7200 make synth_report` to get the full numbers.
  This core is not expected to fit on iCE40 (the LUT
  count exceeds the UP5K's 5280 logic tiles by ~100x).
* secp256k1 is a LARGE design. The Yosys-generic Xilinx number above
  (560k LUTs) is an upper bound that vendor flows reduce sharply.
  Vivado's `synth_design` packs the 18.7k inferred DSP48E1 blocks
  into proper hard-macro instances and folds the LUT count by an
  estimated 5-10x; a Vivado run is expected to land in the 50-80k LUT
  range on a 35T-like part (unverified estimate; still requiring a
  larger part to fit).

## Reproduction

```
make synth_report
```

If the iCE40 / ECP5 generic flows time out on your machine,
re-run with a longer cap:

```
YOSYS_TIMEOUT=7200 make synth_report
```

Raw logs land in `synth_report/`.
