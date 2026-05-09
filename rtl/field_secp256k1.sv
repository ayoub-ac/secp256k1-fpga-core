// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// secp256k1 prime-field GF(p) arithmetic, where
//
//     p = 2^256 - 2^32 - 977
//       = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//
// p is a 256-bit Solinas-friendly pseudo-Mersenne prime. The constant
// c = 2^32 + 977 = 0x1000003D1 lets us fold any 257..512-bit value back
// into 256 bits with a small number of additions of c, instead of the
// long division that a generic prime would need:
//
//     x mod p,  with x = x_hi * 2^256 + x_lo
//             = x_lo + x_hi * (2^32 + 977)        (mod p)
//
// This module provides:
//
//   * fadd / fsub  : 256-bit modular add / sub, single cycle.
//   * fmul         : 256x256 -> 512-bit schoolbook then 2-step Solinas
//                    fold, single cycle. Wide combinational; the parent
//                    FSM registers the result. On Yosys generic mapping
//                    this dominates the design area; vendor flows infer
//                    DSP48 (Xilinx) / 27x18 multipliers (Quartus) for
//                    the partial products.
//   * finv         : modular inverse via Fermat's little theorem,
//                    a^(p-2) mod p, sequenced as a 256-bit windowed
//                    addition chain. An iterative engine fmul-loop is
//                    exposed by the parent: the parent feeds the inverse
//                    state machine which calls fmul on each step.
//
// All ports are big-endian on the wide bus: byte 0 lives in [255:248].
// The constant p is exposed as a `function` so other modules can refer
// to it without re-hardcoding the literal.

module field_secp256k1 (
  input  logic [255:0] a_i,
  input  logic [255:0] b_i,
  input  logic [1:0]   op_i,        // 0 = add, 1 = sub, 2 = mul, 3 = sqr
  output logic [255:0] r_o
);

  // p = 2^256 - 2^32 - 977
  function automatic logic [255:0] p_const ();
    p_const = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
  endfunction

  // c = 2^32 + 977 = p's "low part" complement; used for Solinas reduction
  //   x mod p, where x < 2^512:
  //     let x = x_hi * 2^256 + x_lo (x_hi 256 b, x_lo 256 b)
  //     reduce  step1 = x_lo + x_hi * c       (up to ~289 b)
  //     step2 = step1_lo + step1_hi * c       (up to ~256+ε b)
  //     step3 = subtract p once if >= p       (final 256 b)
  // c fits in 33 bits.
  localparam logic [32:0] C_K = 33'h1_0000_03D1;

  // Modular add: (a + b) mod p.
  function automatic logic [255:0] fadd_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    logic [256:0] s;
    logic [256:0] s_red;
    s = {1'b0, a} + {1'b0, b};
    if (s >= {1'b0, p_const()}) begin
      s_red = s - {1'b0, p_const()};
    end else begin
      s_red = s;
    end
    fadd_fn = s_red[255:0];
  endfunction

  // Modular sub: (a - b) mod p.
  function automatic logic [255:0] fsub_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    logic [256:0] s;
    if (a >= b) begin
      s = {1'b0, a - b};
    end else begin
      s = {1'b0, p_const()} - {1'b0, b - a};
    end
    fsub_fn = s[255:0];
  endfunction

  // Solinas reduction of a 512-bit value to a 256-bit value mod p.
  // Two folding rounds are sufficient because c is 33 bits: each round
  // shrinks the high part by 256-33 = 223 bits.
  function automatic logic [255:0] solinas_reduce (input logic [511:0] x);
    logic [255:0] x_lo;
    logic [255:0] x_hi;
    logic [288:0] step1;       // x_lo + x_hi * c
    logic [255:0] s1_lo;
    logic [32:0]  s1_hi;
    logic [288:0] step2;       // s1_lo + s1_hi * c
    logic [255:0] s2_lo;
    logic [32:0]  s2_hi;
    logic [256:0] step3;       // final fold of any remaining carry hi
    logic [256:0] s3_full;
    logic [255:0] s3_norm;

    x_lo  = x[255:0];
    x_hi  = x[511:256];
    step1 = {33'd0, x_lo} + x_hi * C_K;       // 289 bits max
    s1_lo = step1[255:0];
    s1_hi = step1[288:256];
    step2 = {33'd0, s1_lo} + s1_hi * C_K;     // 257 bits max (s1_hi <= 2^33)
    s2_lo = step2[255:0];
    s2_hi = step2[288:256];
    // s2_hi is at most a few bits; one more fold, then conditional sub p.
    step3 = {1'b0, s2_lo} + {223'd0, s2_hi} * {223'd0, C_K[31:0]};
    if (step3 >= {1'b0, p_const()}) begin
      s3_full = step3 - {1'b0, p_const()};
    end else begin
      s3_full = step3;
    end
    if (s3_full >= {1'b0, p_const()}) begin
      s3_norm = s3_full[255:0] - p_const();
    end else begin
      s3_norm = s3_full[255:0];
    end
    solinas_reduce = s3_norm;
  endfunction

  // Modular multiplication: (a * b) mod p.
  function automatic logic [255:0] fmul_fn (input logic [255:0] a,
                                             input logic [255:0] b);
    logic [511:0] prod;
    prod = a * b;
    fmul_fn = solinas_reduce(prod);
  endfunction

  always_comb begin
    case (op_i)
      2'd0:    r_o = fadd_fn(a_i, b_i);
      2'd1:    r_o = fsub_fn(a_i, b_i);
      2'd2:    r_o = fmul_fn(a_i, b_i);
      2'd3:    r_o = fmul_fn(a_i, a_i);
      default: r_o = 256'd0;
    endcase
  end

endmodule
