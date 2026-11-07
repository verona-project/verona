VERONA_EXECUTABLE = $(abs_top_builddir)/build/verona
VERONA_FORMATTER = $(abs_top_builddir)/build/formatter/verona-fmt
VERONA_PROJECT = $(abs_top_builddir)/build/project/verona-project
VERONA_SERVER = $(abs_top_builddir)/build/verona-server
VERONA_LINKER = @VERONA_LINKER@
VERONA_AR = @VERONA_AR@

export VERONA_LINKER VERONA_AR

verona_srcdir = $(shell cd $(top_srcdir) && pwd -P)
# The generated launcher embeds its Lisp entry point and shares bindir with verona.
nodist_bin_SCRIPTS = $(VERONA_SERVER)

# Include submodule sources in archives without Git metadata pointers.
cl_llvm_files = $(shell cd $(verona_srcdir) && find vendor/CL-LLVM -type f ! -name .git -print)
project_dist_files = $(shell cd $(verona_srcdir) && find projects -type f ! -name .git -print)
verona_project_files = $(shell find $(verona_srcdir)/projects/project $(verona_srcdir)/projects/base/src $(verona_srcdir)/projects/libc/src -type f -name '*.vrn' -print)
verona_formatter_files = $(shell find $(verona_srcdir)/projects/formatter/src $(verona_srcdir)/projects/foundation/src $(verona_srcdir)/projects/base/src $(verona_srcdir)/projects/libc/src -type f -name '*.vrn' -print)
verona_lisp_files = $(shell find $(verona_srcdir)/src -type f -name '*.lisp' -print)
EXTRA_DIST = AGENT.md CMakeLists.txt assets/calico.png docs/API.md docs/compiler-roadmap.org docs/compiler-boolean-operations.org docs/self-hosted-project-audit.md docs/IDE-WORKFLOWS.md \
	editors/emacs/verona-mode.el editors/emacs/verona-ide.el editors/emacs/verona-server.el editors/emacs/README.md flake.lock flake.nix license $(project_dist_files) readme.md \
	scripts src tests $(cl_llvm_files) verona.asd

.PHONY: help bootstrap build test test-frontend test-llvm test-compiler test-verona test-bounded test-foundation formatter test-formatter test-swank

help:
	@printf '%s\n' 'Verona development commands:'
	@printf '%s\n' '  make bootstrap      Check and run the Verona package-environment tutorial'
	@printf '%s\n' '  make build          Build Verona and its standalone tools'
	@printf '%s\n' '  make release RELEASE_VERSION=X.Y.Z  Build a versioned release zip'
	@printf '%s\n' '  make project        Build the Verona project management tool'
	@printf '%s\n' '  make install        Install Verona and its tools (configure --prefix=/path)'
	@printf '%s\n' '  make test           Run every test runner'
	@printf '%s\n' '  make test-frontend  Run front-end and module-semantic tests'
	@printf '%s\n' '  make test-llvm      Run LLVM backend integration tests'
	@printf '%s\n' '  make test-compiler  Run compiler-driver, CLI, and build tests'
	@printf '%s\n' '  make test-verona    Build and run the supplied Verona project smoke suite'
	@printf '%s\n' '  make test-foundation Build and run the Verona Foundation suite'
	@printf '%s\n' '  make test-bounded   Build and run Base bounded unit tests'
	@printf '%s\n' '  make formatter      Build the Verona source formatter'
	@printf '%s\n' '  make test-formatter Run formatter unit, CLI, and reader-equivalence tests'
	@printf '%s\n' '  make llvm-bindings  Build the Verona LLVM binding library'
	@printf '%s\n' '  make test-llvm-bindings Run native LLVM binding acceptance tests'
	@printf '%s\n' '  make test-compiler-support Run compiler support unit tests'
	@printf '%s\n' '  make compiler-core  Build the compiler and evaluator written in Verona'
	@printf '%s\n' '  make test-compiler-core Compare core evaluation with native LLVM execution'
	@printf '%s\n' '  make bootstrap-compiler Run recorded A/B/C self-hosting validation'
	@printf '%s\n' '  make test-self-hosted-projects SELF_HOSTED_COMPILER=/path/to/verona-core'
	@printf '%s\n' '  make verify-compiler-release Validate a clean revision in an isolated checkout'
	@printf '%s\n' '  make test-swank     Run optional Swank adapter integration tests'
	@printf '%s\n' '  make test-editor    Run optional Emacs integration tests'
	@printf '%s\n' '  make test-workflows Run all compiler, Swank and editor acceptance tests'

all-local: build

