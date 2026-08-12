#!/bin/sh
# Freezes quickjs-ng's four translation units into a per-target static library,
# so that consumers link it instead of recompiling it. quickjs.c alone is 2 MB of
# C and takes ~4.2 s at -O2 on an M-series Mac; c3c has no object cache, so as a
# `c-sources` entry it was paid on *every* build, including one that changed
# nothing.
#
# qjs_shim.c is deliberately NOT in here. It is the file this binding actually
# edits, it compiles in 0.03 s, and freezing it into the archive would mean
# every shim change needed this script run first — silently building the old
# code until someone noticed.
#
#   ./build-quickjs.sh                # the host's own target
#   ./build-quickjs.sh macos-x64      # a named target this host can reach
#
# CROSS-BUILDING: c3c never passes -target to the C compiler — it hands each
# `c-sources` file to whatever `--cc` names, defaulting to the host's. So
# `c3c build --target linux-x64` on a Mac writes an archive holding one ELF
# x86-64 object beside five Mach-O arm64 ones and reports success (verified on
# 0.8.2, same for windows-x64). The fix is not to avoid c3c but to give it a
# compiler that is already aimed at the target:
#
#   c3c build --target mingw-x64 --cc x86_64-w64-mingw32-gcc
#
# which yields an all-COFF archive. This script does the same thing directly, so
# a cross toolchain on PATH is all any target needs:
#
#   macos-*     Xcode clang, both slices, no extra install
#   windows-x64 x86_64-w64-mingw32-gcc    (brew install mingw-w64)
#   linux-*     x86_64-linux-gnu-gcc etc. (a linux cross-gcc, or build natively)
#
# Windows deserves a note. c3c links `windows-x64` with lld-link against the MSVC
# CRT it downloads to ~/.cache/c3/msvc_sdk — which is import libraries only, no C
# headers, so clang cannot compile C for that ABI (`'stdlib.h' file not found`).
# mingw-w64 supplies the missing headers, and its objects link happily against
# the MSVC CRT *once they stop asking for mingw's own runtime* — which is what
# the three flags below are for:
#
#   -D__USE_MINGW_ANSI_STDIO=0  mingw's stdio.h otherwise redirects printf-family
#                               calls to __mingw_vsnprintf, which lives in
#                               libmingwex and is not in the MSVC CRT
#   -fno-stack-protector        __stack_chk_fail/__stack_chk_guard live in libssp
#   -mno-stack-arg-probe        ___chkstk_ms lives in libgcc
#
# With those, a consumer cross-builds from macOS all the way to a PE32+ binary:
#
#   c3c build <target> --target windows-x64 --cc x86_64-w64-mingw32-gcc
#
# The same --cc is needed there because qjs_shim.c is still compiled from source;
# manifest.json carries these flags under its windows-x64 target so the shim gets
# them too.
#
# c3c's *other* Windows target, `mingw-x64`, is not shipped: on 0.8.2 it cannot
# link even a hello world from macOS — its own std.io objects call ___chkstk_ms
# and the link provides no libgcc. Nothing to do with this library.
#
# Run after updating the vendored quickjs-ng sources, and commit the result.
# The flags must stay in step with manifest.json's `cflags`.
set -e
cd "$(dirname "$0")"

# The engine is the quickjs-ng submodule, not a copy in this tree: the gitlink is
# what records which upstream commit these archives were built from.
SRC=../vendor/quickjs-ng
[ -f "$SRC/quickjs.c" ] || {
	echo "vendor/quickjs-ng is empty — the quickjs-ng submodule is not checked out." >&2
	echo "  git submodule update --init --recursive" >&2
	exit 1; }

UNITS="dtoa libregexp libunicode quickjs"
COMMON="-O2 -std=c11 -D_GNU_SOURCE -funsigned-char -Wno-unused-parameter -Wno-missing-braces -Wno-sign-compare -Wno-unused-but-set-variable -Wno-implicit-fallthrough"

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64)  HOST=macos-aarch64 ;;
	Darwin-x86_64) HOST=macos-x64 ;;
	Linux-aarch64) HOST=linux-aarch64 ;;
	Linux-x86_64)  HOST=linux-x64 ;;
	MINGW*|MSYS*|CYGWIN*) HOST=windows-x64 ;;
	*) HOST="" ;;
esac

targets=$*
if [ -z "$targets" ]; then
	[ -n "$HOST" ] || { echo "unknown host $(uname -s)-$(uname -m); name a target explicitly" >&2; exit 1; }
	targets=$HOST
fi

for target in $targets; do
	# How to reach each target, and the archiver that understands its objects.
	# A cross toolchain is used only where the host compiler cannot aim itself.
	archive=libquickjs.a
	AR=ar
	EXTRA=""
	native=""
	case "$target" in
		macos-aarch64) CC="cc -arch arm64 -mmacosx-version-min=11.0"; native=Darwin ;;
		macos-x64)     CC="cc -arch x86_64 -mmacosx-version-min=11.0"; native=Darwin ;;
		# c3c reads a static library as <name>.lib on Windows, the shape ktx.c3
		# ships zstd.lib in. EXTRA is what keeps mingw's objects linkable against
		# the MSVC CRT — see the note at the top.
		windows-x64)   CC=x86_64-w64-mingw32-gcc; AR=x86_64-w64-mingw32-ar
		               archive=quickjs.lib
		               EXTRA="-D__USE_MINGW_ANSI_STDIO=0 -fno-stack-protector -mno-stack-arg-probe" ;;
		linux-x64)     [ "$HOST" = linux-x64 ] && CC=cc || CC=x86_64-linux-gnu-gcc ;;
		linux-aarch64) [ "$HOST" = linux-aarch64 ] && CC=cc || CC=aarch64-linux-gnu-gcc ;;
		*) echo "unknown target $target" >&2; exit 1 ;;
	esac

	# Refuse rather than silently mis-build: a missing cross compiler must not
	# fall back to the host's, which would produce the host's object format.
	[ -z "$native" ] || [ "$(uname -s)" = "$native" ] || {
		echo "$target needs a $native host" >&2; exit 1; }
	set -- $CC
	command -v "$1" >/dev/null || {
		echo "$target needs $1 on PATH." >&2
		[ "$target" = windows-x64 ] && echo "  brew install mingw-w64" >&2
		exit 1; }

	out=../lib/$target
	work=$(mktemp -d)
	mkdir -p "$out"
	echo "$target:"
	objs=""
	for unit in $UNITS; do
		echo "  cc $unit.c"
		$CC -c "$SRC/$unit.c" -I"$SRC" -I. -o "$work/$unit.o" $COMMON $EXTRA
		objs="$objs $work/$unit.o"
	done
	rm -f "$out/$archive"
	# shellcheck disable=SC2086
	$AR rcs "$out/$archive" $objs
	rm -rf "$work"
	echo "  wrote $out/$archive"
done
