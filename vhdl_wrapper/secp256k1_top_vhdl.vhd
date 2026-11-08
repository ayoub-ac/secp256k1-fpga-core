-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog secp256k1_top module.
--
-- This entity exposes the ECDSA streaming top's port list in VHDL syntax.
-- The architecture instantiates the SystemVerilog module by component
-- name; mixed-language elaboration is supported natively by Vivado,
-- Quartus, ModelSim/Questa, and Aldec, and via the GHDL VHPI bridge for
-- open simulation.
--
-- Status: WRAPPER ONLY. The ECDSA datapath itself remains in
-- SystemVerilog (rtl/*.sv). A native VHDL port of the datapath is
-- listed as future work.
--
-- I/O contract: identical to secp256k1_top.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * Mode select: 00 = key derive, 01 = sign, 10 = verify.
--   * 256-bit private key, 256-bit hash, 256-bit nonce, 256-bit (Qx, Qy)
--     public key, 256-bit (r, s) signature.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity secp256k1_top_vhdl is
  port (
    clk_i              : in  std_logic;
    rst_ni             : in  std_logic;

    start_i            : in  std_logic;
    mode_i             : in  std_logic_vector(  1 downto 0);

    d_i                : in  std_logic_vector(255 downto 0);
    h_i                : in  std_logic_vector(255 downto 0);
    k_i                : in  std_logic_vector(255 downto 0);
    qx_i               : in  std_logic_vector(255 downto 0);
    qy_i               : in  std_logic_vector(255 downto 0);
    r_i                : in  std_logic_vector(255 downto 0);
    s_i                : in  std_logic_vector(255 downto 0);

    qx_o               : out std_logic_vector(255 downto 0);
    qy_o               : out std_logic_vector(255 downto 0);
    r_o                : out std_logic_vector(255 downto 0);
    s_o                : out std_logic_vector(255 downto 0);
    low_s_replaced_o   : out std_logic;
    accept_o           : out std_logic;
    err_o              : out std_logic;
    valid_o            : out std_logic;
    ready_o            : out std_logic
  );
end entity secp256k1_top_vhdl;

architecture rtl of secp256k1_top_vhdl is

  component secp256k1_top
    port (
      clk_i              : in  std_logic;
      rst_ni             : in  std_logic;
      start_i            : in  std_logic;
      mode_i             : in  std_logic_vector(  1 downto 0);
      d_i                : in  std_logic_vector(255 downto 0);
      h_i                : in  std_logic_vector(255 downto 0);
      k_i                : in  std_logic_vector(255 downto 0);
      qx_i               : in  std_logic_vector(255 downto 0);
      qy_i               : in  std_logic_vector(255 downto 0);
      r_i                : in  std_logic_vector(255 downto 0);
      s_i                : in  std_logic_vector(255 downto 0);
      qx_o               : out std_logic_vector(255 downto 0);
      qy_o               : out std_logic_vector(255 downto 0);
      r_o                : out std_logic_vector(255 downto 0);
      s_o                : out std_logic_vector(255 downto 0);
      low_s_replaced_o   : out std_logic;
      accept_o           : out std_logic;
      err_o              : out std_logic;
      valid_o            : out std_logic;
      ready_o            : out std_logic
    );
  end component;

begin

  u_secp : secp256k1_top
    port map (
      clk_i            => clk_i,
      rst_ni           => rst_ni,
      start_i          => start_i,
      mode_i           => mode_i,
      d_i              => d_i,
      h_i              => h_i,
      k_i              => k_i,
      qx_i             => qx_i,
      qy_i             => qy_i,
      r_i              => r_i,
      s_i              => s_i,
      qx_o             => qx_o,
      qy_o             => qy_o,
      r_o              => r_o,
      s_o              => s_o,
      low_s_replaced_o => low_s_replaced_o,
      accept_o         => accept_o,
      err_o            => err_o,
      valid_o          => valid_o,
      ready_o          => ready_o
    );

end architecture rtl;
