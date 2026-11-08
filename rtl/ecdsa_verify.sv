// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// ECDSA verification on secp256k1 (ANSI X9.62 / SEC 1 §4.1.4 / FIPS 186-5).
//
// Inputs:
//   * Qx, Qy : public key (affine)
//   * h      : message hash (256 bits, treated as integer mod n)
//   * r, s   : signature components
//
// Algorithm:
//   1. Reject if r = 0, s = 0, r >= n, s >= n.
//   2. w  = s^-1 (mod n)             [Fermat: w = s^(n-2) mod n]
//   3. u1 = h * w (mod n)
//   4. u2 = r * w (mod n)
//   5. R' = u1 * G + u2 * Q          [scalar mults + affine add]
//   6. accept = (R' != O) and (R'.x mod n == r)
//
// Sequencing:
//   * The mod-n inversion is a 256-step square-and-multiply walk over
//     (n-2). Each step is one cycle of "square-and-capture" + optional
//     one cycle of "multiply-and-capture", giving ~512 cycles per
//     inversion.
//   * The two scalar mults reuse a single shared `scalar_mult` engine
//     (~1024 cycles each).
//   * The final affine add takes another modular inversion (~512 cycles)
//     and a handful of cycles of multiplications.
//
// Total per verify: ~3200 cycles. At 100 MHz that's 32 us; at Verilator's
// effective ~10 MHz it's ~300 us per call, well within the testbench
// budget.

