# Security model

This document describes what `secp256k1_top` is designed to defend
against, what it is NOT designed to defend against, and how to evaluate
the claims.

If you need a side-channel-resistant ECDSA signing core for a
commercial hardware wallet, an HSM, or a custodial signing appliance,
read this whole document and decide whether the threat model matches
your deployment. Don't trust marketing copy; trust the threat model and
your own evaluation.

## ECDSA nonce reuse is CATASTROPHIC — read this first

ECDSA signing requires a per-signature nonce `k` chosen uniformly at
random from `[1, n-1]` AND kept secret AND never reused for two
different messages under the same private key. Reusing the same `k`
twice with two different messages allows immediate, trivial recovery of
the private key:

```
s1 = k^-1 * (h1 + r * d) mod n
s2 = k^-1 * (h2 + r * d) mod n
=>  k = (h1 - h2) * (s1 - s2)^-1 mod n
=>  d = (s1 * k - h1) * r^-1 mod n
```

This is not a theoretical attack: it is how the Sony PS3 ECDSA private
key was extracted in 2010, how a reused nonce in early
Android `SecureRandom` leaked Bitcoin wallet keys in 2013, and how
multiple production smart-contract deployments have been compromised
since.

**This core does NOT generate the nonce internally.** The caller must
supply `k` via the `k_i` port. The CALLER is responsible for ensuring:

1. **Uniqueness**: each sign call gets a fresh `k` that has never been
   used with the same `d` before. The standard solution is RFC 6979 §3.2
   deterministic nonce derivation:
   ```
   k = HMAC_DRBG(d, h, "secp256k1") truncated to [1, n-1]
   ```
   which is a function of `(d, h)` and is provably unique per message.
