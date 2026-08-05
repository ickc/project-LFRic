# A scratch build area for Fortran.
#
# Drop any .f90 file in this directory and `make`: every file containing a
# `program` becomes an executable in build/, everything else becomes an object,
# and the build order is worked out for you.
#
# Working that order out is the part that has no analogue in C. There are no
# header files in Fortran: compiling a module *emits* a binary interface file
# (.mod), and every `use` of that module *reads* it. So the objects have a
# dependency DAG that is invisible in the file names, and `make` needs to be
# told. fortdep.py scans the sources and writes those rules into build/deps.mk;
# LFRic's build system, fab, does the same job with more care.

BUILD  ?= build

# `?=` is not enough for FC: make ships a built-in definition (f77), so FC is
# already "defined" and `?=` would leave it alone. Testing $(origin ...)
# overrides make's own default while still respecting a value the user set on
# the command line or in the environment.
ifneq ($(filter default undefined,$(origin FC)),)
  FC := gfortran
endif

# -std=f2018 keeps the examples honest about what is standard.
# -fcheck=bounds turns the classic Fortran silent-corruption bug into an
#  error message. It costs real time; drop it for anything you are timing.
ifneq ($(filter default undefined,$(origin FFLAGS)),)
  FFLAGS := -O2 -g -Wall -std=f2018 -fimplicit-none -fcheck=bounds -fbacktrace
endif
OMPFLAGS ?= -fopenmp

SRCS := $(sort $(wildcard *.f90))
OBJS := $(patsubst %.f90,$(BUILD)/%.o,$(SRCS))

.DEFAULT_GOAL := all
.PHONY: all run clean help

$(BUILD):
	@mkdir -p $(BUILD)

# The scanner runs before anything else; make restarts itself once deps.mk
# has been (re)generated.
$(BUILD)/deps.mk: $(SRCS) fortdep.py | $(BUILD)
	@python3 fortdep.py $(BUILD) $(SRCS) > $@

ifeq (,$(filter clean help,$(MAKECMDGOALS)))
-include $(BUILD)/deps.mk
endif

# -J is where .mod files are written, -I where they are looked for. Both point
# at build/ so nothing lands in the source directory.
$(BUILD)/%.o: %.f90 | $(BUILD)
	$(FC) $(FFLAGS) $(OMPFLAGS) -J$(BUILD) -I$(BUILD) -c $< -o $@

$(PROGRAMS): $(BUILD)/%: $(BUILD)/%.o
	$(FC) $(FFLAGS) $(OMPFLAGS) -J$(BUILD) -I$(BUILD) $^ -o $@

all: $(PROGRAMS)

run: all
	@for p in $(PROGRAMS); do \
	  echo "=== $$p ==="; \
	  case $$p in \
	    */cli_demo) $$p --levels=30 -v mesh_C24.nc ;; \
	    *) $$p ;; \
	  esac; \
	done

clean:
	rm -rf $(BUILD)

help:
	@echo 'make       build every program into $(BUILD)/'
	@echo 'make run   build, then run them'
	@echo 'make clean remove $(BUILD)/'
	@echo
	@echo 'Variables: FC=$(FC) FFLAGS=$(FFLAGS)'
