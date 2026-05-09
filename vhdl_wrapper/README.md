# VHDL wrapper

`secp256k1_top_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `secp256k1_top` module under a VHDL-friendly interface.
Use it from a VHDL design that does not want to touch SystemVerilog
directly.

## Status

**Wrapper only.** The field arithmetic, point arithmetic, scalar
multiplication FSM, ECDSA sign / verify wrappers, and the streaming top
all live in `rtl/*.sv` and are instantiated as a SystemVerilog
black-box. Mixed-language elaboration is supported by every commercial
simulator and synthesiser the core has been tested against.

A pure VHDL re-implementation of the datapath is on the roadmap (Premium
tier, scope: parity with `rtl/secp256k1_top.sv` including the same
testbench checks). Until then, treat this directory as a binding layer,
not as a second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `secp256k1_top_vhdl.vhd` to the
same project library (`work` is fine). The toolchain resolves the SV
component automatically:

```tcl
# Vivado
read_verilog -sv {rtl/field_secp256k1.sv rtl/scalar_field.sv \
                   rtl/point_secp256k1.sv rtl/scalar_mult.sv \
                   rtl/ecdsa_sign.sv rtl/ecdsa_verify.sv \
                   rtl/secp256k1_top.sv}
read_vhdl -vhdl2008 vhdl_wrapper/secp256k1_top_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/field_secp256k1.sv rtl/scalar_field.sv \
        rtl/point_secp256k1.sv rtl/scalar_mult.sv \
        rtl/ecdsa_sign.sv rtl/ecdsa_verify.sv \
        rtl/secp256k1_top.sv
vcom -2008 vhdl_wrapper/secp256k1_top_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the
two are linked through GHDL's VHPI bridge. The provided `make
vhdl-test` target wraps this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn                            : std_logic;
  signal start, ready, valid                  : std_logic;
  signal mode                                 : std_logic_vector( 1 downto 0);
  signal d, h, k                              : std_logic_vector(255 downto 0);
  signal qx, qy, r, s                         : std_logic_vector(255 downto 0);
  signal qx_o, qy_o, r_o, s_o                 : std_logic_vector(255 downto 0);
  signal low_s, accept, err                   : std_logic;
begin
  u_ecdsa : entity work.secp256k1_top_vhdl
    port map (
      clk_i            => clk,
      rst_ni           => rstn,
      start_i          => start,
      mode_i           => mode,
      d_i              => d,
      h_i              => h,
      k_i              => k,
      qx_i             => qx,
      qy_i             => qy,
      r_i              => r,
      s_i              => s,
      qx_o             => qx_o,
      qy_o             => qy_o,
      r_o              => r_o,
      s_o              => s_o,
      low_s_replaced_o => low_s,
      accept_o         => accept,
      err_o            => err,
      valid_o          => valid,
      ready_o          => ready
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: identical to `secp256k1_top.sv`. There is
  no additional pipeline stage. Per-call latency depends on the mode:
  * key derive: ~1024 cycles (one scalar multiplication)
  * sign: ~1600 cycles (one scalar mult + one mod-n inverse + a handful
    of mod-n muls/adds)
  * verify: ~3200 cycles (two scalar mults + one mod-n inverse + one
    mod-p inverse + an affine sum)
* Endianness: byte 0 of every 256-bit byte-stream message lives at bits
  `[255:248]` of the wide bus (big-endian, matching the
  `coincurve` / libsecp256k1 / Bitcoin Core wire conventions).
* Reset polarity: still active-low synchronous (`rst_ni`).
