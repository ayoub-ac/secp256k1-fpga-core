// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// ECDSA signing on secp256k1 (ANSI X9.62 / SEC 1 §4.1.3 / FIPS 186-5).
//
// Inputs:
//   * d  : private key (256-bit integer in [1, n-1])
//   * h  : message hash (256 bits)
//   * k  : per-signature nonce in [1, n-1]
//          The caller MUST supply a fresh, secret, uniformly random nonce
//          OR a deterministic nonce per RFC 6979 § 3.2 (HMAC-SHA-256
//          based). Nonce reuse with two different messages allows
//          immediate recovery of d. See SECURITY.md.
//
// Algorithm:
//   1. (R.x, R.y) = k * G                    [scalar mult]
//   2. r = R.x mod n;  if r == 0, fail (caller must retry with a new k)
//   3. s = k^-1 * (h + r*d) mod n             [Fermat inverse + 2 muls]
//   4. if s == 0, fail
//   5. Return (r, s).
//
// This module emits an additional `low_s_o` flag: per BIP-66 / Bitcoin
// canonical form, on-chain signatures must satisfy s <= n/2; if not,
// replace s with n - s. The output `s_o` is the LOW-S form, and
// `low_s_replaced_o` indicates whether a replacement happened so the
// caller can record it. Higher layers (DER encoding, low-r grinding for
// Bitcoin's "low-r" canonical extension) are out of scope for this core.
//
// Sequencing:
//   * 1 scalar mult (~1024 cycles) for k*G.
//   * 1 mod-n inversion (~512 cycles) for k^-1.
//   * Handful of mod-n muls + adds for s.
//   * Total per sign: ~1600 cycles.

