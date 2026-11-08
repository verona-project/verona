# The seed runs the root manifest; Make owns orchestration, never compiler policy.
VERONA_SEED = @VERONA_SEED@
VERONA = $(abs_top_builddir)/build/compiler/verona
VERONA_FORMATTER = $(abs_top_builddir)/build/formatter/verona-formatter
VERONA_PROJECT = $(abs_top_builddir)/build/project/verona-project

PYTHON = @PYTHON@
LLVM_CONFIG = @LLVM_CONFIG@
VERONA_LLVM_LIBDIR = @LLVM_LIBDIR@
VERONA_CORE_CLANG = @VERONA_CORE_CLANG@
VERONA_CORE_AR = @VERONA_CORE_AR@
VERONA_LINKER = @VERONA_LINKER@
VERONA_AR = @VERONA_AR@

# Preserve any caller-supplied paths while ensuring the configured LLVM shared
# library is found by both the compiler and executables produced during tests.
LIBRARY_PATH := $(VERONA_LLVM_LIBDIR)$(if $(LIBRARY_PATH),:$(LIBRARY_PATH))
LD_LIBRARY_PATH := $(VERONA_LLVM_LIBDIR)$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
DYLD_LIBRARY_PATH := $(VERONA_LLVM_LIBDIR)$(if $(DYLD_LIBRARY_PATH),:$(DYLD_LIBRARY_PATH))
export LLVM_CONFIG VERONA_CORE_CLANG VERONA_CORE_AR VERONA_LINKER VERONA_AR
export LIBRARY_PATH LD_LIBRARY_PATH DYLD_LIBRARY_PATH

verona_srcdir = $(shell cd $(top_srcdir) && pwd -P)
verona_sources = $(shell find $(verona_srcdir)/src $(verona_srcdir)/projects/base/src $(verona_srcdir)/projects/foundation/src $(verona_srcdir)/projects/libc/src $(verona_srcdir)/projects/llvm/src -type f -name '*.vrn' -print)
compiler_test_sources = $(shell find $(verona_srcdir)/tests $(verona_srcdir)/projects/testing/src -type f \( -name '*.vrn' -o -name '*.py' -o -name '*.json' \) -print)

EXTRA_DIST = \
	AGENTS.md flake.nix flake.lock license readme.md verona.build \
	docs assets src tests projects

.PHONY: help build formatter project compiler-tests check test test-python test-verona

help:
	@printf '%s\n' 'Verona self-hosted compiler commands:'
	@printf '%s\n' '  ./configure --with-seed=/path/to/verona  Configure a build'
	@printf '%s\n' '  make build                           Build compiler and root tools'
	@printf '%s\n' '  make check                           Run Python and Verona test suites'
	@printf '%s\n' '  make install                         Install verona, formatter, and project tool'

all-local: build

build: $(VERONA) $(VERONA_FORMATTER) $(VERONA_PROJECT)

$(VERONA): $(verona_srcdir)/verona.build $(verona_sources)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir) && $(VERONA_SEED) build verona $(@D)

$(VERONA_FORMATTER): $(VERONA) $(verona_srcdir)/verona.build $(verona_sources)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir) && $(VERONA) build verona-formatter $(@D)

$(VERONA_PROJECT): $(VERONA) $(verona_srcdir)/verona.build $(verona_sources)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir) && $(VERONA) build verona-project $(@D)

formatter: $(VERONA_FORMATTER)
project: $(VERONA_PROJECT)

compiler-tests: $(VERONA) $(verona_srcdir)/verona.build $(verona_sources) $(compiler_test_sources)
	@$(MKDIR_P) $(abs_top_builddir)/build/compiler-tests
	cd $(verona_srcdir) && $(VERONA) build compiler-tests $(abs_top_builddir)/build/compiler-tests

test-python: $(VERONA) $(VERONA_PROJECT)
	cd $(verona_srcdir) && VERONA_REFERENCE=$(VERONA_SEED) $(PYTHON) tests/test_core.py $(VERONA)
	cd $(verona_srcdir) && $(PYTHON) tests/shared_suite.py $(VERONA)
	cd $(verona_srcdir) && $(PYTHON) tests/test_project.py $(VERONA_PROJECT)

test-verona: compiler-tests
	$(abs_top_builddir)/build/compiler-tests/compiler-tests

check: test-python test-verona
test: check

install-exec-local: build
	$(MKDIR_P) '$(DESTDIR)$(bindir)'
	$(INSTALL_PROGRAM) $(VERONA) '$(DESTDIR)$(bindir)/verona'
	$(INSTALL_PROGRAM) $(VERONA_FORMATTER) '$(DESTDIR)$(bindir)/verona-formatter'
	$(INSTALL_PROGRAM) $(VERONA_PROJECT) '$(DESTDIR)$(bindir)/verona-project'

uninstall-local:
	$(RM) '$(DESTDIR)$(bindir)/verona' '$(DESTDIR)$(bindir)/verona-formatter' '$(DESTDIR)$(bindir)/verona-project'

clean-local:
	$(RM) $(VERONA) $(VERONA_FORMATTER) $(VERONA_PROJECT)
	$(RM) $(abs_top_builddir)/build/compiler-tests/compiler-tests