module ecdsa_verify (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         start_i,
  input  logic [255:0] qx_i,
  input  logic [255:0] qy_i,
  input  logic [255:0] h_i,
  input  logic [255:0] r_i,
  input  logic [255:0] s_i,

  output logic         valid_o,
  output logic         accept_o,
  output logic         ready_o
);

  // -----------------------------------------------------------------------
  // Constants
  // -----------------------------------------------------------------------
  localparam logic [255:0] N_CONST =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
  localparam logic [255:0] N_MINUS_2 =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD036413F;
  localparam logic [255:0] P_CONST =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
  localparam logic [255:0] P_MINUS_2 =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D;
  function automatic logic [255:0] n_const ();   n_const   = N_CONST;   endfunction
  function automatic logic [255:0] n_minus_2 (); n_minus_2 = N_MINUS_2; endfunction
  function automatic logic [255:0] p_const ();   p_const   = P_CONST;   endfunction
  function automatic logic [255:0] p_minus_2 (); p_minus_2 = P_MINUS_2; endfunction
  function automatic logic [255:0] gx_const ();
    gx_const = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
  endfunction
  function automatic logic [255:0] gy_const ();
    gy_const = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
  endfunction

  // -----------------------------------------------------------------------
  // Scalar-field op (mod n) -- combinational.
  // -----------------------------------------------------------------------
  logic [255:0] sf_a, sf_b, sf_r;
  logic [1:0]   sf_op;
  scalar_field u_sf (
    .a_i(sf_a), .b_i(sf_b), .op_i(sf_op), .r_o(sf_r)
  );

  // -----------------------------------------------------------------------
  // Field op (mod p) -- combinational.
  // -----------------------------------------------------------------------
  logic [255:0] fp_a, fp_b, fp_r;
  logic [1:0]   fp_op;
  field_secp256k1 u_fp (
    .a_i(fp_a), .b_i(fp_b), .op_i(fp_op), .r_o(fp_r)
  );

  // -----------------------------------------------------------------------
  // Shared scalar_mult engine
  // -----------------------------------------------------------------------
  logic         smul_start;
  logic [255:0] smul_k, smul_px, smul_py;
  logic [255:0] smul_rx, smul_ry;
  logic         smul_inf, smul_ready, smul_valid;
  scalar_mult u_smul (
    .clk_i (clk_i),  .rst_ni(rst_ni),
    .start_i(smul_start),
    .k_i   (smul_k), .px_i (smul_px), .py_i(smul_py),
    .rx_o  (smul_rx),.ry_o (smul_ry),
    .inf_o (smul_inf),
    .ready_o(smul_ready), .valid_o(smul_valid)
  );

  // -----------------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------------
  typedef enum logic [4:0] {
    V_IDLE        = 5'd0,
    V_CHECK       = 5'd1,
    V_SINV_INIT   = 5'd2,
    V_SINV_SQ     = 5'd3,
    V_SINV_CAP_S  = 5'd4,    // capture square; conditionally request mul
    V_SINV_CAP_M  = 5'd5,    // capture multiply
    V_U1_MUL      = 5'd6,
    V_U2_MUL      = 5'd7,
    V_U1G_LAUNCH  = 5'd8,
    V_U1G_WAIT    = 5'd9,
    V_U2Q_LAUNCH  = 5'd10,
    V_U2Q_WAIT    = 5'd11,
    V_SUM_HANDLE  = 5'd12,
    V_PINV_INIT   = 5'd13,
    V_PINV_SQ     = 5'd14,
    V_PINV_CAP_S  = 5'd15,
    V_PINV_CAP_M  = 5'd16,
    V_LAMB_REQ    = 5'd17,
    V_LAMB_CAP    = 5'd18,
    V_X3_REQ      = 5'd19,
    V_X3_CAP      = 5'd20,
    V_Y3_REQ      = 5'd21,
    V_Y3_CAP      = 5'd22,
    V_DBL_LAUNCH  = 5'd23,
    V_DBL_WAIT    = 5'd24,
    V_FINAL       = 5'd25,
    V_DONE        = 5'd26
  } vstate_e;

  vstate_e st_q;
  logic [255:0] r_q, s_q, h_q, qxq, qyq;
  logic [255:0] w_q, u1_q, u2_q;
  logic [255:0] u1G_x, u1G_y, u2Q_x, u2Q_y;
  logic         u1G_inf, u2Q_inf;
  logic [255:0] sum_x, sum_y;
  logic         sum_inf;
  logic [255:0] lambda_q;
  logic [255:0] inv_acc, inv_base;
  logic [8:0]   inv_idx;
  logic         accept_q, valid_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      st_q       <= V_IDLE;
      r_q        <= 256'd0;
      s_q        <= 256'd0;
      h_q        <= 256'd0;
      qxq        <= 256'd0;
      qyq        <= 256'd0;
      w_q        <= 256'd0;
      u1_q       <= 256'd0;
      u2_q       <= 256'd0;
      u1G_x      <= 256'd0;
      u1G_y      <= 256'd0;
      u1G_inf    <= 1'b0;
      u2Q_x      <= 256'd0;
      u2Q_y      <= 256'd0;
      u2Q_inf    <= 1'b0;
      sum_x      <= 256'd0;
      sum_y      <= 256'd0;
      sum_inf    <= 1'b1;
      lambda_q   <= 256'd0;
      inv_acc    <= 256'd0;
      inv_base   <= 256'd0;
      inv_idx    <= 9'd0;
      sf_a       <= 256'd0;
      sf_b       <= 256'd0;
      sf_op      <= 2'd0;
      fp_a       <= 256'd0;
      fp_b       <= 256'd0;
      fp_op      <= 2'd0;
      smul_start <= 1'b0;
      smul_k     <= 256'd0;
      smul_px    <= 256'd0;
      smul_py    <= 256'd0;
      accept_q   <= 1'b0;
      valid_q    <= 1'b0;
    end else begin
      smul_start <= 1'b0;
      valid_q    <= 1'b0;

      case (st_q)
        // ----------------------------------------------------------
        V_IDLE: begin
          if (start_i) begin
            r_q      <= r_i;
            s_q      <= s_i;
            h_q      <= h_i;
            qxq      <= qx_i;
            qyq      <= qy_i;
            accept_q <= 1'b0;
            st_q     <= V_CHECK;
          end
        end

        V_CHECK: begin
          if (r_q == 256'd0 || s_q == 256'd0 ||
              r_q >= n_const() || s_q >= n_const()) begin
            accept_q <= 1'b0;
            valid_q  <= 1'b1;
            st_q     <= V_DONE;
          end else begin
            // Begin Fermat inversion of s mod n.
            inv_acc <= 256'd1;
            inv_base<= s_q;
            inv_idx <= 9'd255;
            sf_a    <= 256'd1;     // first square: 1 * 1 = 1
            sf_b    <= 256'd1;
            sf_op   <= 2'd2;       // MUL
            st_q    <= V_SINV_CAP_S;
          end
        end

        // sf_r holds (current acc)^2; capture it. Conditionally launch mul.
        V_SINV_CAP_S: begin
          inv_acc <= sf_r;
          if (N_MINUS_2[inv_idx[7:0]]) begin
            sf_a  <= sf_r;
            sf_b  <= inv_base;
            sf_op <= 2'd2;
            st_q  <= V_SINV_CAP_M;
          end else begin
            // No mul; advance.
            if (inv_idx == 9'd0) begin
              w_q <= sf_r;
              st_q<= V_U1_MUL;
            end else begin
              inv_idx <= inv_idx - 9'd1;
              sf_a    <= sf_r;
              sf_b    <= sf_r;
              sf_op   <= 2'd2;
              st_q    <= V_SINV_CAP_S;
            end
          end
        end

        V_SINV_CAP_M: begin
          inv_acc <= sf_r;
          if (inv_idx == 9'd0) begin
            w_q <= sf_r;
            st_q<= V_U1_MUL;
          end else begin
            inv_idx <= inv_idx - 9'd1;
            sf_a    <= sf_r;
            sf_b    <= sf_r;
            sf_op   <= 2'd2;
            st_q    <= V_SINV_CAP_S;
          end
        end

        // ----------------------------------------------------------
        V_U1_MUL: begin
          sf_a  <= h_q;
          sf_b  <= w_q;
          sf_op <= 2'd2;
          st_q  <= V_U2_MUL;
        end

        V_U2_MUL: begin
          u1_q  <= sf_r;          // h*w
          sf_a  <= r_q;
          sf_b  <= w_q;
          sf_op <= 2'd2;
          st_q  <= V_U1G_LAUNCH;
        end

        V_U1G_LAUNCH: begin
          u2_q       <= sf_r;     // r*w
          smul_k     <= u1_q;
          smul_px    <= gx_const();
          smul_py    <= gy_const();
          smul_start <= 1'b1;
          st_q       <= V_U1G_WAIT;
        end

        V_U1G_WAIT: begin
          if (smul_valid) begin
            u1G_x   <= smul_rx;
            u1G_y   <= smul_ry;
            u1G_inf <= smul_inf;
            st_q    <= V_U2Q_LAUNCH;
          end
        end

        V_U2Q_LAUNCH: begin
          if (smul_ready) begin
            smul_k     <= u2_q;
            smul_px    <= qxq;
            smul_py    <= qyq;
            smul_start <= 1'b1;
            st_q       <= V_U2Q_WAIT;
          end
        end

        V_U2Q_WAIT: begin
          if (smul_valid) begin
            u2Q_x   <= smul_rx;
            u2Q_y   <= smul_ry;
            u2Q_inf <= smul_inf;
            st_q    <= V_SUM_HANDLE;
          end
        end

        // ----------------------------------------------------------
        V_SUM_HANDLE: begin
          if (u1G_inf && u2Q_inf) begin
            sum_inf <= 1'b1;
            st_q    <= V_FINAL;
          end else if (u1G_inf) begin
            sum_x   <= u2Q_x;
            sum_y   <= u2Q_y;
            sum_inf <= 1'b0;
            st_q    <= V_FINAL;
          end else if (u2Q_inf) begin
            sum_x   <= u1G_x;
            sum_y   <= u1G_y;
            sum_inf <= 1'b0;
            st_q    <= V_FINAL;
          end else if (u1G_x == u2Q_x) begin
            if (u1G_y == u2Q_y) begin
              // Need to double u1G. Re-use scalar_mult with k=2.
              smul_k     <= 256'd2;
              smul_px    <= u1G_x;
              smul_py    <= u1G_y;
              smul_start <= 1'b1;
              st_q       <= V_DBL_WAIT;
            end else begin
              sum_inf <= 1'b1;
              st_q    <= V_FINAL;
            end
          end else begin
            // Begin Fermat inversion of (x2 - x1) mod p.
            // (We need fp ops here; load the field input.)
            fp_a    <= u2Q_x;
            fp_b    <= u1G_x;
            fp_op   <= 2'd1;       // SUB mod p
            inv_acc <= 256'd1;
            inv_idx <= 9'd255;
            st_q    <= V_PINV_INIT;
          end
        end

        V_DBL_WAIT: begin
          if (smul_valid) begin
            sum_x   <= smul_rx;
            sum_y   <= smul_ry;
            sum_inf <= smul_inf;
            st_q    <= V_FINAL;
          end
        end

        // ----------------------------------------------------------
        V_PINV_INIT: begin
          inv_base <= fp_r;          // (x2 - x1) mod p
          // First square op is 1 * 1 = 1.
          fp_a  <= 256'd1;
          fp_b  <= 256'd1;
          fp_op <= 2'd2;             // MUL mod p
          st_q  <= V_PINV_CAP_S;
        end

        V_PINV_CAP_S: begin
          inv_acc <= fp_r;
          if (P_MINUS_2[inv_idx[7:0]]) begin
            fp_a  <= fp_r;
            fp_b  <= inv_base;
            fp_op <= 2'd2;
            st_q  <= V_PINV_CAP_M;
          end else begin
            if (inv_idx == 9'd0) begin
              st_q <= V_LAMB_REQ;
            end else begin
              inv_idx <= inv_idx - 9'd1;
              fp_a    <= fp_r;
              fp_b    <= fp_r;
              fp_op   <= 2'd2;
              st_q    <= V_PINV_CAP_S;
            end
          end
        end

        V_PINV_CAP_M: begin
          inv_acc <= fp_r;
          if (inv_idx == 9'd0) begin
            st_q <= V_LAMB_REQ;
          end else begin
            inv_idx <= inv_idx - 9'd1;
            fp_a    <= fp_r;
            fp_b    <= fp_r;
            fp_op   <= 2'd2;
            st_q    <= V_PINV_CAP_S;
          end
        end

        // ----------------------------------------------------------
        // lambda = (y2 - y1) * (x2 - x1)^-1
        V_LAMB_REQ: begin
          // First compute (y2 - y1).
          fp_a  <= u2Q_y;
          fp_b  <= u1G_y;
          fp_op <= 2'd1;             // SUB
          st_q  <= V_LAMB_CAP;
        end

        V_LAMB_CAP: begin
          // fp_r is (y2 - y1). inv_acc is (x2-x1)^-1. Multiply.
          fp_a  <= fp_r;
          fp_b  <= inv_acc;
          fp_op <= 2'd2;             // MUL
          st_q  <= V_X3_REQ;
        end

        V_X3_REQ: begin
          lambda_q <= fp_r;          // capture lambda
          // x3 = lambda^2 - x1 - x2.  Request lambda^2.
          fp_a  <= fp_r;
          fp_b  <= fp_r;
          fp_op <= 2'd2;             // MUL (= SQR effectively)
          st_q  <= V_X3_CAP;
        end

        V_X3_CAP: begin
          // fp_r = lambda^2.  Subtract x1.
          fp_a  <= fp_r;
          fp_b  <= u1G_x;
          fp_op <= 2'd1;
          st_q  <= V_Y3_REQ;
        end

        V_Y3_REQ: begin
          // fp_r = lambda^2 - x1.  Subtract x2 -> sum_x.
          fp_a  <= fp_r;
          fp_b  <= u2Q_x;
          fp_op <= 2'd1;
          st_q  <= V_Y3_CAP;
        end

        V_Y3_CAP: begin
          // fp_r = sum_x.  Now compute sum_y = lambda*(x1 - sum_x) - y1.
          sum_x   <= fp_r;
          sum_inf <= 1'b0;
          // Request (x1 - sum_x):
          fp_a  <= u1G_x;
          fp_b  <= fp_r;
          fp_op <= 2'd1;
          st_q  <= V_DBL_LAUNCH;     // reuse a free state for next mul
        end

        V_DBL_LAUNCH: begin
          // fp_r = (x1 - sum_x). Multiply by lambda.
          fp_a  <= lambda_q;
          fp_b  <= fp_r;
          fp_op <= 2'd2;
          st_q  <= V_FINAL;
        end

        // ----------------------------------------------------------
        V_FINAL: begin
          // If sum_y wasn't yet finalised (we came via the affine-add
          // path), one more sub: sum_y = lambda*(x1-sum_x) - y1.
          // Detect via: came from V_DBL_LAUNCH iff fp_op == MUL with
          // operand pattern. Simpler: sum_inf already set in degenerate
          // paths; in those, sum_x/sum_y were directly assigned.
          if (!sum_inf && sum_y == 256'd0) begin
            // Subtract y1 from fp_r (which is lambda*(x1-sum_x)).
            fp_a    <= fp_r;
            fp_b    <= u1G_y;
            fp_op   <= 2'd1;
            sum_y   <= mod_p_sub(fp_r, u1G_y);
            // Acceptance check: r' = sum_x mod n; accept iff == r.
            accept_q<= (mod_n_256(sum_x) == r_q);
            valid_q <= 1'b1;
            st_q    <= V_DONE;
          end else begin
            // Degenerate path: sum_x/sum_y/sum_inf were set directly.
            if (sum_inf) accept_q <= 1'b0;
            else         accept_q <= (mod_n_256(sum_x) == r_q);
            valid_q <= 1'b1;
            st_q    <= V_DONE;
          end
        end

        V_DONE: begin
          st_q <= V_IDLE;
        end

        default: st_q <= V_IDLE;
      endcase
    end
  end

  // ----------------------------------------------------------------------
  // Local pure-function helpers used in the V_FINAL state.
  function automatic logic [255:0] mod_p_sub (input logic [255:0] a,
                                                input logic [255:0] b);
    if (a >= b) mod_p_sub = a - b;
    else        mod_p_sub = p_const() - (b - a);
  endfunction
  function automatic logic [255:0] mod_n_256 (input logic [255:0] x);
    if (x >= n_const()) mod_n_256 = x - n_const();
    else                 mod_n_256 = x;
  endfunction

  assign ready_o  = (st_q == V_IDLE);
  assign valid_o  = valid_q;
  assign accept_o = accept_q;

endmodule
