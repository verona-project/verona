VERONA_EXECUTABLE = $(abs_top_builddir)/build/verona
VERONA_SERVER = $(abs_top_builddir)/build/verona-server
VERONA_LINKER = @VERONA_LINKER@
VERONA_AR = @VERONA_AR@

export VERONA_LINKER VERONA_AR

verona_srcdir = $(shell cd $(top_srcdir) && pwd -P)
# The generated launcher embeds its Lisp entry point and shares bindir with verona.
nodist_bin_SCRIPTS = $(VERONA_SERVER)

verona_lisp_files = $(shell find $(verona_srcdir)/src -type f -name '*.lisp' -print)
EXTRA_DIST = AGENT.md CMakeLists.txt assets/calico.png docs/API.md docs/IDE-WORKFLOWS.md \
	editors/emacs/verona-mode.el editors/emacs/verona-ide.el editors/emacs/verona-server.el editors/emacs/README.md flake.lock flake.nix license projects readme.md \
	scripts src tests verona.asd

.PHONY: help bootstrap build test test-frontend test-llvm test-compiler test-verona test-swank

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
	@printf '%s\n' '  make test-swank     Run optional Swank adapter integration tests'
	@printf '%s\n' '  make test-editor    Run optional Emacs integration tests'
	@printf '%s\n' '  make test-workflows Run all compiler, Swank and editor acceptance tests'

all-local: build

bootstrap: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/bootstrap
	@cd $(verona_srcdir)/projects/bootstrap && $(VERONA_EXECUTABLE) build bootstrap $(abs_top_builddir)/build/bootstrap
	@$(abs_top_builddir)/build/bootstrap/bootstrap

build: $(VERONA_EXECUTABLE) $(VERONA_SERVER)

$(VERONA_EXECUTABLE): $(verona_srcdir)/verona.asd $(verona_srcdir)/scripts/build-executable.lisp $(verona_lisp_files)
	@$(MKDIR_P) $(@D)
	$(SBCL) --script $(verona_srcdir)/scripts/build-executable.lisp $@

$(VERONA_SERVER): $(verona_srcdir)/scripts/verona-server.in $(verona_srcdir)/scripts/ide-server.lisp
	@$(MKDIR_P) $(@D)
	cat $(verona_srcdir)/scripts/verona-server.in $(verona_srcdir)/scripts/ide-server.lisp > $@.tmp
	printf '\nVERONA_EMBEDDED_IDE_SERVER\n' >> $@.tmp
	chmod +x $@.tmp
	mv $@.tmp $@

install-exec-local: $(VERONA_EXECUTABLE)
	$(MKDIR_P) '$(DESTDIR)$(bindir)'
	$(INSTALL_PROGRAM) $(VERONA_EXECUTABLE) '$(DESTDIR)$(bindir)/verona'

uninstall-local:
	$(RM) '$(DESTDIR)$(bindir)/verona'

test: test-frontend test-llvm test-compiler test-verona

test-frontend:
	cd $(verona_srcdir) && $(SBCL) --script tests/run.lisp

# Deliberately separate: the compiler test/build path never requires Swank.
test-swank:
	cd $(verona_srcdir) && $(SBCL) --script tests/run-swank.lisp

test-llvm:
	cd $(verona_srcdir) && $(SBCL) --script tests/run-llvm.lisp

test-compiler:
	cd $(verona_srcdir) && $(SBCL) --script tests/run-compiler.lisp

test-verona: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/testing
	@cd $(verona_srcdir)/projects/testing && $(VERONA_EXECUTABLE) build testing-smoke $(abs_top_builddir)/build/testing
	@$(abs_top_builddir)/build/testing/testing-smoke

clean-local:
	$(RM) $(VERONA_EXECUTABLE) $(VERONA_SERVER) $(VERONA_SERVER).tmp

# Optional editor tests; Emacs and SLIME are not compiler dependencies.
.PHONY: test-editor test-workflows
EMACS = emacs

# Explicit opt-in: ordinary compiler tests do not require Swank or Emacs.
test-workflows: test test-swank test-editor

test-editor:
	cd $(verona_srcdir) && $(EMACS) -Q --batch -L editors/emacs -l tests/editor.el -f ert-run-tests-batch-and-exit

# Explicit real editor/server acceptance; never required by compiler builds.
.PHONY: test-editor-live
test-editor-live: $(VERONA_SERVER)
	@test -n "$(SLIME_DIR)" || { echo 'Set SLIME_DIR to the installed SLIME directory'; exit 1; }
	cd $(verona_srcdir) && $(EMACS) -Q --batch -L "$(SLIME_DIR)" -L editors/emacs -l tests/editor-live.el -f ert-run-tests-batch-and-exit
