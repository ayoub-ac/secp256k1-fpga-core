// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Scalar multiplication R = k * P on secp256k1 using a left-to-right
// double-and-add over Jacobian coordinates. The base point P is taken
// in affine form (Z = 1, the typical case for k * G or for the verify
// path's u1 * G + u2 * Q where Q is the public key in affine).
//
// Phases:
//   1. Bit loop: for i = 255 down to 0
//        R = 2 * R                              (Jacobian doubling)
//        if k_i = 1:  R = R + P                 (mixed Jacobian + affine)
//      One state per DBL, one state per ADD step. Field arithmetic
//      inside `point_secp256k1` is combinational, so each state takes
//      one cycle. ~512 cycles for the whole loop.
//
//   2. Affine conversion: compute Z^-1 via Fermat
//          Z^-1 = Z^(p-2) mod p
//      using a 256-step square-and-multiply walk over the binary
//      expansion of (p-2). One register-capture cycle per square and
//      one per conditional multiply: ~512 additional cycles.
//
//   3. Affine: X = Xj * Z^-2,  Y = Yj * Z^-3.
//
// Total: ~1024 cycles per scalar multiply. For Verilator on a developer
// laptop this runs in ~50 ms per call.
//
// Constant-time note: this is not a side-channel-hardened design. The
// per-bit DBL+ADD pattern is structurally fixed but the conditional
// commit of the ADD result is gated on the scalar bit, which is a
// known-leaky pattern at the register-write level. See SECURITY.md.

