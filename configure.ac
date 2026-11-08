AC_INIT([Verona], [0.1.0])
AC_CONFIG_SRCDIR([verona.build])
AC_CONFIG_AUX_DIR([build-aux])

AM_INIT_AUTOMAKE([foreign subdir-objects])
AC_PROG_INSTALL
AC_PROG_MKDIR_P

dnl The compiler is self-hosted.  A development checkout may use its local
dnl seed, while a source release must name the recorded compatible seed.
AC_ARG_VAR([VERONA_SEED], [compatible Verona compiler used to build this checkout])
AC_ARG_WITH([seed],
  [AS_HELP_STRING([--with-seed=PATH], [compatible Verona compiler used to build this checkout])],
  [VERONA_SEED=$withval])
AS_IF([test -z "$VERONA_SEED"], [VERONA_SEED="$srcdir/build/verona"])
AS_IF([test ! -x "$VERONA_SEED"],
  [AC_MSG_ERROR([a compatible executable seed compiler is required; pass --with-seed=PATH or set VERONA_SEED])])
VERONA_SEED_DIR=`dirname "$VERONA_SEED"`
VERONA_SEED_BASE=`basename "$VERONA_SEED"`
VERONA_SEED_DIR=`cd "$VERONA_SEED_DIR" && pwd -P`
VERONA_SEED="$VERONA_SEED_DIR/$VERONA_SEED_BASE"
AC_SUBST([VERONA_SEED])

AC_PATH_PROG([PYTHON], [python3])
AS_IF([test -z "$PYTHON"],
  [AC_MSG_ERROR([Python 3 is required to run the compiler test suites])])
AC_SUBST([PYTHON])

dnl LLVM's C API and the compiler driver must come from the same major release.
AC_ARG_VAR([LLVM_CONFIG], [llvm-config from the LLVM 23 toolchain])
AC_PATH_PROG([LLVM_CONFIG], [llvm-config])
AS_IF([test -z "$LLVM_CONFIG"],
  [AC_MSG_ERROR([LLVM 23 is required; run nix develop or set LLVM_CONFIG])])
AS_IF([test ! -x "$LLVM_CONFIG"],
  [AC_MSG_ERROR([LLVM_CONFIG must name an executable llvm-config; found $LLVM_CONFIG])])
LLVM_VERSION=`"$LLVM_CONFIG" --version 2>/dev/null`
AS_CASE([$LLVM_VERSION],
  [23.*], [],
  [AC_MSG_ERROR([LLVM 23 is required; found $LLVM_VERSION])])
LLVM_LIBDIR=`"$LLVM_CONFIG" --libdir`
AC_SUBST([LLVM_CONFIG])
AC_SUBST([LLVM_LIBDIR])

dnl These settings are consumed by the self-hosted driver's native linker.
dnl Keep the historical public names as fallbacks for existing callers.
AC_ARG_VAR([VERONA_CORE_CLANG], [C compiler used by Verona for native linking])
AC_ARG_VAR([VERONA_CORE_AR], [archiver used by Verona for static libraries])
AC_ARG_VAR([VERONA_LINKER], [fallback C compiler used by Verona for native linking])
AC_ARG_VAR([VERONA_AR], [fallback archiver used by Verona for static libraries])
AC_ARG_WITH([linker],
  [AS_HELP_STRING([--with-linker=PATH], [C compiler used for native linking])],
  [VERONA_CORE_CLANG=$withval])
AC_ARG_WITH([archiver],
  [AS_HELP_STRING([--with-archiver=PATH], [archiver used for static libraries])],
  [VERONA_CORE_AR=$withval])
AS_IF([test -z "$VERONA_CORE_CLANG"], [VERONA_CORE_CLANG=$VERONA_LINKER])
AS_IF([test -z "$VERONA_CORE_AR"], [VERONA_CORE_AR=$VERONA_AR])
AS_IF([test -z "$VERONA_CORE_CLANG"], [AC_PATH_PROG([VERONA_CORE_CLANG], [clang])])
AS_IF([test -z "$VERONA_CORE_AR"], [AC_PATH_PROG([VERONA_CORE_AR], [llvm-ar])])
AS_IF([test -z "$VERONA_CORE_CLANG"],
  [AC_MSG_ERROR([clang is required; run nix develop or pass --with-linker=PATH])])
AS_IF([test -z "$VERONA_CORE_AR"],
  [AC_MSG_ERROR([llvm-ar is required; run nix develop or pass --with-archiver=PATH])])
AS_IF([test ! -x "$VERONA_CORE_CLANG"],
  [AC_MSG_ERROR([VERONA_CORE_CLANG must name an executable clang; found $VERONA_CORE_CLANG])])
AS_IF([test ! -x "$VERONA_CORE_AR"],
  [AC_MSG_ERROR([VERONA_CORE_AR must name an executable llvm-ar; found $VERONA_CORE_AR])])
VERONA_CORE_CLANG_VERSION=`"$VERONA_CORE_CLANG" --version 2>/dev/null`
AS_CASE([$VERONA_CORE_CLANG_VERSION],
  [*23.*], [],
  [AC_MSG_ERROR([Clang 23 is required; found $VERONA_CORE_CLANG_VERSION])])
VERONA_CORE_AR_VERSION=`"$VERONA_CORE_AR" --version 2>/dev/null`
AS_CASE([$VERONA_CORE_AR_VERSION],
  [*23.*], [],
  [AC_MSG_ERROR([llvm-ar 23 is required; found $VERONA_CORE_AR_VERSION])])
VERONA_LINKER=$VERONA_CORE_CLANG
VERONA_AR=$VERONA_CORE_AR
AC_SUBST([VERONA_CORE_CLANG])
AC_SUBST([VERONA_CORE_AR])
AC_SUBST([VERONA_LINKER])
AC_SUBST([VERONA_AR])

AC_CONFIG_FILES([Makefile])
AC_OUTPUT
