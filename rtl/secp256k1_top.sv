// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// secp256k1 ECDSA streaming top.
//
// One streaming interface, three modes:
//
//   mode_i = 2'd0  KEY_DERIVE
//       Inputs:  d_i (private key)
//       Outputs: qx_o, qy_o = d * G        (public key, affine)
//
//   mode_i = 2'd1  SIGN
//       Inputs:  d_i (private key), h_i (hash), k_i (per-sig nonce)
//       Outputs: r_o, s_o, low_s_replaced_o, err_o
//                (s is in BIP-66 canonical low-S form; err_o is 1 if r=0
//                 or s=0, in which case the caller should retry with a
//                 fresh nonce)
//
//   mode_i = 2'd2  VERIFY
//       Inputs:  qx_i, qy_i (public key), h_i (hash), r_i, s_i
//       Outputs: accept_o (1 if signature valid for this (q, h, r, s))
//
// The three sub-engines (`scalar_mult`, `ecdsa_sign`, `ecdsa_verify`)
// share the same field / scalar-field / point datapaths; multiplexing
// between modes is purely at the FSM level. At any given session only
// one sub-engine is active.
//
// Curve parameters: secp256k1 (SEC 1, Certicom 2010), used by Bitcoin,
// Ethereum, Lightning Network, every major hardware wallet (Ledger,
// Trezor, Coldcard, ...), Solana's underlying validator signing for
// non-Ed25519 paths, and TLS optional curves. See README.md.

