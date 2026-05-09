// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Scalar-field arithmetic mod n (the secp256k1 group order).
//
//   n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
//
// n is NOT Solinas-friendly the way p is, so we use the dual approach:
//
//   * Add / sub : single-cycle modular sum / difference (one conditional
//                 subtract or add).
//   * Multiply  : 256x256 -> 512 schoolbook, then a sequenced reduction
//                 (Barrett-style with a precomputed mu = floor(2^512 / n)
//                 produces a fixed two-step reduction; here we use the
//                 simpler "fold by c_n = 2^256 - n" approach):
//                     x = x_lo + x_hi * 2^256
//                     x mod n = x_lo - x_hi * (n - 2^256) mod n
//                             = x_lo + x_hi * c_n  (mod n)
//                  where c_n = 2^256 - n is ~129 bits. After one fold
//                  the residue fits in ~388 bits; one more fold yields
//                  ~261 bits; final conditional subtractions of n.
//
// This module exposes a combinational op block. The parent FSM registers
// the result.

module scalar_field (
  input  logic [255:0] a_i,
  input  logic [255:0] b_i,
  input  logic [1:0]   op_i,        // 0 = add, 1 = sub, 2 = mul, 3 = sqr
  output logic [255:0] r_o
);

  function automatic logic [255:0] n_const ();
    n_const = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
  endfunction
  // c_n = 2^256 - n   (= 0x14551231950B75FC4402DA1732FC9BEBF, 129 bits)
  function automatic logic [128:0] cn_const ();
    cn_const = 129'h1_4551_231950B75FC4402DA1732FC9BEBF;
  endfunction

  function automatic logic [255:0] nadd_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    logic [256:0] s;
    s = {1'b0, a} + {1'b0, b};
    if (s >= {1'b0, n_const()}) nadd_fn = s[255:0] - n_const();
    else                         nadd_fn = s[255:0];
  endfunction
  function automatic logic [255:0] nsub_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    if (a >= b) nsub_fn = a - b;
    else        nsub_fn = n_const() - (b - a);
  endfunction

  // Reduce a 512-bit value mod n via two folds with c_n (which is 129 b),
  // followed by up to two conditional subtractions of n.
  //   x = x_lo + x_hi * 2^256
  //   step1 = x_lo + x_hi * c_n            (~ 256 + 129 = 385 b)
  //   step2 = step1_lo + step1_hi * c_n    (~ 256 + 2*129-256 = ~258 b)
  //   if step2 >= 2^256: subtract n once  (still <=  ~258 b after sub)
  //   while result >= n: subtract n
  function automatic logic [255:0] mod_n_512 (input logic [511:0] x);
    logic [255:0] x_lo;
    logic [255:0] x_hi;
    logic [384:0] step1;
    logic [255:0] s1_lo;
    logic [128:0] s1_hi;
    logic [384:0] step2;
    logic [255:0] s2_lo;
    logic [128:0] s2_hi;
    logic [385:0] s3;
    logic [385:0] cur;
    logic [128:0] cn;

    cn    = cn_const();
    x_lo  = x[255:0];
    x_hi  = x[511:256];
    step1 = {129'd0, x_lo} + x_hi * cn;              // <= 385 b
    s1_lo = step1[255:0];
    s1_hi = step1[384:256];                            // 129 b
    step2 = {129'd0, s1_lo} + s1_hi * cn;            // <= 258 b
    s2_lo = step2[255:0];
    s2_hi = step2[384:256];                            // <= 2 b in practice
    // Final fold uses the full 129-bit cn (NOT a 128-bit truncation).
    // s2_hi is at most a few bits so the product fits well within the
    // 386-bit accumulator below.
    s3    = {130'd0, s2_lo} + {257'd0, s2_hi} * {257'd0, cn};
    cur   = s3;
    // Final reduction: subtract n at most ~3 times.
    if (cur >= {130'd0, n_const()}) cur = cur - {130'd0, n_const()};
    if (cur >= {130'd0, n_const()}) cur = cur - {130'd0, n_const()};
    if (cur >= {130'd0, n_const()}) cur = cur - {130'd0, n_const()};
    mod_n_512 = cur[255:0];
  endfunction

  function automatic logic [255:0] nmul_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    nmul_fn = mod_n_512(a * b);
  endfunction

  always_comb begin
    case (op_i)
      2'd0:    r_o = nadd_fn(a_i, b_i);
      2'd1:    r_o = nsub_fn(a_i, b_i);
      2'd2:    r_o = nmul_fn(a_i, b_i);
      2'd3:    r_o = nmul_fn(a_i, a_i);
      default: r_o = 256'd0;
    endcase
  end

endmodule
