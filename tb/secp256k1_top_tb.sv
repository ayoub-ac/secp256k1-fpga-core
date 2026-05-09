// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Top-level testbench wrapper for secp256k1_top.
// Stimulus from tb/sim_main.cpp.

module secp256k1_top_tb (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         start_i,
  input  logic [1:0]   mode_i,
  input  logic [255:0] d_i,
  input  logic [255:0] h_i,
  input  logic [255:0] k_i,
  input  logic [255:0] qx_i,
  input  logic [255:0] qy_i,
  input  logic [255:0] r_i,
  input  logic [255:0] s_i,

  output logic [255:0] qx_o,
  output logic [255:0] qy_o,
  output logic [255:0] r_o,
  output logic [255:0] s_o,
  output logic         low_s_replaced_o,
  output logic         accept_o,
  output logic         err_o,
  output logic         valid_o,
  output logic         ready_o
);

  secp256k1_top u_dut (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .start_i         (start_i),
    .mode_i          (mode_i),
    .d_i             (d_i),
    .h_i             (h_i),
    .k_i             (k_i),
    .qx_i            (qx_i),
    .qy_i            (qy_i),
    .r_i             (r_i),
    .s_i             (s_i),
    .qx_o            (qx_o),
    .qy_o            (qy_o),
    .r_o             (r_o),
    .s_o             (s_o),
    .low_s_replaced_o(low_s_replaced_o),
    .accept_o        (accept_o),
    .err_o           (err_o),
    .valid_o         (valid_o),
    .ready_o         (ready_o)
  );

  // ----------------------------------------------------------------
  secp256k1_assertions u_assert (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .start_i(start_i),
    .ready_o(ready_o),
    .valid_o(valid_o),
    .accept_o(accept_o),
    .err_o   (err_o)
  );

  secp256k1_cov u_cov (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .start_i         (start_i),
    .mode_i          (mode_i),
    .valid_o         (valid_o),
    .accept_o        (accept_o),
    .err_o           (err_o),
    .low_s_replaced_o(low_s_replaced_o),
    .h_i             (h_i),
    .k_i             (k_i)
  );

endmodule
