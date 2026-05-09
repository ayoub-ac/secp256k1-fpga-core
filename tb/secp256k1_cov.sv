// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage collector for secp256k1_top. Sticky bins recorded
// across the regression so the harness can print a single coverage line
// at end-of-test.
//
// Bins (10 total):
//   c_mode_key       : a key_derive session
//   c_mode_sign      : a sign session
//   c_mode_verify    : a verify session
//   c_verify_accept  : at least one verify session that returned accept=1
//   c_verify_reject  : at least one verify session that returned accept=0
//   c_sign_low_s     : at least one sign session that triggered low-S
//                      replacement (s > n/2 normalised)
//   c_sign_err       : at least one sign session that hit r=0 or s=0
//                      (caller must retry with new nonce)
//   c_msg_zero       : a session with h_i = 0 (edge case)
//   c_msg_high       : a session with h_i in upper half of range
//   c_nonce_small    : a sign session with k_i < 2^64 (small-nonce edge)

module secp256k1_cov (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         start_i,
  input logic [1:0]   mode_i,
  input logic         valid_o,
  input logic         accept_o,
  input logic         err_o,
  input logic         low_s_replaced_o,
  input logic [255:0] h_i,
  input logic [255:0] k_i
);

  logic c_mode_key      /*verilator public*/;
  logic c_mode_sign     /*verilator public*/;
  logic c_mode_verify   /*verilator public*/;
  logic c_verify_accept /*verilator public*/;
  logic c_verify_reject /*verilator public*/;
  logic c_sign_low_s    /*verilator public*/;
  logic c_sign_err      /*verilator public*/;
  logic c_msg_zero      /*verilator public*/;
  logic c_msg_high      /*verilator public*/;
  logic c_nonce_small   /*verilator public*/;

  // Latch the mode of the active session so we can attribute valid_o
  // outcomes (accept/reject/err/low_s) to it.
  logic [1:0] active_mode_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      active_mode_q <= 2'd0;
    end else begin
      if (start_i) begin
        active_mode_q <= mode_i;
        case (mode_i)
          2'd0: c_mode_key    <= 1'b1;
          2'd1: c_mode_sign   <= 1'b1;
          2'd2: c_mode_verify <= 1'b1;
          default: ;
        endcase
        if (h_i == 256'd0)            c_msg_zero  <= 1'b1;
        if (h_i[255])                  c_msg_high  <= 1'b1;
        if (mode_i == 2'd1 && k_i[255:64] == 192'd0) c_nonce_small <= 1'b1;
      end

      if (valid_o) begin
        if (active_mode_q == 2'd2) begin
          if (accept_o) c_verify_accept <= 1'b1;
          else          c_verify_reject <= 1'b1;
        end
        if (active_mode_q == 2'd1) begin
          if (low_s_replaced_o) c_sign_low_s <= 1'b1;
          if (err_o)            c_sign_err   <= 1'b1;
        end
      end
    end
  end

  initial begin
    c_mode_key      = 1'b0;
    c_mode_sign     = 1'b0;
    c_mode_verify   = 1'b0;
    c_verify_accept = 1'b0;
    c_verify_reject = 1'b0;
    c_sign_low_s    = 1'b0;
    c_sign_err      = 1'b0;
    c_msg_zero      = 1'b0;
    c_msg_high      = 1'b0;
    c_nonce_small   = 1'b0;
  end

endmodule
