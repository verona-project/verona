VERONA_EXECUTABLE = $(abs_top_builddir)/build/verona
VERONA_LINKER = @VERONA_LINKER@
VERONA_AR = @VERONA_AR@

export VERONA_LINKER VERONA_AR

verona_srcdir = $(shell cd $(top_srcdir) && pwd -P)
verona_lisp_files = $(shell find $(verona_srcdir)/src -type f -name '*.lisp' -print)
EXTRA_DIST = AGENT.md CMakeLists.txt assets/calico.png docs/API.md \
	editors/emacs/verona-mode.el flake.lock flake.nix license projects readme.md \
	scripts src tests verona.asd

.PHONY: help bootstrap build test test-frontend test-llvm test-compiler test-verona

help:
	@printf '%s\n' 'Verona development commands:'
	@printf '%s\n' '  make bootstrap      Check and run the Verona package-environment tutorial'
	@printf '%s\n' '  make build          Build the standalone verona executable'
	@printf '%s\n' '  make install        Install verona (configure --prefix=/path to change it)'
	@printf '%s\n' '  make test           Run every test runner'
	@printf '%s\n' '  make test-frontend  Run front-end and module-semantic tests'
	@printf '%s\n' '  make test-llvm      Run LLVM backend integration tests'
	@printf '%s\n' '  make test-compiler  Run compiler-driver, CLI, and build tests'
	@printf '%s\n' '  make test-verona    Build and run the supplied Verona project smoke suite'

all-local: build

bootstrap: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/bootstrap
	@cd $(verona_srcdir)/projects/bootstrap && $(VERONA_EXECUTABLE) build bootstrap $(abs_top_builddir)/build/bootstrap
	@$(abs_top_builddir)/build/bootstrap/bootstrap

build: $(VERONA_EXECUTABLE)

$(VERONA_EXECUTABLE): $(verona_srcdir)/verona.asd $(verona_srcdir)/scripts/build-executable.lisp $(verona_lisp_files)
	@$(MKDIR_P) $(@D)
	$(SBCL) --script $(verona_srcdir)/scripts/build-executable.lisp $@

install-exec-local: $(VERONA_EXECUTABLE)
	$(MKDIR_P) '$(DESTDIR)$(bindir)'
	$(INSTALL_PROGRAM) $(VERONA_EXECUTABLE) '$(DESTDIR)$(bindir)/verona'

uninstall-local:
	$(RM) '$(DESTDIR)$(bindir)/verona'

test: test-frontend test-llvm test-compiler test-verona

test-frontend:
	cd $(verona_srcdir) && $(SBCL) --script tests/run.lisp

test-llvm:
	cd $(verona_srcdir) && $(SBCL) --script tests/run-llvm.lisp

test-compiler:
	cd $(verona_srcdir) && $(SBCL) --script tests/run-compiler.lisp

test-verona: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/testing
	@cd $(verona_srcdir)/projects/testing && $(VERONA_EXECUTABLE) build testing-smoke $(abs_top_builddir)/build/testing
	@$(abs_top_builddir)/build/testing/testing-smoke

clean-local:
	$(RM) $(VERONA_EXECUTABLE)
