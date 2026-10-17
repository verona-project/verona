AC_INIT([Verona], [0.1.0])
AC_CONFIG_SRCDIR([verona.asd])
AC_CONFIG_AUX_DIR([build-aux])

AM_INIT_AUTOMAKE([foreign])
AC_PROG_INSTALL
AC_PATH_PROG([SBCL], [sbcl])
AS_IF([test -z "$SBCL"], [AC_MSG_ERROR([SBCL is required to build Verona])])

AC_CONFIG_FILES([Makefile])
AC_OUTPUT
