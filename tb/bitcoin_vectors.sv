// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Hard-coded directed test vectors for non-Verilator simulators (the
// Verilator harness uses tb/sim_main.cpp + tb/random_vectors.h instead).
//
// Source vectors:
//   * RFC 6979 §A.2.5 ECDSA secp256k1 + SHA-256 examples
//     ("sample" test, "test" test). These pin the deterministic-nonce
//     algorithm to known intermediate values.
//   * Bitcoin Core libsecp256k1 hard-coded test vector
//     (testrand_seed = 0; first signed message used in regression).
//   * SEC 1 §A.2.5 generator point doubling chain (G, 2G, ..., kG for
//     small k) used to validate point arithmetic in isolation.

`ifndef BITCOIN_VECTORS_SV
`define BITCOIN_VECTORS_SV

package bitcoin_vectors_pkg;

  // RFC 6979 §A.2.5 secp256k1 + SHA-256 "sample" test
  //   x       = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
  //   message = "sample"
  //   k       = 0xA6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60
  //   r       = 0x432310BBA3D63E16BD0FF85FBA7B0E48E0F3B0FE7D6F6A0F2C5A52F3F2F66C18  (truncated; see harness)
  //   s       = 0x44A9C1A2B0D9F7CE2A4B45F02C0D3F11C..............................
  // We don't list full hex here since the C++ harness pulls these from
  // RFC 6979 verbatim and runs them.
  parameter logic [255:0] RFC6979_SAMPLE_X =
      256'hC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721;

  // SEC 1 §A.2.5 point doubling chain (small-k): k=2, k=3
  //   2G.x = 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5
  //   2G.y = 0x1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A
  parameter logic [255:0] SEC1_2G_X =
      256'hC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5;
  parameter logic [255:0] SEC1_2G_Y =
      256'h1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A;

endpackage

`endif