module ecdsa_sign (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         start_i,
  input  logic [255:0] d_i,         // private key
  input  logic [255:0] h_i,         // message hash
  input  logic [255:0] k_i,         // per-signature nonce

  output logic [255:0] r_o,
  output logic [255:0] s_o,
  output logic         low_s_replaced_o,
  output logic         err_o,       // 1 if r==0 or s==0 (retry with new k)
  output logic         valid_o,
  output logic         ready_o
);

  localparam logic [255:0] N_CONST =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
  localparam logic [255:0] N_MINUS_2 =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD036413F;
  // n/2 floor
  localparam logic [255:0] N_HALF_FLOOR =
      256'h7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
  function automatic logic [255:0] n_const (); n_const = N_CONST; endfunction
  function automatic logic [255:0] n_minus_2 (); n_minus_2 = N_MINUS_2; endfunction
  function automatic logic [255:0] n_half_floor (); n_half_floor = N_HALF_FLOOR; endfunction
  function automatic logic [255:0] gx_const ();
    gx_const = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
  endfunction
  function automatic logic [255:0] gy_const ();
    gy_const = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
  endfunction

  // -----------------------------------------------------------------------
  // Shared scalar_mult engine
  // -----------------------------------------------------------------------
  logic         smul_start;
  logic [255:0] smul_k, smul_px, smul_py;
  logic [255:0] smul_rx, smul_ry;
  logic         smul_inf, smul_ready, smul_valid;
  scalar_mult u_smul (
    .clk_i (clk_i), .rst_ni(rst_ni),
    .start_i(smul_start),
    .k_i   (smul_k), .px_i (smul_px), .py_i(smul_py),
    .rx_o  (smul_rx), .ry_o (smul_ry),
    .inf_o (smul_inf),
    .ready_o(smul_ready), .valid_o(smul_valid)
  );

  // -----------------------------------------------------------------------
  // Scalar-field op (mod n)
  // -----------------------------------------------------------------------
  logic [255:0] sf_a, sf_b, sf_r;
  logic [1:0]   sf_op;
  scalar_field u_sf (
    .a_i(sf_a), .b_i(sf_b), .op_i(sf_op), .r_o(sf_r)
  );

  // -----------------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------------
  typedef enum logic [3:0] {
    G_IDLE        = 4'd0,
    G_KG_LAUNCH   = 4'd1,
    G_KG_WAIT     = 4'd2,
    G_R_CHECK     = 4'd3,
    G_KINV_INIT   = 4'd4,
    G_KINV_SQ     = 4'd5,    // capture square; conditionally request mul
    G_KINV_MUL    = 4'd6,    // capture mul
    G_RD          = 4'd7,    // r * d mod n
    G_HRD         = 4'd8,    // h + r*d mod n
    G_S_MUL       = 4'd9,    // k^-1 * (h + r*d) mod n
    G_LOWS        = 4'd10,   // low-S canonicalisation
    G_DONE        = 4'd11
  } gstate_e;

  gstate_e st_q;
  logic [255:0] d_q, h_q, k_q;
  logic [255:0] r_q, s_q;
  logic [255:0] kinv_q;
  logic [255:0] inv_acc, inv_base;
  logic [8:0]   inv_idx;
  logic         err_q, valid_q, low_s_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      st_q       <= G_IDLE;
      d_q        <= 256'd0;
      h_q        <= 256'd0;
      k_q        <= 256'd0;
      r_q        <= 256'd0;
      s_q        <= 256'd0;
      kinv_q     <= 256'd0;
      inv_acc    <= 256'd0;
      inv_base   <= 256'd0;
      inv_idx    <= 9'd0;
      sf_a       <= 256'd0;
      sf_b       <= 256'd0;
      sf_op      <= 2'd0;
      smul_start <= 1'b0;
      smul_k     <= 256'd0;
      smul_px    <= 256'd0;
      smul_py    <= 256'd0;
      err_q      <= 1'b0;
      valid_q    <= 1'b0;
      low_s_q    <= 1'b0;
    end else begin
      smul_start <= 1'b0;
      valid_q    <= 1'b0;

      case (st_q)
        G_IDLE: begin
          if (start_i) begin
            d_q   <= d_i;
            h_q   <= h_i;
            k_q   <= k_i;
            err_q <= 1'b0;
            low_s_q <= 1'b0;
            // Validate k != 0 and k < n; if violated, error out early.
            if (k_i == 256'd0 || k_i >= n_const()) begin
              err_q   <= 1'b1;
              valid_q <= 1'b1;
              st_q    <= G_DONE;
            end else begin
              st_q    <= G_KG_LAUNCH;
            end
          end
        end

        G_KG_LAUNCH: begin
          smul_k     <= k_q;
          smul_px    <= gx_const();
          smul_py    <= gy_const();
          smul_start <= 1'b1;
          st_q       <= G_KG_WAIT;
        end

        G_KG_WAIT: begin
          if (smul_valid) begin
            // r = R.x mod n
            r_q  <= (smul_rx >= n_const()) ? (smul_rx - n_const()) : smul_rx;
            st_q <= G_R_CHECK;
          end
        end

        G_R_CHECK: begin
          if (r_q == 256'd0 || smul_inf) begin
            err_q   <= 1'b1;
            valid_q <= 1'b1;
            st_q    <= G_DONE;
          end else begin
            // Begin Fermat inversion of k mod n.
            inv_acc <= 256'd1;
            inv_base<= k_q;
            inv_idx <= 9'd255;
            sf_a    <= 256'd1;
            sf_b    <= 256'd1;
            sf_op   <= 2'd2;        // MUL: 1*1 = 1 (initial square)
            st_q    <= G_KINV_SQ;
          end
        end

        G_KINV_SQ: begin
          inv_acc <= sf_r;
          if (N_MINUS_2[inv_idx[7:0]]) begin
            sf_a  <= sf_r;
            sf_b  <= inv_base;
            sf_op <= 2'd2;
            st_q  <= G_KINV_MUL;
          end else begin
            if (inv_idx == 9'd0) begin
              kinv_q <= sf_r;
              // Begin r * d.
              sf_a   <= r_q;
              sf_b   <= d_q;
              sf_op  <= 2'd2;
              st_q   <= G_RD;
            end else begin
              inv_idx <= inv_idx - 9'd1;
              sf_a    <= sf_r;
              sf_b    <= sf_r;
              sf_op   <= 2'd2;
              st_q    <= G_KINV_SQ;
            end
          end
        end

        G_KINV_MUL: begin
          inv_acc <= sf_r;
          if (inv_idx == 9'd0) begin
            kinv_q <= sf_r;
            sf_a   <= r_q;
            sf_b   <= d_q;
            sf_op  <= 2'd2;
            st_q   <= G_RD;
          end else begin
            inv_idx <= inv_idx - 9'd1;
            sf_a    <= sf_r;
            sf_b    <= sf_r;
            sf_op   <= 2'd2;
            st_q    <= G_KINV_SQ;
          end
        end

        G_RD: begin
          // sf_r = r*d.  Compute h + r*d.
          sf_a  <= h_q;
          sf_b  <= sf_r;
          sf_op <= 2'd0;            // ADD mod n
          st_q  <= G_HRD;
        end

        G_HRD: begin
          // sf_r = h + r*d.  Multiply by k^-1.
          sf_a  <= kinv_q;
          sf_b  <= sf_r;
          sf_op <= 2'd2;
          st_q  <= G_S_MUL;
        end

        G_S_MUL: begin
          s_q   <= sf_r;
          st_q  <= G_LOWS;
        end

        G_LOWS: begin
          // Bitcoin / BIP-66 canonical: enforce s <= n/2; otherwise s = n-s.
          if (s_q == 256'd0) begin
            err_q   <= 1'b1;
            valid_q <= 1'b1;
            st_q    <= G_DONE;
          end else if (s_q > n_half_floor()) begin
            s_q     <= n_const() - s_q;
            low_s_q <= 1'b1;
            valid_q <= 1'b1;
            st_q    <= G_DONE;
          end else begin
            low_s_q <= 1'b0;
            valid_q <= 1'b1;
            st_q    <= G_DONE;
          end
        end

        G_DONE: begin
          st_q <= G_IDLE;
        end

        default: st_q <= G_IDLE;
      endcase
    end
  end

  assign ready_o          = (st_q == G_IDLE);
  assign valid_o          = valid_q;
  assign r_o              = r_q;
  assign s_o              = s_q;
  assign err_o            = err_q;
  assign low_s_replaced_o = low_s_q;

endmodule
