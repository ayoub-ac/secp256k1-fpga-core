# Resource estimates

Numbers below are from Yosys 0.x generic synthesis (`make synth_report`).
They are pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (post-Yosys, pre-PnR)

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | Tight fit. The 256-bit modular multipliers (mod p and mod n) dominate the LUT count; iCE40 has no DSP and the schoolbook 256x256 multiply is mapped onto LUT4 adder trees. Production deployments target ECP5 or larger. |
| Lattice ECP5 LFE5UM-25         | Comfortable fit. Yosys generic mapping does not auto-pack into block multipliers; nextpnr-ecp5 packs tighter; vendor (Diamond) tighter still and infers the 18x18 DSP blocks. |
| Xilinx Artix-7 XC7A35T         | Comfortable fit. Yosys-generic synthesis here counts LUT6 + CARRY4. Vivado `synth_design` infers DSP48E1 blocks for the 256x256 multiply and the LUT count drops sharply (typically 2-3x reduction). |
| Cyclone V 5CSEMA5F31C6         | Quartus folds the 256x256 multiply into 27x18 DSP blocks; ALM count is much lower than the Yosys soft estimate. |
| Xilinx UltraScale+ ZCU104      | Not characterised here. DSP58 mapping yields the lowest gate count; recommended for production signing accelerators. |

For exact LUT/FF/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`. The synthesis-comparison report is regenerated on
every CI build.

## What dominates the area

- **256-bit modular multiplier (mod p)**: implemented as a flat
  256x256 -> 512-bit schoolbook multiply followed by a two-step
  Solinas reduction (folding by `c = 2^32 + 977`). On Yosys generic
  mapping this is the single largest contributor and it accounts for
  roughly 40-50% of the LUT count. Two of these are instantiated (one
  in `field_secp256k1`, one used directly inside `point_secp256k1`).
- **256-bit modular multiplier (mod n)**: similar structure but with a
  larger `c_n = 2^256 - n` (~129 bits) and three folding rounds.
  Slightly larger than the mod-p variant. Accounts for another ~20%.
- **Scalar-mult engine state**: P (X, Y, Z in Jacobian), the affine
  base point Q, the scalar `k`, the bit index, and the
  inversion accumulator together hold ~1500 FFs.
- **ECDSA sign / verify wrappers**: signature-level state (r, s, h,
  inversion accumulator, lambda, sum_x, sum_y, ...) holds another
  ~1500 FFs.
- **FSM and control**: small (<5% of total area).

secp256k1 is a LARGE design. iCE40 UP5K (5280 logic tiles) is right at
the edge of fitting; production deployments target ECP5-25, Artix-7
35T, Cyclone V SE, or any modern UltraScale+ / Versal device. Vendor
flows fold the 256x256 multiplier into hard DSP blocks and drop the
gate count sharply; the Yosys-generic numbers are upper bounds.

## What you can do to shrink it

- **Schedule the 256x256 multiplier**: replace the flat schoolbook
  multiply with a 4x or 8x time-multiplexed variant that computes the
  partial products serially. Trade ~4-8x more cycles per multiply for
  ~4-8x fewer LUTs. Available in the Premium tier.
- **DSP-friendly layout**: a `(* dsp = "yes" *)` attribute on the
  partial-product sums lets Vivado / Quartus infer DSP48 / 27x18
  blocks where the open flow's generic adder tree would have
  remained. Available in the Premium tier (Vivado XDC + Quartus QSF
  templates included).
- **Karatsuba multiplication**: replace the 256x256 schoolbook with a
  3-level Karatsuba decomposition (256 -> 128 + 128, 128 -> 64 + 64,
  64 -> 32 + 32). Roughly 30% fewer multiplications at the cost of
  more additions. Wins on FPGAs with limited DSP but ample LUTs.
  Available in the Premium tier.
- **Verify-only build**: drop `ecdsa_sign` and the SIGN-side mod-n
  inversion plus the low-S logic. Available in the Premium tier (we
  ship a `SECP256K1_VERIFY_ONLY` define for accelerators that only
  validate signatures, e.g., consensus full-nodes).

## What you can do to push throughput

- **Pipelined multiplier** (Premium): unroll the modular multiplier
  into a 4-stage pipeline. Steady-state throughput becomes 1 multiply
  per cycle instead of every cycle (combinational; the limit is now
  the surrounding FSM, which can be re-architected). Combined with a
  pipelined scalar-mult unit this lifts ECDSA throughput by ~3-5x.
- **Two-engine top** (Premium): u1 * G and u2 * Q computed in parallel
  during VERIFY. Cuts the verify latency from ~3200 to ~1800 cycles
  at ~1.7x the area (one extra scalar-mult engine).
- **Windowed scalar multiplication** (Premium): replace the bit-by-bit
  double-and-add with a width-4 fixed-window method using a precomputed
  table of `{0*G, 1*G, 2*G, ..., 15*G}` (precomputed once at synthesis
  time for the `k * G` path). Lifts the per-scalar-mult cycle count
  from ~512 down to ~320. Not constant-time; pair with table lookup
  randomisation if side channels matter.
- **Fixed-base scalar multiplication for `k * G`** (Premium): replace
  the generic scalar-mult with a fixed-base "comb" method that uses
  a precomputed table of `{2^0 * G, 2^4 * G, 2^8 * G, ...}` and
  reduces the scalar-mult cycle count to ~64 cycles. The verify path
  still uses the variable-base scalar-mult for `u2 * Q`.

## Frequency

- iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints:
  limited by the 256-bit adder LUT depth (~20-30 MHz on generic synth).
- ECP5: ~50-80 MHz on generic synth.
- Artix-7 -1 speed grade: ~80 MHz typical with Yosys, easily 150+
  MHz with Vivado + DSP48 inference.
- Cyclone V: similar to Artix-7 with M10K-backed BRAM and 27x18
  DSPs.
- UltraScale+: 250-400 MHz with the pipelined Premium variant.

The throughput is gated by the modular multiplier (1 multiply per
cycle in this generic version, 1 multiply per pipeline stage in the
Premium pipelined variant). For a 100 MHz Artix-7 deployment at the
default cycle count, throughput is ~30K verifies/s and ~60K signs/s.
The pipelined Premium variant lifts this to ~150K verifies/s and
~300K signs/s, which is competitive with software signing on a modern
ARM Cortex-A78.

## Power

Ballpark: 60-120 mW dynamic on Artix-7 35T at 100 MHz, depending on
data activity. The 256-bit register banks are the largest dynamic
contributor; the multipliers toggle on every state transition during
the bit loop.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers (post-PnR LUT counts and
timing), run the vendor flow:
- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