module secp256k1_top (
  input  logic         clk_i,
  input  logic         rst_ni,

  // Session start
  input  logic         start_i,
  input  logic [1:0]   mode_i,            // 0=key_derive, 1=sign, 2=verify

  // Inputs (used by subset of modes; ignored otherwise)
  input  logic [255:0] d_i,                // private key (key_derive, sign)
  input  logic [255:0] h_i,                // hash (sign, verify)
  input  logic [255:0] k_i,                // nonce (sign)
  input  logic [255:0] qx_i, qy_i,         // pubkey (verify)
  input  logic [255:0] r_i, s_i,           // signature (verify)

  // Outputs
  output logic [255:0] qx_o, qy_o,         // pubkey (key_derive)
  output logic [255:0] r_o, s_o,           // signature (sign)
  output logic         low_s_replaced_o,
  output logic         accept_o,           // (verify)
  output logic         err_o,              // (sign)
  output logic         valid_o,
  output logic         ready_o
);

  localparam logic [1:0] M_KEY    = 2'd0;
  localparam logic [1:0] M_SIGN   = 2'd1;
  localparam logic [1:0] M_VERIFY = 2'd2;

  // ----------------------------------------------------------------------
  // Generator G
  function automatic logic [255:0] gx_const ();
    gx_const = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
  endfunction
  function automatic logic [255:0] gy_const ();
    gy_const = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
  endfunction

  // ----------------------------------------------------------------------
  // KEY_DERIVE engine: just one scalar_mult instance with k = d, P = G.
  logic         kd_start;
  logic [255:0] kd_k, kd_px, kd_py;
  logic [255:0] kd_rx, kd_ry;
  logic         kd_inf, kd_ready, kd_valid;
  scalar_mult u_kd (
    .clk_i (clk_i), .rst_ni(rst_ni),
    .start_i(kd_start),
    .k_i   (kd_k), .px_i(kd_px), .py_i(kd_py),
    .rx_o  (kd_rx), .ry_o(kd_ry),
    .inf_o (kd_inf),
    .ready_o(kd_ready), .valid_o(kd_valid)
  );

  // ----------------------------------------------------------------------
  // SIGN engine
  logic         sg_start;
  logic [255:0] sg_d, sg_h, sg_k;
  logic [255:0] sg_r, sg_s;
  logic         sg_low_s, sg_err, sg_ready, sg_valid;
  ecdsa_sign u_sg (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .start_i(sg_start),
    .d_i  (sg_d), .h_i(sg_h), .k_i(sg_k),
    .r_o  (sg_r), .s_o(sg_s),
    .low_s_replaced_o(sg_low_s),
    .err_o(sg_err),
    .valid_o(sg_valid), .ready_o(sg_ready)
  );

  // ----------------------------------------------------------------------
  // VERIFY engine
  logic         vf_start;
  logic [255:0] vf_qx, vf_qy, vf_h, vf_r, vf_s;
  logic         vf_accept, vf_ready, vf_valid;
  ecdsa_verify u_vf (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .start_i(vf_start),
    .qx_i (vf_qx), .qy_i(vf_qy),
    .h_i  (vf_h),
    .r_i  (vf_r), .s_i (vf_s),
    .valid_o(vf_valid),
    .accept_o(vf_accept),
    .ready_o (vf_ready)
  );

  // ----------------------------------------------------------------------
  // Session FSM
  // ----------------------------------------------------------------------
  typedef enum logic [2:0] {
    T_IDLE = 3'd0,
    T_KD   = 3'd1,
    T_SG   = 3'd2,
    T_VF   = 3'd3,
    T_DONE = 3'd4
  } tstate_e;

  tstate_e st_q;
  logic [1:0] mode_q;

  logic [255:0] qx_q, qy_q;
  logic [255:0] r_q, s_q;
  logic         low_s_q, accept_q, err_q;
  logic         valid_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      st_q     <= T_IDLE;
      mode_q   <= 2'd0;
      kd_start <= 1'b0;
      kd_k     <= 256'd0;
      kd_px    <= 256'd0;
      kd_py    <= 256'd0;
      sg_start <= 1'b0;
      sg_d     <= 256'd0;
      sg_h     <= 256'd0;
      sg_k     <= 256'd0;
      vf_start <= 1'b0;
      vf_qx    <= 256'd0;
      vf_qy    <= 256'd0;
      vf_h     <= 256'd0;
      vf_r     <= 256'd0;
      vf_s     <= 256'd0;
      qx_q     <= 256'd0;
      qy_q     <= 256'd0;
      r_q      <= 256'd0;
      s_q      <= 256'd0;
      low_s_q  <= 1'b0;
      accept_q <= 1'b0;
      err_q    <= 1'b0;
      valid_q  <= 1'b0;
    end else begin
      kd_start <= 1'b0;
      sg_start <= 1'b0;
      vf_start <= 1'b0;
      valid_q  <= 1'b0;

      case (st_q)
        T_IDLE: begin
          if (start_i) begin
            mode_q   <= mode_i;
            accept_q <= 1'b0;
            err_q    <= 1'b0;
            low_s_q  <= 1'b0;
            case (mode_i)
              M_KEY: begin
                kd_k     <= d_i;
                kd_px    <= gx_const();
                kd_py    <= gy_const();
                kd_start <= 1'b1;
                st_q     <= T_KD;
              end
              M_SIGN: begin
                sg_d     <= d_i;
                sg_h     <= h_i;
                sg_k     <= k_i;
                sg_start <= 1'b1;
                st_q     <= T_SG;
              end
              M_VERIFY: begin
                vf_qx    <= qx_i;
                vf_qy    <= qy_i;
                vf_h     <= h_i;
                vf_r     <= r_i;
                vf_s     <= s_i;
                vf_start <= 1'b1;
                st_q     <= T_VF;
              end
              default: st_q <= T_IDLE;
            endcase
          end
        end

        T_KD: begin
          if (kd_valid) begin
            qx_q   <= kd_rx;
            qy_q   <= kd_ry;
            valid_q<= 1'b1;
            st_q   <= T_DONE;
          end
        end

        T_SG: begin
          if (sg_valid) begin
            r_q     <= sg_r;
            s_q     <= sg_s;
            low_s_q <= sg_low_s;
            err_q   <= sg_err;
            valid_q <= 1'b1;
            st_q    <= T_DONE;
          end
        end

        T_VF: begin
          if (vf_valid) begin
            accept_q<= vf_accept;
            valid_q <= 1'b1;
            st_q    <= T_DONE;
          end
        end

        T_DONE: begin
          st_q <= T_IDLE;
        end

        default: st_q <= T_IDLE;
      endcase
    end
  end

  assign ready_o          = (st_q == T_IDLE);
  assign valid_o          = valid_q;
  assign qx_o             = qx_q;
  assign qy_o             = qy_q;
  assign r_o              = r_q;
  assign s_o              = s_q;
  assign low_s_replaced_o = low_s_q;
  assign accept_o         = accept_q;
  assign err_o            = err_q;

endmodule
