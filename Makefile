# secp256k1 ECDSA FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint            verilator --lint-only on RTL (field + scalar
#                        field + point + scalar mult + sign + verify
#                        + top)
#   make sim             build the secp256k1 top simulator
#   make test            build + run sim, check for "+PASS"
#   make synth           Yosys: ice40 + ecp5 + xilinx generic for the top
#   make synth_report    run all available toolchains and emit SYNTH_REPORT.md
#   make vhdl-test       GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make clean           remove build artifacts
#   make regen_vectors   regenerate tb/random_vectors.h from coincurve

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

RTL := \
    rtl/field_secp256k1.sv \
    rtl/scalar_field.sv \
    rtl/point_secp256k1.sv \
    rtl/scalar_mult.sv \
    rtl/ecdsa_sign.sv \
    rtl/ecdsa_verify.sv \
    rtl/secp256k1_top.sv

TB_TOP := tb/secp256k1_top_tb.sv
TB_AUX := tb/secp256k1_assertions.sv tb/secp256k1_cov.sv
TB_CPP := tb/sim_main.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: lint sim test synth synth_report vhdl-test clean regen_vectors

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module secp256k1_top_tb \
	    $(RTL) $(TB_TOP) $(TB_AUX)

sim: obj_dir/Vsecp256k1_top_tb

obj_dir/Vsecp256k1_top_tb: $(RTL) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
                           tb/random_vectors.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module secp256k1_top_tb \
	    $(RTL) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
	    -o Vsecp256k1_top_tb

test: sim
	./obj_dir/Vsecp256k1_top_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv $(RTL); hierarchy -top secp256k1_top; synth_ice40 -top secp256k1_top; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv $(RTL); hierarchy -top secp256k1_top; synth_ecp5 -top secp256k1_top -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv $(RTL); hierarchy -top secp256k1_top; synth_xilinx -top secp256k1_top; stat" \
	    | tee synth_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

clean:
	rm -rf obj_dir \
	    test.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log \
	    synth_report/ SYNTH_REPORT.md

regen_vectors:
	python3 tb/gen_random_vectors.py > tb/random_vectors.h