2. **Secrecy**: `k` must be unknown to any attacker. A single bit of
   `k` leaked through a side channel has been shown to suffice for
   practical key-recovery attacks (Genkin et al., "Sliding right into
   disaster", CHES 2017; Aldaya et al., "Port contention for fun and
   profit", S&P 2019).
3. **Range**: `k` in `[1, n-1]`. The DUT is designed to enforce this
   with an early-out `err_o = 1` when `k = 0` or `k >= n` (unverified). The caller must NOT silently
   retry with the same `k` value; on `err_o`, derive a fresh `k` and
   re-sign.

Reference for safe nonce derivation: IETF RFC 6979, "Deterministic
Usage of the Digital Signature Algorithm (DSA) and Elliptic Curve
Digital Signature Algorithm (ECDSA)", T. Pornin, August 2013. The
companion `gen_random_vectors.py` script implements RFC 6979 in Python
and generates test vectors for the testbench; results not independently confirmed.

## What is intended to be protected (not verified)

### 1. Signature mathematical correctness

The DUT implements the ANSI X9.62 / SEC 1 §4.1.3-4.1.4 ECDSA algorithm
(not validated):

* **Sign**: `(R.x, R.y) = k * G; r = R.x mod n; s = k^-1 * (h + r*d) mod n`,
  followed by BIP-66 low-S canonicalisation (`s' = n - s` if `s > n/2`).
  Output (r, s) is intended to be byte-for-byte identical to
  libsecp256k1 / coincurve for the same (d, h, k) inputs. 30 test
  vectors derived from libsecp256k1 are included in
  `tb/random_vectors.h`; results not independently confirmed.
* **Verify**: full SEC 1 §4.1.4 procedure including range checks
  `0 < r < n` and `0 < s < n`. The DUT is designed to reject malformed
  signatures (r=0, s=0, r>=n, s>=n) at the protocol level. 90 test
  vectors derived from libsecp256k1 (70 valid + 20 tampered) are
  included; results not independently confirmed.
* **Key derive**: `Q = d * G` for any `d in [1, n-1]`. 60 test vectors
  derived from libsecp256k1 are included; results not independently confirmed.

### 2. Bitcoin / BIP-66 canonical form

`ecdsa_sign` post-processes `s` per BIP-66:

```
if s > n/2:  s = n - s
```

This is what Bitcoin Core requires for on-chain transaction
signatures. The output flag `low_s_replaced_o` indicates whether the
replacement was applied (so the caller can record it for audit).

The DUT does NOT enforce Bitcoin's "low-r" canonicalisation extension
(re-signing with a different `k` if `r >= 2^255`). That is outside the
scope of a stateless ECDSA primitive; the caller must implement
re-signing on retry if low-r is required.

### 3. Bounded session latency

The internal FSMs (scalar mult, modular inversion, ECDSA sign / verify)
are intended to be bounded; SVA assertions are intended to fail the test
if a session runs past its latency bound (not independently confirmed).
The expected maximum per-session cycle count is ~3200 cycles (verify
with full affine sum; unverified estimate); see `RESOURCE_ESTIMATES.md`.

## What is NOT covered (be honest)

This list is deliberately exhaustive so users can evaluate fit:

- **Differential power analysis (DPA / CPA)** on the scalar-mult engine,
  the modular multiplier, or the inversion accumulator: working state
  is unmasked. A power attacker measuring leakage at the FF boundary
  during a sign operation can mount standard CPA on intermediate
  values, with `k` and `d` as the recovery target. Mitigation requires
  randomised scalar splitting (Coron 1999), masked field arithmetic
  (e.g., affine coordinate randomisation per Itoh-Izu-Takenaka, CHES
  2002), and / or randomised projective coordinates per Hankerson-
  Menezes-Vanstone §5.3. **None of these is implemented.**
- **Electromagnetic (EM) analysis** and **template attacks**: not
  specifically countered. There is no power balancing, no differential
  routing, no constant-Hamming-weight encoding.
- **Fault injection** on the scalar-mult bit loop, the inversion
  accumulator, or the FSM state register: a flipped bit in the bit
  loop can leak `d` (Biehl-Meyer-Müller, "Differential fault attacks
  on elliptic curve cryptosystems", CRYPTO 2000). No duplicated
  counter / parity-protected register variant is implemented.
- **Constant-time scalar multiplication**: the per-bit DBL+ADD pattern
  is structurally fixed but the conditional commit of the ADD result
  is gated on the scalar bit, which is a known-leaky pattern at the
  register-write level. A timing attacker measuring per-cycle current
  can distinguish bit positions where ADD was committed vs not. No
  Montgomery-ladder variant is included in this repository.
- **Cache / micro-architectural side channels**: not applicable (this
  is RTL, not software). However, if you place this core into a
  multi-tenant SoC with a shared bus, those channels can leak through
  the surrounding fabric.
- **Nonce malleability**: ECDSA signatures with the same (r, s) value
  are valid; the verifier accepts both s and n-s. We mitigate this on
  the SIGN side via BIP-66 low-S form, but a third-party signature
  with high-S is still accepted on VERIFY (the SEC 1 standard requires
  acceptance of high-S signatures; only Bitcoin's transaction-level
  policy rejects them, which is enforced by the wallet, not the
  signature primitive).
- **Replay protection**: not in scope. The caller must include a
  monotonic counter / nonce in `h` (the message hash) if replay must
  be prevented. This is a protocol-layer concern.
- **Invasive attacks** (decap, microprobing) are entirely out of scope.

If your deployment threat model includes any of the above and the rest
of your system relies on integrity, this core is not enough on its
own.

## Compliance claims

- **SEC 1 §4.1.3-4.1.4 conformance**: not validated. The core
  implements the SEC 1 ECDSA algorithm over secp256k1 with arbitrary
  256-bit message hashes (not validated). Test vectors derived from
  libsecp256k1 (via Python `coincurve`) are included; results not independently confirmed.
- **BIP-66 canonical signature form**: not validated. Low-S
  canonicalisation is intended to be applied on the SIGN side. The DER encoding step (BIP-66 strict-DER) is out of scope and
  must be applied by the caller before broadcasting on-chain.
- **RFC 6979 deterministic nonce**: NOT implemented in hardware. The
  DUT is parameterised on a caller-supplied nonce. The companion
  Python script `tb/gen_random_vectors.py` implements RFC 6979 and
  generates test vectors derived from libsecp256k1's deterministic
  signatures; results not independently confirmed. Production deployments
  should run the RFC 6979 derivation in either software or in a
  dedicated HMAC-SHA-256 IP (the sibling
  [sha256-fpga-core](https://github.com/ayoub-ac/sha256-fpga-core)
  includes an HMAC-SHA-256 primitive; it is also unverified).
- **NIST CAVP test certificate**: NOT obtained. CAVP validation
  requires a NIST-accredited testing lab. Test vectors derived from
  libsecp256k1 are included; results not independently confirmed. This is not a
  substitute for CAVP validation.
- **FIPS 186-5 conformance**: not validated. The core implements the
  FIPS 186-5 §6.4 ECDSA algorithm over secp256k1 (not validated).
  Whether secp256k1 is an approved curve for a given FIPS use is not
  established here. Achieving an actual FIPS-140-3
  certificate requires a full module evaluation including
  side-channel and tamper response — not part of this product.
- **Common Criteria**: not evaluated.
- **CMVP / FIPS 140-3 module suitability**: this core implements one
  of the cryptographic primitives a FIPS module would use (ECDSA
  signing / verification), but the entropy source for `k`, the
  RBG / DRBG, the secure-boot integration, and the key-management
  protocol are all out of scope and must be implemented by the
  integrator.

## Test methodology used to validate the security claims

The Verilator testbenches contain the checks below. The checks are
included; results not independently confirmed.

1. **Functional correctness on directed vectors**: privkey = 1 -> Q = G,
   privkey = 2 -> 2G (SEC 1 §A.2.5 generator doubling chain). The
   testbench includes these as `dut_key_derive` smoke tests.
2. **Test vectors derived from libsecp256k1 (via `coincurve`)**: 60
   random key-derivation tests, 70 valid-signature verify tests, 30
   random sign tests with a caller-supplied RFC 6979 nonce. The harness
   is written to require a byte-for-byte match.
3. **Tampered-signature rejection**: 20 random verify tests with a
   bit flipped in `r` or `s`; the DUT must return `accept_o = 0`.
4. **Malformed-signature rejection**: directed tests for `r = 0`,
   `s = 0`, and `r = n` (boundary). The DUT must return `accept_o = 0`
   immediately, without running the scalar mult.
5. **Edge-case nonce / hash**: directed test for `k = 0` (must error),
   small nonce `k = 5` (must succeed; signature is mathematically valid
   but trivially key-recoverable in practice — the test only verifies
   the FSM does not deadlock for boundary `k`).
6. **SVA protocol checks intended to run on every cycle**: see
   `tb/secp256k1_assertions.sv`. Properties include:
   - `valid_o` cannot pulse before any `start_i` has been seen.
   - The session finishes within a generous latency bound (8192 cycles)
     to catch a stuck FSM.
   - `err_o` and `accept_o` are mutually exclusive.
   - `valid_o` is at most one cycle high per session.
   - `start_i` cannot be raised while `ready_o` is low (integrator
     misuse detector).
7. **Functional coverage**: 10 bins (key / sign / verify modes,
   verify-accept / verify-reject, sign-low-S / sign-err, msg-zero /
   msg-high, nonce-small). Coverage report printed at end of
   `make test`.

We do NOT run experimental DPA / CPA against a real bitstream. Any
side-channel property described here is **design intent** only; not
evaluated. An experimentally verified claim would require an FPGA, an
oscilloscope, and a trace-collection campaign measured in days or
weeks; none has been done.

## How to use the core safely

1. **Generate `k` per RFC 6979 §3.2.** Do NOT use a software RNG that
   has not been entropy-seeded since boot. Do NOT use `rand()` or any
   non-cryptographic PRNG.
2. **Hold `rst_ni` low for at least 4 cycles** after power-on and
   before the first command.
3. **Wipe `d_i`, `k_i`, intermediate registers** after a sign
   operation completes. The wrapper does not do this automatically;
   the working-state registers retain post-op state until the next
   `start_i`. Drive zeros into the input ports between sessions if
   you cannot trust the surrounding fabric.
4. **Apply low-S canonicalisation if your downstream protocol
   requires it.** The DUT enforces this on the SIGN side; if you
   accept signatures from external sources and need to reject high-S
   variants (Bitcoin policy), filter them at the application layer.
5. **Verify the DER encoding before broadcasting on-chain.** BIP-66
   strict-DER encoding is out of scope for this RTL primitive.
6. The core is not a substitute for protocol-level measures like
   transaction-replay protection, key rotation, or secure-erase. Wrap
   it in a real wallet / HSM stack.

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with SEC 1 /
RFC 6979 / libsecp256k1? Open a GitHub issue; do not post confidential
details in it. Coordinated disclosure welcome. We do not currently offer a
bug bounty.
