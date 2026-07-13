# Grotti — a Stratum V1 CPU/GPU miner in pure Odin.
#
#   make            build the optimized binary  →  ./grotti
#   make test       run the unit + differential test suites
#   make check      type-check the CLI without producing a binary
#   make clean      remove built binaries
#
# -o:speed is mandatory for anything hashrate-related (CLAUDE.md § Build); the default
# target uses it. GPU backends need no build-time toolkit — CUDA/Vulkan are dlopen'd at
# runtime and Metal is compiled from embedded source, so a plain `make` produces a
# GPU-capable binary on any box.

ODIN    ?= odin
BIN     ?= grotti
VERSION ?= 0.1.0-dev

.PHONY: all build test check clean

all: build

build:
	$(ODIN) build cli -out:$(BIN) -o:speed -define:GROTTI_VERSION=$(VERSION)

test:
	$(ODIN) test .
	$(ODIN) test sha256d
	$(ODIN) test keygen

check:
	$(ODIN) check cli

clean:
	rm -f $(BIN) $(BIN).exe
