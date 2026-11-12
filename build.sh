#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC=${CC:-clang}
LD=${LD:-ld.lld}
TARGET_DIR=$ROOT/bin
TMP_BUILD=$ROOT/.build
mkdir -p "$TARGET_DIR" "$TMP_BUILD"
command -v "$CC" >/dev/null 2>&1 || { echo "clang not found (set CC=...)" >&2; exit 1; }
command -v "$LD" >/dev/null 2>&1 || { echo "ld.lld not found (set LD=...)" >&2; exit 1; }

CFLAGS='-O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables -nostdlib'

build_target() {
    echo '[BUILD] AArch64 static binaries'
    "$CC" --target=aarch64-linux-gnu $CFLAGS -c "$ROOT/src/start_aarch64.S" -o "$TMP_BUILD/start_aarch64.o"
    "$CC" --target=aarch64-linux-gnu $CFLAGS -c "$ROOT/src/vqe_whistle_capture.c" -o "$TMP_BUILD/vqe_aarch64.o"
    "$CC" --target=aarch64-linux-gnu $CFLAGS -c "$ROOT/src/eventwatch.c" -o "$TMP_BUILD/eventwatch_aarch64.o"
    "$LD" -m aarch64elf -static -e _start -z noexecstack -o "$TARGET_DIR/vqe-whistle-capture" "$TMP_BUILD/start_aarch64.o" "$TMP_BUILD/vqe_aarch64.o"
    "$LD" -m aarch64elf -static -e _start -z noexecstack -o "$TARGET_DIR/eventwatch" "$TMP_BUILD/start_aarch64.o" "$TMP_BUILD/eventwatch_aarch64.o"
    chmod 755 "$TARGET_DIR/vqe-whistle-capture" "$TARGET_DIR/eventwatch"
    command -v file >/dev/null 2>&1 && file "$TARGET_DIR/vqe-whistle-capture" "$TARGET_DIR/eventwatch" || :
    command -v readelf >/dev/null 2>&1 && {
        for f in "$TARGET_DIR/vqe-whistle-capture" "$TARGET_DIR/eventwatch"; do
            readelf -l "$f" | grep -q INTERP && { echo "Unexpected dynamic interpreter: $f" >&2; exit 1; } || :
            readelf -Ws "$f" | awk '$7 == "UND" && $8 != "" { bad=1 } END { exit bad }' || { echo "Unresolved symbol in $f" >&2; exit 1; }
        done
    }
    echo '[BUILD] Target binaries are static AArch64 ELF files with no unresolved symbols.'
}

build_host_tests() {
    echo '[BUILD] Native x86_64 test binaries'
    "$CC" $CFLAGS -c "$ROOT/src/start_x86_64.S" -o "$TMP_BUILD/start_x86_64.o"
    "$CC" $CFLAGS -c "$ROOT/src/vqe_whistle_capture.c" -o "$TMP_BUILD/vqe_host.o"
    "$CC" $CFLAGS -c "$ROOT/src/eventwatch.c" -o "$TMP_BUILD/eventwatch_host.o"
    mkdir -p "$ROOT/tests/bin"
    "$LD" -m elf_x86_64 -static -e _start -z noexecstack -o "$ROOT/tests/bin/vqe-whistle-capture-host" "$TMP_BUILD/start_x86_64.o" "$TMP_BUILD/vqe_host.o"
    "$LD" -m elf_x86_64 -static -e _start -z noexecstack -o "$ROOT/tests/bin/eventwatch-host" "$TMP_BUILD/start_x86_64.o" "$TMP_BUILD/eventwatch_host.o"
    chmod 755 "$ROOT/tests/bin/"*-host
}

case "${1:-all}" in
    all) build_target ;;
    host-test) build_host_tests ;;
    *) echo "Usage: $0 [all|host-test]" >&2; exit 2 ;;
esac