bootstrap: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/bootstrap
	@cd $(verona_srcdir)/projects/bootstrap && $(VERONA_EXECUTABLE) build bootstrap $(abs_top_builddir)/build/bootstrap
	@$(abs_top_builddir)/build/bootstrap/bootstrap

build: $(VERONA_EXECUTABLE) $(VERONA_SERVER) $(VERONA_PROJECT) $(VERONA_FORMATTER)

$(VERONA_EXECUTABLE): $(verona_srcdir)/verona.asd $(verona_srcdir)/scripts/build-executable.lisp $(verona_lisp_files)
	@$(MKDIR_P) $(@D)
	$(SBCL) --script $(verona_srcdir)/scripts/build-executable.lisp $@

$(VERONA_SERVER): $(verona_srcdir)/scripts/verona-server.in $(verona_srcdir)/scripts/ide-server.lisp
	@$(MKDIR_P) $(@D)
	cat $(verona_srcdir)/scripts/verona-server.in $(verona_srcdir)/scripts/ide-server.lisp > $@.tmp
	printf '\nVERONA_EMBEDDED_IDE_SERVER\n' >> $@.tmp
	chmod +x $@.tmp
	mv $@.tmp $@

$(VERONA_PROJECT): $(VERONA_EXECUTABLE) $(verona_srcdir)/projects/project/verona.build $(verona_project_files)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir)/projects/project && $(VERONA_EXECUTABLE) build verona-project $(@D)

.PHONY: project
project: $(VERONA_PROJECT)

install-exec-local: $(VERONA_EXECUTABLE) $(VERONA_PROJECT) $(VERONA_FORMATTER)
	$(MKDIR_P) '$(DESTDIR)$(bindir)'
	$(INSTALL_PROGRAM) $(VERONA_EXECUTABLE) '$(DESTDIR)$(bindir)/verona'
	$(INSTALL_PROGRAM) $(VERONA_PROJECT) '$(DESTDIR)$(bindir)/verona-project'
	$(INSTALL_PROGRAM) $(VERONA_FORMATTER) '$(DESTDIR)$(bindir)/verona-fmt'

uninstall-local:
	$(RM) '$(DESTDIR)$(bindir)/verona' '$(DESTDIR)$(bindir)/verona-project' '$(DESTDIR)$(bindir)/verona-fmt'

test: test-frontend test-llvm test-compiler test-verona test-bounded test-foundation test-formatter test-compiler-core test-llvm-bindings test-compiler-support test-self-hosted-projects-runner test-compiler-release-runner

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

test-bounded: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/base
	@cd $(verona_srcdir)/projects/base/tests && $(VERONA_EXECUTABLE) build bounded-tests $(abs_top_builddir)/build/base
	@$(abs_top_builddir)/build/base/bounded-tests

test-foundation: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/foundation
	@cd $(verona_srcdir)/projects/foundation && $(VERONA_EXECUTABLE) build foundation-tests $(abs_top_builddir)/build/foundation
	@$(abs_top_builddir)/build/foundation/foundation-tests

formatter: $(VERONA_FORMATTER)

$(VERONA_FORMATTER): $(VERONA_EXECUTABLE) $(verona_srcdir)/projects/formatter/verona.build $(verona_formatter_files)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir)/projects/formatter && $(VERONA_EXECUTABLE) build verona-fmt $(@D)

test-formatter: formatter
	@cd $(verona_srcdir)/projects/formatter && $(VERONA_EXECUTABLE) build formatter-tests $(abs_top_builddir)/build/formatter
	@$(abs_top_builddir)/build/formatter/formatter-tests
	@$(SBCL) --script $(verona_srcdir)/projects/formatter/tests/run-integration.lisp $(abs_top_builddir)/build/formatter/verona-fmt

clean-local:
	$(RM) $(VERONA_EXECUTABLE) $(VERONA_FORMATTER) $(VERONA_PROJECT) $(VERONA_SERVER) $(VERONA_SERVER).tmp $(VERONA_CORE) $(VERONA_LLVM_LIBRARY) $(VERONA_LLVM_TESTS)

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

# Release inputs are versioned in a temporary copy, including submodules.
PYTHON = python3
RELEASE_VERSION = $(PACKAGE_VERSION)
RELEASE_OUTPUT = $(abs_top_builddir)/build/releases
.PHONY: release test-release
release:
	$(PYTHON) $(verona_srcdir)/scripts/release.py --version "$(RELEASE_VERSION)" --output "$(RELEASE_OUTPUT)"

test-release:
	$(PYTHON) $(verona_srcdir)/tests/test-release.py

