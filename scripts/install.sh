#!/usr/bin/env bash
# Also supported with: zsh install.sh [absolute-binary-directory]
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
    printf '%s\n' 'Usage: bash install.sh [ABSOLUTE-BIN-DIR]' \
        'Also runs with zsh. Default bin directory: /usr/local/bin.' \
        'Set VERONA_SOURCE_DIR and VERONA_LIBRARY_DIR to absolute destination directories.'
    exit 0
fi
[ "$#" -le 1 ] || fail 'Expected at most one binary destination directory'
bindir=${1:-/usr/local/bin}
: "${VERONA_SOURCE_DIR:?Set VERONA_SOURCE_DIR to an absolute source destination}"
: "${VERONA_LIBRARY_DIR:?Set VERONA_LIBRARY_DIR to an absolute library destination}"
for destination in "$bindir" "$VERONA_SOURCE_DIR" "$VERONA_LIBRARY_DIR"; do
    case "$destination" in /*) ;; *) fail "Destination must be absolute: $destination" ;; esac
    [ "$destination" != / ] || fail 'Refusing to install directly into /'
    [ ! -e "$destination" ] || [ -d "$destination" ] || fail "Not a directory: $destination"
done
# $0 works for direct invocation, bash install.sh, and zsh install.sh.
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
for executable in verona verona-project verona-fmt verona-server; do
    [ -f "$bundle/bin/$executable" ] || fail "Missing executable: $executable"
done
for package in base libc foundation testing; do
    [ -f "$bundle/source/$package/verona.build" ] || fail "Missing source: $package"
    [ -d "$bundle/source/$package/src" ] || fail "Missing source directory: $package"
done
[ -f "$bundle/VERSION" ] || fail 'Missing release version'
[ -f "$bundle/GIT_HASH" ] || fail 'Missing Git revision'
[ -f "$bundle/compiler/verona.asd" ] || fail 'Missing compiler sources'
[ -f "$bundle/CL-LLVM/llvm.asd" ] || fail 'Missing CL-LLVM sources'
# Validate every payload and destination before creating directories or copying.
mkdir -p -- "$bindir" "$VERONA_SOURCE_DIR" "$VERONA_LIBRARY_DIR"
for executable in verona verona-project verona-fmt verona-server; do
    install -m 755 "$bundle/bin/$executable" "$bindir/$executable"
done
for package in base libc foundation testing; do
    mkdir -p -- "$VERONA_SOURCE_DIR/$package"
    cp -R "$bundle/source/$package/." "$VERONA_SOURCE_DIR/$package/"
done
install -m 644 "$bundle/VERSION" "$VERONA_LIBRARY_DIR/VERSION"
install -m 644 "$bundle/GIT_HASH" "$VERONA_LIBRARY_DIR/GIT_HASH"
mkdir -p -- "$VERONA_SOURCE_DIR/compiler" "$VERONA_SOURCE_DIR/CL-LLVM"
cp -R "$bundle/compiler/." "$VERONA_SOURCE_DIR/compiler/"
cp -R "$bundle/CL-LLVM/." "$VERONA_SOURCE_DIR/CL-LLVM/"
printf '%s\n' "Installed Verona into $bindir" \
    'Keep VERONA_SOURCE_DIR and VERONA_LIBRARY_DIR exported in your shell.' \
    "For the IDE, use compiler root $VERONA_SOURCE_DIR/compiler" \
    "and set VERONA_CL_LLVM=$VERONA_SOURCE_DIR/CL-LLVM; SBCL and Swank are also required." \
    'Ensure the binary destination is on PATH and LLVM 23 runtime libraries are discoverable.'