module scalar_mult (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         start_i,
  input  logic [255:0] k_i,
  input  logic [255:0] px_i,
  input  logic [255:0] py_i,

  output logic [255:0] rx_o,
  output logic [255:0] ry_o,
  output logic         inf_o,
  output logic         ready_o,
  output logic         valid_o
);

  // ---------------- shared field op block ---------------------------------
  // Combinational; r_o is valid in the same cycle that a_i/b_i/op_i settle.
  logic [255:0] f_a, f_b, f_r;
  logic [1:0]   f_op;
  field_secp256k1 u_field (
    .a_i (f_a),
    .b_i (f_b),
    .op_i(f_op),
    .r_o (f_r)
  );

  // ---------------- shared point op block ---------------------------------
  logic [255:0] px_q, py_q, pz_q;
  logic [255:0] qx_q, qy_q;
  logic         q_inf_q;
  logic         pt_op_q;            // 0=DBL, 1=ADD
  logic [255:0] pt_rx, pt_ry, pt_rz;
  point_secp256k1 u_pt (
    .px_i  (px_q),
    .py_i  (py_q),
    .pz_i  (pz_q),
    .qx_i  (qx_q),
    .qy_i  (qy_q),
    .q_inf_i(q_inf_q),
    .op_i  (pt_op_q),
    .rx_o  (pt_rx),
    .ry_o  (pt_ry),
    .rz_o  (pt_rz)
  );

  // ---------------- FSM ---------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE      = 4'd0,
    S_BIT_DBL   = 4'd1,
    S_BIT_ADD   = 4'd2,
    S_INV_INIT  = 4'd3,
    S_INV_SQ    = 4'd4,
    S_INV_MAY   = 4'd5,    // capture sq; conditionally request multiply
    S_INV_CAP   = 4'd6,    // capture multiply (only entered if mul issued)
    S_AFF_ZI2   = 4'd7,    // request zi^2
    S_AFF_X     = 4'd8,    // capture zi^2; request X = Xj * zi^2
    S_AFF_ZI3   = 4'd9,    // capture X; request zi^3 = zi^2 * zi
    S_AFF_Y     = 4'd10,   // capture zi^3; request Y = Yj * zi^3
    S_AFF_YCAP  = 4'd11,   // capture Y
    S_DONE      = 4'd12
  } state_e;

  state_e state_q;
  logic [255:0] k_q;
  logic [8:0]   bit_idx_q;
  logic         R_is_inf_q;

  // p - 2
  localparam logic [255:0] P_MINUS_2 =
      256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D;

  logic [255:0] inv_acc_q;
  logic [255:0] inv_z_q;
  logic [8:0]   inv_idx_q;
  logic [255:0] zi_q, zi2_q;

  logic [255:0] rx_q, ry_q;
  logic         inf_q;
  logic         valid_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      k_q         <= 256'd0;
      bit_idx_q   <= 9'd0;
      px_q        <= 256'd0;
      py_q        <= 256'd0;
      pz_q        <= 256'd0;
      qx_q        <= 256'd0;
      qy_q        <= 256'd0;
      q_inf_q     <= 1'b0;
      pt_op_q     <= 1'b0;
      f_a         <= 256'd0;
      f_b         <= 256'd0;
      f_op        <= 2'd0;
      inv_acc_q   <= 256'd0;
      inv_z_q     <= 256'd0;
      inv_idx_q   <= 9'd0;
      zi_q        <= 256'd0;
      zi2_q       <= 256'd0;
      R_is_inf_q  <= 1'b1;
      rx_q        <= 256'd0;
      ry_q        <= 256'd0;
      inf_q       <= 1'b0;
      valid_q     <= 1'b0;
    end else begin
      valid_q <= 1'b0;

      case (state_q)
        // ------------------------------------------------------------
        S_IDLE: begin
          if (start_i) begin
            k_q          <= k_i;
            qx_q         <= px_i;
            qy_q         <= py_i;
            q_inf_q      <= 1'b0;
            // R = O
            px_q         <= 256'd0;
            py_q         <= 256'd0;
            pz_q         <= 256'd0;
            R_is_inf_q   <= 1'b1;
            inf_q        <= 1'b0;
            bit_idx_q    <= 9'd255;
            pt_op_q      <= 1'b0;     // DBL settles combinationally
            state_q      <= S_BIT_DBL;
          end
        end

        // ------------------------------------------------------------
        // Capture R <- 2*R, request ADD next.
        S_BIT_DBL: begin
          if (!R_is_inf_q) begin
            px_q <= pt_rx;
            py_q <= pt_ry;
            pz_q <= pt_rz;
            if (pt_rz == 256'd0) R_is_inf_q <= 1'b1;
          end
          pt_op_q <= 1'b1;            // ADD settles combinationally now
          state_q <= S_BIT_ADD;
        end

        // ------------------------------------------------------------
        // If k bit is 1, capture R <- R + P. Then loop or move to inv.
        S_BIT_ADD: begin
          if (k_q[bit_idx_q[7:0]]) begin
            if (R_is_inf_q) begin
              px_q       <= qx_q;
              py_q       <= qy_q;
              pz_q       <= 256'd1;
              R_is_inf_q <= 1'b0;
            end else begin
              px_q       <= pt_rx;
              py_q       <= pt_ry;
              pz_q       <= pt_rz;
              if (pt_rz == 256'd0) R_is_inf_q <= 1'b1;
            end
          end

          if (bit_idx_q == 9'd0) begin
            // End of bit loop.
            if (R_is_inf_q && !k_q[0]) begin
              inf_q   <= 1'b1;
              state_q <= S_DONE;
            end else if (k_q[0] && R_is_inf_q) begin
              rx_q    <= qx_q;
              ry_q    <= qy_q;
              inf_q   <= 1'b0;
              state_q <= S_DONE;
            end else begin
              state_q <= S_INV_INIT;
            end
          end else begin
            bit_idx_q <= bit_idx_q - 9'd1;
            pt_op_q   <= 1'b0;
            state_q   <= S_BIT_DBL;
          end
        end

        // ------------------------------------------------------------
        // Inversion via Fermat: acc = z^(p-2).
        S_INV_INIT: begin
          inv_acc_q <= 256'd1;
          inv_z_q   <= pz_q;
          inv_idx_q <= 9'd255;
          // Issue the first SQR (acc=1 squared = 1).
          f_a       <= 256'd1;
          f_b       <= 256'd0;
          f_op      <= 2'd3;
          state_q   <= S_INV_SQ;
        end

        // f_r holds acc^2. Capture and request optional multiply.
        S_INV_SQ: begin
          inv_acc_q <= f_r;
          if (P_MINUS_2[inv_idx_q[7:0]]) begin
            // Request multiply by Z.
            f_a   <= f_r;
            f_b   <= inv_z_q;
            f_op  <= 2'd2;
            state_q <= S_INV_CAP;
          end else begin
            if (inv_idx_q == 9'd0) state_q <= S_AFF_ZI2;
            else begin
              inv_idx_q <= inv_idx_q - 9'd1;
              // Issue next SQR using updated acc (= f_r computed above).
              f_a   <= f_r;
              f_b   <= 256'd0;
              f_op  <= 2'd3;
              state_q <= S_INV_SQ;
            end
          end
        end

        // Capture the multiply result, then advance.
        S_INV_CAP: begin
          inv_acc_q <= f_r;
          if (inv_idx_q == 9'd0) begin
            state_q <= S_AFF_ZI2;
          end else begin
            inv_idx_q <= inv_idx_q - 9'd1;
            f_a       <= f_r;
            f_b       <= 256'd0;
            f_op      <= 2'd3;
            state_q   <= S_INV_SQ;
          end
        end

        // ------------------------------------------------------------
        // Affine conversion. After inversion, inv_acc_q holds Z^-1.
        S_AFF_ZI2: begin
          zi_q   <= inv_acc_q;
          f_a    <= inv_acc_q;
          f_b    <= inv_acc_q;
          f_op   <= 2'd3;             // SQR -> Zi^2
          state_q<= S_AFF_X;
        end

        S_AFF_X: begin
          zi2_q  <= f_r;              // Zi^2
          f_a    <= px_q;
          f_b    <= f_r;
          f_op   <= 2'd2;             // X = Xj * Zi^2
          state_q<= S_AFF_ZI3;
        end

        S_AFF_ZI3: begin
          rx_q   <= f_r;              // X
          f_a    <= zi2_q;
          f_b    <= zi_q;
          f_op   <= 2'd2;             // Zi^3 = Zi^2 * Zi
          state_q<= S_AFF_Y;
        end

        S_AFF_Y: begin
          // f_r holds Zi^3 ; request Y.
          f_a    <= py_q;
          f_b    <= f_r;
          f_op   <= 2'd2;
          state_q<= S_AFF_YCAP;
        end

        S_AFF_YCAP: begin
          ry_q   <= f_r;              // Y
          inf_q  <= 1'b0;
          state_q<= S_DONE;
        end

        // ------------------------------------------------------------
        S_DONE: begin
          valid_q <= 1'b1;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign ready_o = (state_q == S_IDLE);
  assign valid_o = valid_q;
  assign rx_o    = rx_q;
  assign ry_o    = ry_q;
  assign inf_o   = inf_q;

endmodule