# The independently designed core compiler/evaluator is bootstrapped by Verona.
VERONA_CORE = $(abs_top_builddir)/build/compiler/verona-core
verona_core_files = $(shell find $(verona_srcdir)/projects/compiler/src $(verona_srcdir)/projects/llvm/src $(verona_srcdir)/projects/foundation/src $(verona_srcdir)/projects/base/src $(verona_srcdir)/projects/libc/src -type f -name '*.vrn' -print)
.PHONY: compiler-core test-compiler-core bootstrap-compiler
compiler-core: $(VERONA_CORE)

$(VERONA_CORE): $(VERONA_EXECUTABLE) $(verona_srcdir)/projects/compiler/verona.build $(verona_core_files)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir)/projects/compiler && $(VERONA_EXECUTABLE) build verona-core $(@D)

test-compiler-core: compiler-core
	$(SBCL) --script $(verona_srcdir)/tests/run-core.lisp $(VERONA_CORE)
	$(PYTHON) $(verona_srcdir)/projects/compiler/tests/test_core.py $(VERONA_CORE)
	$(PYTHON) $(verona_srcdir)/projects/compiler/tests/shared_suite.py $(VERONA_CORE)

# LLVM bindings are independently consumable Verona source modules.
VERONA_LLVM_LIBRARY = $(abs_top_builddir)/build/llvm/libverona-llvm.a
VERONA_LLVM_TESTS = $(abs_top_builddir)/build/llvm/llvm-tests
verona_llvm_files = $(shell find $(verona_srcdir)/projects/llvm/src $(verona_srcdir)/projects/base/src -type f -name '*.vrn' -print)
.PHONY: llvm-bindings test-llvm-bindings
llvm-bindings: $(VERONA_LLVM_LIBRARY)

$(VERONA_LLVM_LIBRARY): $(VERONA_EXECUTABLE) $(verona_srcdir)/projects/llvm/verona.build $(verona_llvm_files)
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir)/projects/llvm && $(VERONA_EXECUTABLE) build verona-llvm $(@D)

$(VERONA_LLVM_TESTS): $(VERONA_EXECUTABLE) $(verona_srcdir)/projects/llvm/verona.build $(verona_llvm_files) $(verona_srcdir)/projects/llvm/tests/llvm.tests.vrn
	@$(MKDIR_P) $(@D)
	cd $(verona_srcdir)/projects/llvm && $(VERONA_EXECUTABLE) build llvm-tests $(@D)

test-llvm-bindings: $(VERONA_LLVM_TESTS)
	$(SBCL) --script $(verona_srcdir)/tests/run-llvm-bindings.lisp $(VERONA_LLVM_TESTS)

# Compiler support unit tests use the regular Verona testing library.
.PHONY: test-compiler-support
test-compiler-support: $(VERONA_EXECUTABLE)
	@$(MKDIR_P) $(abs_top_builddir)/build/compiler
	cd $(verona_srcdir)/projects/compiler && $(VERONA_EXECUTABLE) build compiler-tests $(abs_top_builddir)/build/compiler
	$(abs_top_builddir)/build/compiler/compiler-tests

# Recorded A/B/C self-hosting and exact artifact verification.
bootstrap-compiler: $(VERONA_EXECUTABLE)
	$(PYTHON) $(verona_srcdir)/projects/compiler/bootstrap.py --bootstrap $(VERONA_EXECUTABLE) --output $(abs_top_builddir)/build/self-hosting

# No bootstrap prerequisite: the audit never builds or substitutes the Lisp compiler.
SELF_HOSTED_COMPILER =
SELF_HOSTED_PROJECTS_JOBS = 2
SELF_HOSTED_PROJECTS_OUTPUT = $(abs_top_builddir)/build/self-hosted-projects
.PHONY: test-self-hosted-projects test-self-hosted-projects-runner

test-self-hosted-projects-runner:
	$(PYTHON) $(verona_srcdir)/tests/test-self-hosted-projects.py

test-self-hosted-projects: test-self-hosted-projects-runner
	@test -n "$(SELF_HOSTED_COMPILER)" || { echo 'Set SELF_HOSTED_COMPILER to an existing self-hosted verona-core executable.' >&2; exit 1; }
	$(PYTHON) $(verona_srcdir)/scripts/self-hosted-projects.py --compiler "$(SELF_HOSTED_COMPILER)" --output "$(SELF_HOSTED_PROJECTS_OUTPUT)" --jobs "$(SELF_HOSTED_PROJECTS_JOBS)"

.PHONY: verify-compiler-release test-compiler-release-runner
test-compiler-release-runner:
	$(PYTHON) $(verona_srcdir)/tests/test-compiler-release.py

# No build prerequisite: reject dirty inputs before starting a release build.
verify-compiler-release: test-compiler-release-runner
	$(PYTHON) $(verona_srcdir)/scripts/verify-compiler-release.py --output $(abs_top_builddir)/build/compiler-release
