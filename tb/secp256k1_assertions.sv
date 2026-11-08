// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// SVA assertions for secp256k1_top. Properties hold on every cycle of
// every test:
//
//   p_no_valid_before_start : valid_o cannot pulse before any start_i
//                             has been seen since reset.
//   p_ready_after_done      : ready_o re-asserts within LAT_MAX cycles
//                             after a start_i (catches stuck FSM in
//                             the scalar_mult or inversion loop).
//   p_no_accept_on_err      : err_o = 1 implies accept_o = 0 (sign-mode
//                             error path is mutually exclusive with the
//                             verify-accept path).
//   p_valid_one_pulse       : valid_o is at most one cycle high per
//                             session (single-pulse semantics).
//   p_start_lockout         : start_i must not be asserted while ready_o
//                             is low (the core ignores it; the assertion
//                             flags integrator misuse).
//
// LAT_MAX is 8192 cycles; actual session is ~1024-3200 cycles. The
// generous bound only fires if the FSM is genuinely wedged.

module secp256k1_assertions #(
  parameter int LAT_MAX = 8192
) (
  input logic clk_i,
  input logic rst_ni,
  input logic start_i,
  input logic ready_o,
  input logic valid_o,
  input logic accept_o,
  input logic err_o
);
`ifndef SYNTHESIS

  logic start_seen_q       = 1'b0;
  int   cycles_since_start = 0;
  logic in_session_q       = 1'b0;
  logic valid_seen_q       = 1'b0;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      start_seen_q       <= 1'b0;
      cycles_since_start <= 0;
      in_session_q       <= 1'b0;
      valid_seen_q       <= 1'b0;
    end else begin
      if (start_i && ready_o) begin
        start_seen_q       <= 1'b1;
        cycles_since_start <= 0;
        in_session_q       <= 1'b1;
        valid_seen_q       <= 1'b0;
      end else if (in_session_q) begin
        cycles_since_start <= cycles_since_start + 1;
      end
      if (valid_o) begin
        valid_seen_q <= 1'b1;
        in_session_q <= 1'b0;
      end
    end
  end

  // 1. valid_o never pulses before any start_i has been seen.
  property p_no_valid_before_start;
    @(posedge clk_i) disable iff (!rst_ni)
      valid_o |-> start_seen_q;
  endproperty
  a_no_valid_before_start: assert property (p_no_valid_before_start)
    else $error("secp256k1: valid_o pulsed before any start_i");

  // 2. ready_o eventually re-asserts (within LAT_MAX) after a start.
  property p_ready_eventually;
    @(posedge clk_i) disable iff (!rst_ni)
      in_session_q |-> (cycles_since_start < LAT_MAX);
  endproperty
  a_ready_eventually: assert property (p_ready_eventually)
    else $error("secp256k1: session did not finish within %0d cycles", LAT_MAX);

  // 3. err and accept cannot both be high.
  property p_no_accept_on_err;
    @(posedge clk_i) disable iff (!rst_ni)
      err_o |-> !accept_o;
  endproperty
  a_no_accept_on_err: assert property (p_no_accept_on_err)
    else $error("secp256k1: err_o and accept_o both asserted");

  // 4. valid_o is at most one cycle per session.
  property p_valid_one_pulse;
    @(posedge clk_i) disable iff (!rst_ni || (start_i && ready_o))
      valid_o |-> !valid_seen_q;
  endproperty
  a_valid_one_pulse: assert property (p_valid_one_pulse)
    else $error("secp256k1: valid_o pulsed twice within one session");

  // 5. start_i should not be raised while ready_o is low.
  property p_start_lockout;
    @(posedge clk_i) disable iff (!rst_ni)
      start_i |-> ready_o;
  endproperty
  a_start_lockout: assert property (p_start_lockout)
    else $error("secp256k1: start_i raised while ready_o low (ignored by core)");

`endif
endmodule
