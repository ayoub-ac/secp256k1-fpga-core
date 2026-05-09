# Port description

Detailed handshake protocol and timing for `secp256k1_top`.

## Reset

`rst_ni` is **synchronous active-low**. Hold it low for at least 4
clock cycles before the first command. After de-assertion, the core is
in `T_IDLE` with `ready_o = 1`.

```
clk_i      __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
rst_ni     ‾‾‾‾‾‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾
ready_o           X X X X X X X X X X X X X 1 1 1 1 1 1
```

## Session start

A new ECDSA operation is initiated by pulsing `start_i` for one cycle
together with `mode_i` and the per-mode inputs.

```
clk_i               |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
ready_o             ‾‾‾|___________________________________
start_i             ___|‾‾|_____________________________________
mode_i              ___|valid|___________________________________
inputs              ___|valid|___________________________________
                    (compute ~1024-3200 cycles)
valid_o             _________________________________________|‾‾|_
outputs             _________________________________________|valid|_
ready_o             _____________________________________________|‾‾‾
```

`ready_o` is high when the core can accept a new `start_i`, which
includes both `T_IDLE` (post-reset / post-clean) and `T_DONE` (after a
prior session has finalised). Driving `start_i` while `ready_o = 0`
is ignored.

## Mode select (`mode_i[1:0]`)

| Encoding | Mode        | Inputs used                  | Outputs              |
|----------|-------------|------------------------------|----------------------|
| `2'b00`  | KEY_DERIVE  | `d_i`                        | `qx_o`, `qy_o`       |
| `2'b01`  | SIGN        | `d_i`, `h_i`, `k_i`          | `r_o`, `s_o`, `low_s_replaced_o`, `err_o` |
| `2'b10`  | VERIFY      | `qx_i`, `qy_i`, `h_i`, `r_i`, `s_i` | `accept_o`     |

Unused inputs are ignored and may be driven to any value.

## Latency

| Mode       | Cycles (typical) | Notes                                       |
|------------|------------------|---------------------------------------------|
| KEY_DERIVE | ~1024            | One scalar multiplication + final inversion |
| SIGN       | ~1600            | One scalar mult + one mod-n inverse + muls  |
| VERIFY     | ~3200            | Two scalar mults + mod-n inverse + affine sum |

Worst-case bounds are enforced by the SVA `p_ready_eventually` property
at 8192 cycles; if a session ever runs past that, the testbench
fails the gate.

## Endianness

All 256-bit byte-stream ports use **big-endian** byte ordering: byte 0
of every byte string is in `[255:248]`. This matches:
* The byte order used by `coincurve` and the underlying libsecp256k1.
* Bitcoin Core's serialised transaction signature wire format.
* The OpenSSL EC point compression / uncompression format.
* The standard hex-string representation in every wallet (Trezor /
  Ledger / Coldcard suites all expect `qx[0]` = byte 0 of the X
  coordinate at the most-significant position).

Concretely:

* `d_i[255:248]` is byte 0 of the private key (the first byte of the
  big-endian 32-byte serialisation).
* `qx_i[7:0]` and `qy_i[7:0]` are the **last** byte of X and Y
  respectively (because `[7:0]` is the LSByte of a big-endian bus).
* `h_i[255:248]` is byte 0 of the message hash.
* `r_i[255:248]` is byte 0 of the signature `r` value.

## Output validity

`valid_o` is a single-cycle pulse that indicates the outputs reflect
the just-completed session. After the `valid_o` pulse, the outputs
remain stable in their session-end state until the next `start_i`
pulse latches new inputs.

`ready_o` re-asserts on the cycle after `valid_o` (the FSM transitions
from `T_DONE` to `T_IDLE`).

## Error semantics (SIGN mode)

`err_o = 1` together with `valid_o = 1` indicates that the SIGN
operation failed and the caller MUST retry with a fresh nonce `k_i`.
Conditions that trigger `err_o`:

* `k_i = 0` (zero nonce; mathematically illegal).
* `k_i >= n` (nonce out of range).
* The computed `r = R.x mod n` came out as 0 (statistically vanishingly
  rare; ~1 in 2^256).
* The computed `s` came out as 0 (similarly rare).

In all other SIGN cases, `err_o = 0` and `(r_o, s_o)` is a valid
signature. `low_s_replaced_o = 1` indicates that the canonical low-S
form was applied (the raw `s` was greater than `n/2` and was replaced
by `n - s`).

## Acceptance semantics (VERIFY mode)

`accept_o = 1` together with `valid_o = 1` indicates that the supplied
signature `(r_i, s_i)` is valid for the public key `(qx_i, qy_i)` and
the message hash `h_i` per SEC 1 §4.1.4. `accept_o = 0` indicates
rejection, which can be caused by any of:

* `r_i = 0` or `s_i = 0` or `r_i >= n` or `s_i >= n` (range check).
* The reconstructed point `R' = u1 * G + u2 * Q` is the point at
  infinity.
* `R'.x mod n != r_i` (signature does not match).

The DUT does NOT distinguish between these failure modes; all are
reported as `accept_o = 0`. If you need fine-grained error reporting,
filter the malformed-signature cases at the application layer before
calling the DUT.

## Public-key validity (VERIFY mode)

The DUT does NOT check that `(qx_i, qy_i)` is a valid point on the
curve. The caller must validate the public key per SEC 1 §3.2.2.1
before invoking VERIFY:

1. `qx, qy in [0, p-1]`.
2. `qy^2 == qx^3 + 7 mod p` (point-on-curve check).
3. `n * Q != O` (sub-group check; for secp256k1 the cofactor is 1, so
   any on-curve point automatically satisfies this).

A malformed public key will produce undefined behaviour (the verify
result is mathematically meaningless; the FSM still terminates and
outputs `accept_o = 0` in all observed cases, but no formal guarantee
is offered).

## Signal table

| Signal              | Dir | Width | Description                                         |
|---------------------|-----|-------|-----------------------------------------------------|
| `clk_i`             | in  | 1     | System clock.                                       |
| `rst_ni`            | in  | 1     | Synchronous active-low reset.                       |
| `start_i`           | in  | 1     | Pulse for one cycle to begin a session.             |
| `mode_i`            | in  | 2     | 0=KEY_DERIVE, 1=SIGN, 2=VERIFY.                     |
| `d_i`               | in  | 256   | Private key (KEY_DERIVE / SIGN).                    |
| `h_i`               | in  | 256   | Message hash (SIGN / VERIFY).                       |
| `k_i`               | in  | 256   | Per-signature nonce (SIGN).                         |
| `qx_i`, `qy_i`      | in  | 256   | Public key (VERIFY).                                |
| `r_i`, `s_i`        | in  | 256   | Signature (VERIFY).                                 |
| `qx_o`, `qy_o`      | out | 256   | Public key (KEY_DERIVE).                            |
| `r_o`, `s_o`        | out | 256   | Signature (SIGN; low-S form).                       |
| `low_s_replaced_o`  | out | 1     | 1 if low-S replacement applied (SIGN).              |
| `accept_o`          | out | 1     | 1 if signature accepted (VERIFY).                   |
| `err_o`             | out | 1     | 1 if SIGN failed (caller must retry).               |
| `valid_o`           | out | 1     | Single-cycle pulse: outputs are valid.              |
| `ready_o`           | out | 1     | Core can accept a new `start_i`.                    |
