// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// secp256k1 point arithmetic helpers, in JACOBIAN coordinates.
//
// Affine (X, Y) is stored as (X*Z^2, Y*Z^3, Z) so that adds and doubles
// avoid a per-step modular inversion (the inversion is the cycle-cost
// bottleneck on chain). The single inversion to convert back to affine
// is performed once at the end of scalar multiplication, in the parent.
//
// Curve: y^2 = x^3 + 7 over GF(p), short Weierstrass with a = 0.
//
// References:
//   * D. Hankerson, A. Menezes, S. Vanstone, "Guide to Elliptic Curve
//     Cryptography", §3.2.2 (Jacobian doubling and addition formulae
//     for a = 0 curves).
//   * SEC 2: Recommended Elliptic Curve Domain Parameters, Certicom
//     Research, 2010.
//
// This module exposes a single combinational "point op" datapath that
// the parent FSM sequences across multiple cycles:
//
//   op_i = OP_DBL : R = 2 * P              (Jacobian doubling, a = 0)
//   op_i = OP_ADD : R = P + Q              (Jacobian-affine mixed add;
//                                           Q assumed Z = 1, the typical
//                                           case for k*G where G is the
//                                           generator and stays affine).
//
// The point-at-infinity is represented by Z = 0; both operations return
// the other operand if either input is the identity.

