# Run PSyclone over the self-contained PSyKAl example in this directory.
#
# This is a miniature of what lfric_core's psyclone_psykal.mk does for real:
# find the .x90 files, look for an optimisation script, and invoke PSyclone
# with `-oalg`/`-opsy` to split the output into the rewritten algorithm layer
# and the generated PSy layer.  The real one also handles preprocessing,
# per-file script overrides, and hand-written PSy-layer overrides; those are
# left out here because they obscure the shape.

PSYCLONE      ?= psyclone
PSYCLONE_KERN ?= psyclone-kern

# The LFRic API needs LFRic's own configuration file, not PSyclone's default:
# it defines the function spaces and, crucially, whether annexed dofs are
# computed -- which changes the generated loop bounds.
LFRIC_CORE ?= ../../../submodules/lfric_core
CONFIG     := $(LFRIC_CORE)/etc/psyclone.cfg

ALG    := algorithm/mini_alg_mod.x90
KERNEL := kernel/mini_matvec_kernel_mod.F90
BUILD  := build

.PHONY: all plain optimised stub clean

all: plain optimised stub

## Generate with no optimisation script: serial, but with distributed-memory
## support -- so halo exchanges and dirty-halo bookkeeping still appear.
plain: | $(BUILD)
	$(PSYCLONE) -api lfric --config $(CONFIG) -d kernel \
	    -oalg $(BUILD)/mini_alg_mod.f90 \
	    -opsy $(BUILD)/mini_alg_mod_psy.f90 \
	    $(ALG)

## The same input through optimisation/global.py: colouring, then OpenMP.
optimised: | $(BUILD)
	$(PSYCLONE) -api lfric --config $(CONFIG) -d kernel \
	    -s ./optimisation/global.py \
	    -oalg $(BUILD)/mini_alg_mod_opt.f90 \
	    -opsy $(BUILD)/mini_alg_mod_psy_opt.f90 \
	    $(ALG)

## The argument list the metadata implies, which is how you check that a
## hand-written kernel agrees with its own metadata.
stub: | $(BUILD)
	$(PSYCLONE_KERN) -gen stub -api lfric $(KERNEL) \
	    -o $(BUILD)/mini_matvec_kernel_stub.f90

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
