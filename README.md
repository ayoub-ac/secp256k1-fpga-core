# secp256k1-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![libsecp256k1 cross-validated](https://img.shields.io/badge/libsecp256k1-cross--validated-blue.svg)](#verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small, synthesisable secp256k1 ECDSA IP core in SystemVerilog.
Implements ANSI X9.62 / SEC 1 §4.1.3-4.1.4 sign and verify, plus
public-key derivation `Q = d*G`, with BIP-66 low-S canonicalisation on
the signing side. Targets iCE40, ECP5, Xilinx 7-series and UltraScale+,
Cyclone V, and Tang Nano (the latter at the edge of fitting).

The core is verified end-to-end against the SEC 1 §A.2.5 generator
doubling chain (privkey 1 -> G, privkey 2 -> 2G), 60 random
key-derivation pairs, 70 valid + 20 tampered ECDSA signatures, and 30
random sign tests with caller-supplied RFC 6979 nonces — all
cross-validated against Python `coincurve` (which wraps the canonical
[bitcoin-core/libsecp256k1](https://github.com/bitcoin-core/secp256k1)).
No FPGA hardware is required for the test suite.

## What secp256k1 is for

secp256k1 is the elliptic curve used by Bitcoin, Ethereum, Litecoin,
Bitcoin Cash, every Lightning Network node, every Bitcoin / Ethereum
hardware wallet (Ledger, Trezor, Coldcard, KeepKey, Foundation
Passport, Jade, Keystone, ...), Solana's non-Ed25519 signing paths,
and most major Layer-2 chains and bridges. It is also one of the
optional curves listed in TLS 1.3 (RFC 8446 §4.2.7), in JWS / JWA (RFC
7518 §3.4), and in the WebAuthn / FIDO2 attestation specifications.

ECDSA over secp256k1 is what produces the digital signature on every
on-chain Bitcoin transaction and every Ethereum transaction (until the
account-abstraction roll-out replaces some of them with native Schnorr
or BLS). A signing accelerator IP core unlocks throughput in custodial
signing appliances, exchange hot-wallet HSMs, hardware wallet ASICs,
on-prem wallet API services, and consensus-side validators that must
verify thousands of signatures per second.

## Difference from Ed25519

Ed25519 (Curve25519 in Edwards form, EdDSA signature scheme) is a
sister curve used by Solana, Cardano, Polkadot, SSH, and most modern
TLS deployments. The two are NOT interoperable:

| Aspect              | secp256k1 (this core)         | Ed25519                          |
|---------------------|-------------------------------|----------------------------------|
| Curve form          | Short Weierstrass `y^2 = x^3 + 7` | Edwards `-x^2 + y^2 = 1 + d*x^2*y^2` |
| Field size          | 256 bits (`p = 2^256 - 2^32 - 977`) | 255 bits (`p = 2^255 - 19`)    |
| Signature scheme    | ECDSA                         | EdDSA (Schnorr-family)           |
| Nonce               | Per-signature, must be unique  | Deterministic, derived from key + msg |
| Side-channel hardness | Caller's responsibility       | Built into the design (constant time) |
| Patents             | Free (post-2008)              | Free                             |
| Used by             | Bitcoin, Ethereum, all major blockchains | Solana, Cardano, SSH      |

Use this core for blockchain signing. Use the sibling
[ed25519-fpga-core](https://github.com/ayoub-ac/ed25519-fpga-core)
project for Ed25519 / EdDSA.

## Bitcoin compatibility note

For on-chain Bitcoin transaction signing, the (r, s) pair must be:
1. **Low-S form** (BIP-66): `s <= n/2`. The DUT enforces this on the
   SIGN side; `low_s_replaced_o` indicates whether replacement was
   applied.
2. **DER-encoded** (BIP-66 strict-DER): a small TLV wrapper around
   the (r, s) integers. This is **not** part of the RTL; perform
   DER encoding at the application layer before broadcasting.
3. **Low-r form** (Bitcoin Core policy since 0.17): `r < 2^255` for
   1-byte savings on the encoded signature. Re-sign with a different
   nonce if `r >= 2^255`. **Not** part of the RTL; handle at the
   application layer.

For Ethereum (EIP-155 / EIP-2 / EIP-2098), use the (r, s, v) triple
with the `v` recovery byte computed by inspecting `R.y mod 2`. The DUT
emits `(r, s)` only; the recovery byte must be derived externally from
the scalar-mult intermediate `R.y`. A future variant on the Premium
roadmap exposes `R.y` directly to support `v` derivation in hardware.

## Used in (alphabetical, real deployments)

| Product / standard                    | Use                            |
|---------------------------------------|--------------------------------|
| Bitcoin Core                          | All on-chain signatures        |
| Ethereum (until account abstraction)  | All on-chain signatures        |
| Lightning Network (BOLT 1-11)         | Channel updates, HTLCs         |
| Litecoin / Bitcoin Cash / Doge        | All on-chain signatures        |
| Solana (non-Ed25519 paths)            | Some validator paths           |
| Most Layer-2 rollups (Optimism, Arbitrum, Base) | Sequencer signatures   |
| Coinbase / Kraken / Binance custodial signing | Hot wallet signing       |
| Ledger / Trezor / Coldcard hardware wallets | All firmware signatures    |
| TCG TPM 2.0                           | Optional ECDSA curves          |
| TLS 1.3 (RFC 8446)                    | Optional EC curve              |

## Quickstart

```bash
git clone https://github.com/ayoub-ac/secp256k1-fpga-core.git
cd secp256k1-fpga-core
make lint test            # Verilator lint + run directed + 100+ random vectors
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth
flow. Python 3 with `coincurve` (the libsecp256k1 binding) for `make
regen_vectors`.

## Architecture

```
                            +-------------------------+
              start_i ---->|                         |
              mode_i  ---->|     secp256k1_top       |---> qx_o, qy_o (key derive)
              d_i     ---->|     (top-level FSM)     |---> r_o, s_o (sign)
              h_i     ---->|                         |---> accept_o (verify)
              k_i     ---->|     ready_o             |
              q*_i    ---->|     valid_o             |
              r_i,s_i ---->|                         |
                            +------------+------------+
                                         |
              +--------------------------+----------------------------+
              |                          |                            |
        ecdsa_sign                 ecdsa_verify                 scalar_mult
       (FSM: k*G,                 (FSM: s^-1, u1*G+u2*Q,        (k * P, ~1024 cycles
        k^-1, s = k^-1*(h+r*d),    affine sum, x' == r)          per call: 256 bit
        low-S)                                                   loop + Z^-1 inversion)
              |                          |                            |
              +-----------+--------------+----+--------+--------------+
                          |                   |        |
                  point_secp256k1     scalar_field   field_secp256k1
                  (Jacobian double,   (mod n: add,   (mod p: add, sub,
                   mixed Jacobian-     sub, mul,      mul, sqr; Solinas
                   affine add for      Barrett-style  reduction by
                   scalar-mult and     fold by c_n)   c = 2^32 + 977)
                   final affine sum)
```

Top-level FSM phases: `T_IDLE -> T_{KD,SG,VF} -> T_DONE -> T_IDLE`.
Each sub-engine internally sequences its own multi-step pipeline; only
one is active per session.

## Port table

| Signal              | Dir | Width | Description                                                                                         |
|---------------------|-----|-------|-----------------------------------------------------------------------------------------------------|
| `clk_i`             | in  | 1     | System clock.                                                                                       |
| `rst_ni`            | in  | 1     | Synchronous active-low reset.                                                                        |
| `start_i`           | in  | 1     | Pulse for one cycle to begin a session.                                                              |
| `mode_i`            | in  | 2     | 0=KEY_DERIVE, 1=SIGN, 2=VERIFY.                                                                       |
| `d_i`               | in  | 256   | Private key (KEY_DERIVE / SIGN).                                                                      |
| `h_i`               | in  | 256   | Message hash (SIGN / VERIFY).                                                                         |
| `k_i`               | in  | 256   | Per-signature nonce (SIGN). Caller MUST supply RFC 6979 deterministic or CSPRNG-derived nonce.        |
| `qx_i`, `qy_i`      | in  | 256   | Public key (VERIFY).                                                                                  |
| `r_i`, `s_i`        | in  | 256   | Signature (VERIFY).                                                                                   |
| `qx_o`, `qy_o`      | out | 256   | Public key (KEY_DERIVE).                                                                              |
| `r_o`, `s_o`        | out | 256   | Signature (SIGN; low-S form).                                                                         |
| `low_s_replaced_o`  | out | 1     | 1 if low-S replacement was applied (SIGN).                                                            |
| `accept_o`          | out | 1     | 1 if signature accepted (VERIFY).                                                                     |
| `err_o`             | out | 1     | 1 if SIGN failed (k=0 / k>=n / r=0 / s=0). Caller must retry with a fresh nonce.                      |
| `valid_o`           | out | 1     | Single-cycle pulse: outputs are valid for the just-completed session.                                 |
| `ready_o`           | out | 1     | Core can accept a new `start_i`.                                                                      |

Detailed handshake timing in [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md).

## Headline numbers

Real numbers from `make synth_report` (Yosys 0.x, top with all
sub-modules):

| Target           | LUT       | FF    | DSP / BRAM | Latency (per session)  | Notes                  |
|------------------|-----------|-------|------------|------------------------|------------------------|
| iCE40 UP5K       | see `SYNTH_REPORT.md` | ~3500 | 0 / 0      | ~1.0K (key) / ~1.6K (sign) / ~3.2K (verify)  | Tight fit; no DSP available |
| ECP5 LFE5UM-25   | see `SYNTH_REPORT.md` | ~3500 | 0 / 0      | same                   | abc9; nextpnr-ecp5 packs tighter than yosys-generic |
| Xilinx Artix-7   | see `SYNTH_REPORT.md` | ~3500 | 0 / 0      | same                   | Vivado infers DSP48E1; LUT count drops ~50% |

The 256-bit modular multipliers (one mod p, one mod n) dominate area
cost. The scalar-mult engine FSM and per-bit point ops contribute
~10-15%. Vendor flows (Vivado / Quartus) fold the partial-product trees
into DSP blocks and the gate count drops sharply; `synth_xilinx` shown
here uses the open generic mapping. See
[`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) for the full breakdown
and reduction options.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint            # static check the RTL
make test            # build and run test suite
                     # (directed key derive + 60 random key derive
                     #  + 90 verify (70 accept + 20 tampered)
                     #  + 30 sign + edge cases + malformed reject)
```

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

Three orthogonal techniques are wired into the testbench.

### Directed tests

| # | Test                                       | Coverage                                             |
|---|--------------------------------------------|------------------------------------------------------|
| 1 | SEC 1 §A.2.5 privkey 1 -> Q = G            | Generator point sanity                               |
| 2 | SEC 1 §A.2.5 privkey 2 -> Q = 2G           | First doubling on the curve                          |
| 3 | 60 cross-validated random `Q = d*G`        | `coincurve.PrivateKey().public_key`                  |
| 4 | 70 random ECDSA verify ACCEPT cases        | `coincurve.PublicKey().verify()`                     |
| 5 | 20 tampered (bit-flipped r/s) REJECT cases | Signature unforgeability under bit-flip              |
| 6 | 30 deterministic-nonce sign cases          | RFC 6979 nonce, output matches `coincurve.sign()`    |
| 7 | k = 0 / r = 0 / s = 0 / r >= n cases       | Range-check rejection logic                          |
| 8 | small-k sign smoke test (k = 5)            | FSM does not deadlock on boundary nonce              |

### SystemVerilog assertions

`tb/secp256k1_assertions.sv` enforces protocol invariants on every cycle
of every test:

- `valid_o` cannot pulse before any `start_i` has been seen.
- `ready_o` re-asserts within `LAT_MAX = 8192` cycles (catches a stuck
  FSM in the scalar-mult or inversion loop).
- `err_o = 1` implies `accept_o = 0` (sign-error and verify-accept are
  mutually exclusive).
- `valid_o` is at most one cycle high per session.
- `start_i` cannot be raised while `ready_o` is low.

The assertions compile with both Verilator 5.x (`--assert`) and Vivado
xsim. They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/secp256k1_cov.sv` collects 10 bins. The simulator prints a coverage
summary at end-of-test:

```
---- Functional coverage ----
  [HIT ] mode_key / mode_sign / mode_verify
  [HIT ] verify_accept / verify_reject
  [HIT ] sign_low_s / sign_err
  [HIT ] msg_zero / msg_high / nonce_small
Coverage: 10/10 bins (100.0%)
```

A regression that drops below 8/10 fails the gate.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL and
emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side
LUT/FF/BRAM table. Yosys (`synth_ice40` / `synth_ecp5` / `synth_xilinx`)
is mandatory; Vivado and Quartus are detected automatically and skipped
with a notice when not on `$PATH`.

## Variants

| Variant                                | Use case                                                                       | Tier   |
|----------------------------------------|--------------------------------------------------------------------------------|--------|
| `rtl/secp256k1_top.sv`                 | Default: key derive + sign + verify, single shared scalar-mult engine          | GPL    |
| `rtl/scalar_mult.sv`                   | k * P scalar multiplication only (no ECDSA wrappers)                            | GPL    |
| `rtl/field_secp256k1.sv`               | GF(p) modular arithmetic only                                                   | GPL    |
| `rtl/scalar_field.sv`                  | Mod-n scalar arithmetic only                                                    | GPL    |
| `vhdl_wrapper/secp256k1_top_vhdl.vhd`  | VHDL-2008 entity wrapping the SV core for VHDL-only designs                     | All    |

Premium tier (on roadmap, not yet shipped):
* RFC 6979 deterministic nonce derivation in hardware (HMAC-SHA-256
  loop). Eliminates the caller-side nonce-management burden.
* Pipelined modular multiplier (4-stage; ~3-5x throughput).
* Two-engine VERIFY top: u1*G and u2*Q computed in parallel
  (~1.7x area, -1400 cycles per verify).
* Fixed-base scalar mult for `k * G` (precomputed comb table; ~6x
  speedup on the SIGN path).
* Side-channel-hardened scalar mult: Montgomery ladder with randomised
  projective coordinates and randomised scalar splitting.
* Verify-only build (drops sign engine, ~30-40% area reduction).
* `(r, s, v)` output for Ethereum (recovery byte from `R.y`).

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product links
  this RTL or its compiled bitstream, your project must also be
  GPL-3.0+.
- **Commercial license** for closed-source products. See
  [`LICENSE.md`](LICENSE.md) for the legal text and an FAQ.

If unsure which applies, read `LICENSE.md` or open an issue.

## Repository layout

```
rtl/                       RTL sources
  field_secp256k1.sv         GF(p) modular arithmetic (Solinas reduction)
  scalar_field.sv            mod-n scalar-field arithmetic
  point_secp256k1.sv         Jacobian point ops (DBL, mixed-affine ADD)
  scalar_mult.sv             k * P scalar multiplication FSM
  ecdsa_sign.sv              ECDSA signing wrapper
  ecdsa_verify.sv            ECDSA verification wrapper
  secp256k1_top.sv           streaming top-level
tb/                        testbench
  sim_main.cpp               C++ harness, directed + 100+ random vectors
  secp256k1_top_tb.sv        DUT wrapper + assertion + coverage bind
  secp256k1_assertions.sv    SVA properties
  secp256k1_cov.sv           functional coverage collector
  bitcoin_vectors.sv         RFC 6979 / SEC 1 vectors (for non-Verilator simulators)
  random_vectors.h           generated cross-validation vectors
  gen_random_vectors.py      regenerator (uses `coincurve` lib)
vhdl_wrapper/              VHDL-2008 wrapper for mixed-language designs
scripts/                   helper scripts (synth_report.sh, vhdl_cosim.sh)
Makefile                   build/lint/sim/synth/synth_report/vhdl-test
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test` locally.
3. Open a pull request with a description of what changed and why.
4. CI runs the full test suite plus `synth_report`; both must be green.

## Citation

```bibtex
@misc{secp256k1-fpga-core,
  title  = {{secp256k1-fpga-core}: a small dual-licensed secp256k1 ECDSA IP core in SystemVerilog},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/secp256k1-fpga-core}}
}
```

## References

- ANSI X9.62-2005, *Public Key Cryptography for the Financial Services
  Industry: The Elliptic Curve Digital Signature Algorithm (ECDSA)*,
  American National Standards Institute, 2005.
- SEC 1: *Elliptic Curve Cryptography*, Version 2.0, Standards for
  Efficient Cryptography Group, Certicom Research, May 2009.
- SEC 2: *Recommended Elliptic Curve Domain Parameters*, Version 2.0,
  Standards for Efficient Cryptography Group, Certicom Research,
  January 2010 (defines secp256k1 in §2.4.1).
- IETF RFC 6979, *Deterministic Usage of the Digital Signature
  Algorithm (DSA) and Elliptic Curve Digital Signature Algorithm
  (ECDSA)*, T. Pornin, August 2013.
- BIP-66, *Strict DER signatures*, P. Wuille, January 2015.
- NIST FIPS 186-5, *Digital Signature Standard (DSS)*, February 2023.
- D. Hankerson, A. Menezes, S. Vanstone, *Guide to Elliptic Curve
  Cryptography*, Springer, 2004.
- Bitcoin Core libsecp256k1 source code,
  <https://github.com/bitcoin-core/secp256k1>.

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