module point_secp256k1 (
  // P (Jacobian)
  input  logic [255:0] px_i,
  input  logic [255:0] py_i,
  input  logic [255:0] pz_i,
  // Q (affine, Z assumed 1; only valid for OP_ADD)
  input  logic [255:0] qx_i,
  input  logic [255:0] qy_i,
  input  logic         q_inf_i,
  // Operation select
  input  logic         op_i,           // 0 = DBL, 1 = ADD
  // Result (Jacobian)
  output logic [255:0] rx_o,
  output logic [255:0] ry_o,
  output logic [255:0] rz_o
);

  localparam logic OP_DBL = 1'b0;
  localparam logic OP_ADD = 1'b1;

  // Helper: field functions (replicated combinationally; keeping them
  // local avoids the round-trip through `field_secp256k1` for every
  // sub-expression here).
  function automatic logic [255:0] p_const ();
    p_const = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
  endfunction
  localparam logic [32:0] C_K = 33'h1_0000_03D1;

  function automatic logic [255:0] fadd (input logic [255:0] a,
                                          input logic [255:0] b);
    logic [256:0] s;
    s = {1'b0, a} + {1'b0, b};
    if (s >= {1'b0, p_const()}) fadd = s[255:0] - p_const();
    else                         fadd = s[255:0];
  endfunction
  function automatic logic [255:0] fsub (input logic [255:0] a,
                                          input logic [255:0] b);
    if (a >= b) fsub = a - b;
    else        fsub = p_const() - (b - a);
  endfunction
  function automatic logic [255:0] solred (input logic [511:0] x);
    logic [255:0] x_lo;
    logic [255:0] x_hi;
    logic [288:0] step1;
    logic [255:0] s1_lo;
    logic [32:0]  s1_hi;
    logic [288:0] step2;
    logic [255:0] s2_lo;
    logic [32:0]  s2_hi;
    logic [256:0] step3;
    logic [256:0] s3_full;
    logic [255:0] s3_norm;
    x_lo  = x[255:0];
    x_hi  = x[511:256];
    step1 = {33'd0, x_lo} + x_hi * C_K;
    s1_lo = step1[255:0];
    s1_hi = step1[288:256];
    step2 = {33'd0, s1_lo} + s1_hi * C_K;
    s2_lo = step2[255:0];
    s2_hi = step2[288:256];
    step3 = {1'b0, s2_lo} + {223'd0, s2_hi} * {223'd0, C_K[31:0]};
    if (step3 >= {1'b0, p_const()}) s3_full = step3 - {1'b0, p_const()};
    else                             s3_full = step3;
    if (s3_full >= {1'b0, p_const()}) s3_norm = s3_full[255:0] - p_const();
    else                              s3_norm = s3_full[255:0];
    solred = s3_norm;
  endfunction
  function automatic logic [255:0] fmul (input logic [255:0] a,
                                          input logic [255:0] b);
    fmul = solred(a * b);
  endfunction
  function automatic logic [255:0] fsqr (input logic [255:0] a);
    fsqr = solred(a * a);
  endfunction

  // ---- Jacobian doubling, a = 0 (HMV §3.2.2) -----------------------------
  //   A = X^2,  B = Y^2,  C = B^2
  //   D = 2 * ((X + B)^2 - A - C)
  //   E = 3 * A
  //   F = E^2
  //   X' = F - 2*D
  //   Y' = E*(D - X') - 8*C
  //   Z' = 2*Y*Z
  function automatic void jac_double (
      input  logic [255:0] x, y, z,
      output logic [255:0] rx, ry, rz);
    logic [255:0] A_, B_, C_, D_, E_, F_;
    logic [255:0] xpb, xpb_sq, t8C, t2D, t1, t2;
    A_     = fsqr(x);
    B_     = fsqr(y);
    C_     = fsqr(B_);
    xpb    = fadd(x, B_);
    xpb_sq = fsqr(xpb);
    D_     = fsub(xpb_sq, A_);
    D_     = fsub(D_,    C_);
    D_     = fadd(D_,    D_);                   // *2
    E_     = fadd(fadd(A_, A_), A_);             // *3
    F_     = fsqr(E_);
    t2D    = fadd(D_, D_);
    rx     = fsub(F_, t2D);
    t1     = fsub(D_, rx);
    t2     = fmul(E_, t1);
    t8C    = fadd(C_, C_);
    t8C    = fadd(t8C, t8C);
    t8C    = fadd(t8C, t8C);                     // 8*C
    ry     = fsub(t2, t8C);
    rz     = fadd(fmul(y, z), fmul(y, z));
  endfunction

  // ---- Jacobian + affine mixed addition (Q has Z = 1) --------------------
  //   U2 = X2 * Z1^2
  //   S2 = Y2 * Z1^3
  //   H  = U2 - X1
  //   r  = S2 - Y1
  //   X3 = r^2 - H^3 - 2*X1*H^2
  //   Y3 = r*(X1*H^2 - X3) - Y1*H^3
  //   Z3 = Z1*H
  function automatic void jac_add_affine (
      input  logic [255:0] x1, y1, z1,
      input  logic [255:0] x2, y2,
      input  logic         q_inf,
      output logic [255:0] rx, ry, rz);
    logic [255:0] z1z1, z1z1z1;
    logic [255:0] u2, s2, h, hh, hhh, t, r_, x3, y3, z3;
    if (z1 == 256'd0) begin
      // P = O, return Q (z = 1) or O if Q = O.
      if (q_inf) begin rx = 256'd0; ry = 256'd0; rz = 256'd0; end
      else       begin rx = x2;     ry = y2;     rz = 256'd1; end
    end else if (q_inf) begin
      rx = x1; ry = y1; rz = z1;
    end else begin
      z1z1   = fsqr(z1);
      z1z1z1 = fmul(z1z1, z1);
      u2     = fmul(x2, z1z1);
      s2     = fmul(y2, z1z1z1);
      h      = fsub(u2, x1);
      r_     = fsub(s2, y1);
      if (h == 256'd0) begin
        if (r_ == 256'd0) begin
          // P = Q: degenerate, parent should have called DBL. Return O.
          rx = 256'd0; ry = 256'd0; rz = 256'd0;
        end else begin
          // P = -Q: result is point at infinity.
          rx = 256'd0; ry = 256'd0; rz = 256'd0;
        end
      end else begin
        hh    = fsqr(h);
        hhh   = fmul(hh, h);
        t     = fmul(x1, hh);
        x3    = fsub(fsub(fsqr(r_), hhh), fadd(t, t));
        y3    = fsub(fmul(r_, fsub(t, x3)), fmul(y1, hhh));
        z3    = fmul(z1, h);
        rx    = x3; ry = y3; rz = z3;
      end
    end
  endfunction

  // ---- Top: pick DBL or ADD ----------------------------------------------
  logic [255:0] dbl_x, dbl_y, dbl_z;
  logic [255:0] add_x, add_y, add_z;

  always_comb begin
    jac_double(px_i, py_i, pz_i, dbl_x, dbl_y, dbl_z);
    jac_add_affine(px_i, py_i, pz_i, qx_i, qy_i, q_inf_i,
                   add_x, add_y, add_z);
    if (op_i == OP_DBL) begin
      rx_o = dbl_x; ry_o = dbl_y; rz_o = dbl_z;
    end else begin
      rx_o = add_x; ry_o = add_y; rz_o = add_z;
    end
  end

endmodule
