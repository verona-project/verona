VERONA_EXECUTABLE := build/verona
VERONA_SOURCES := $(shell find src -type f -name '*.lisp' -print)

.PHONY: help bootstrap build test test-llvm test-verona

help:
	@printf '%s\n' 'Verona development commands:'
	@printf '%s\n' '  make bootstrap  Check and explain the Verona package environment'
	@printf '%s\n' '  make build Build the standalone verona executable'
	@printf '%s\n' '  make test  Run the FiveAM front-end test suite'
	@printf '%s\n' '  make test-llvm  Run the FiveAM LLVM backend test suite'
	@printf '%s\n' '  make test-verona  Build and run the Verona testing-library smoke suite'

bootstrap: $(VERONA_EXECUTABLE)
	@mkdir -p build/bootstrap
	@cd projects/bootstrap && ../../$(VERONA_EXECUTABLE) build bootstrap ../../build/bootstrap
	@build/bootstrap/bootstrap

build: $(VERONA_EXECUTABLE)

$(VERONA_EXECUTABLE): verona.asd scripts/build-executable.lisp $(VERONA_SOURCES)
	@mkdir -p $(@D)
	sbcl --script scripts/build-executable.lisp $@

test:
	sbcl --script tests/run.lisp

test-llvm:
	sbcl --script tests/run-llvm.lisp

test-verona: $(VERONA_EXECUTABLE)
	@mkdir -p build/testing
	@cd projects/testing && ../../$(VERONA_EXECUTABLE) build testing-smoke ../../build/testing
	@build/testing/testing-smoke
