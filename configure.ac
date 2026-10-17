AC_INIT([Verona], [0.1.0])
AC_CONFIG_SRCDIR([verona.asd])
AC_CONFIG_AUX_DIR([build-aux])

AM_INIT_AUTOMAKE([foreign])
AC_PROG_INSTALL

AC_PATH_PROG([SBCL], [sbcl])
AS_IF([test -z "$SBCL"], [AC_MSG_ERROR([SBCL is required to build Verona])])

AC_ARG_VAR([VERONA_LINKER], [C compiler used by Verona for native linking])
AC_ARG_VAR([VERONA_AR], [archiver used by Verona for static libraries])

AC_ARG_WITH([linker],
  [AS_HELP_STRING([--with-linker=PATH], [C compiler used for native linking])],
  [VERONA_LINKER=$withval])
AC_ARG_WITH([archiver],
  [AS_HELP_STRING([--with-archiver=PATH], [archiver used for static libraries])],
  [VERONA_AR=$withval])

AC_PATH_PROG([VERONA_LINKER], [clang])
AS_IF([test -z "$VERONA_LINKER"],
  [AC_MSG_ERROR([clang is required; run nix develop or pass --with-linker=PATH])])
AC_PATH_PROG([VERONA_AR], [llvm-ar])
AS_IF([test -z "$VERONA_AR"],
  [AC_MSG_ERROR([llvm-ar is required; run nix develop or pass --with-archiver=PATH])])

AC_SUBST([VERONA_LINKER])
AC_SUBST([VERONA_AR])

AC_CONFIG_FILES([Makefile])
AC_OUTPUT
