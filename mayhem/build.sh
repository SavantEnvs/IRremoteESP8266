#!/usr/bin/env bash
#
# mayhem/build.sh — build the fuzz harnesses and the unit-test suite for IRremoteESP8266.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# IRremoteESP8266 is an Arduino library. Its own unit tests (test/Makefile) build it with -DUNIT_TEST, which
# swaps the Arduino core for a host-side shim, and so does this build. src/*.cpp is compiled as is.
DEPS=/opt/toolchains/deps/googletest-1.12.1
DEFS="-DUNIT_TEST -D_IR_LOCALE_=en-AU"
STD="-std=gnu++11"
OUT=mayhem
# The upstream protocol sources, plus nothing else (no Arduino core, no examples).
SOURCES=$(ls "$SRC"/src/*.cpp)


# 1) The library, sanitized and coverage-instrumented (-fsanitize=fuzzer-no-link, so the fuzzed code
#    carries SanCov even though only the harness TU links the engine), with DWARF 3.
FUZZ_DIR="$SRC/$OUT/build-fuzz"
rm -rf "$FUZZ_DIR"; mkdir -p "$FUZZ_DIR/obj"
for f in $SOURCES; do
  echo "$CXX $STD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $DEFS -I$SRC/src -I$SRC/test -c $f -o $FUZZ_DIR/obj/$(basename "$f" .cpp).o"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
ar rcs "$FUZZ_DIR/libir.a" "$FUZZ_DIR"/obj/*.o

# 2) The harnesses, each linked twice: libFuzzer, and the run-once standalone reproducer. lsan_off.cc turns
#    LeakSanitizer off at build time; ASan and UBSan stay fully on.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"
$CXX $STD $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/$OUT/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
for h in fuzz_irrecv_decode fuzz_ac_state; do
  $CXX $STD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $DEFS -I"$SRC/src" -I"$SRC/test" \
      -c "$SRC/$OUT/$h.cpp" -o "$FUZZ_DIR/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FUZZ_DIR/$h.o" "$FUZZ_DIR/libir.a" \
      "$FUZZ_DIR/lsan_off.o" -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$FUZZ_DIR/$h.o" "$FUZZ_DIR/standalone_main.o" "$FUZZ_DIR/libir.a" \
      "$FUZZ_DIR/lsan_off.o" -o "/mayhem/$h-standalone"
done

# 3) The project's own unit tests (googletest), with NORMAL flags: no sanitizers, no -gdwarf-3, no
#    coverage instrumentation unless COVERAGE_FLAGS is set. One binary per test/*_test.cpp, as test/Makefile does.
TEST_DIR="$SRC/$OUT/build-tests"
rm -rf "$TEST_DIR"; mkdir -p "$TEST_DIR/obj"
for f in $SOURCES; do
  echo "$CXX $STD -g -pthread $COVERAGE_FLAGS $DEFS -I$SRC/src -I$SRC/test -c $f -o $TEST_DIR/obj/$(basename "$f" .cpp).o"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
ar rcs "$TEST_DIR/libir.a" "$TEST_DIR"/obj/*.o
for t in "$SRC"/test/*_test.cpp; do
  n=$(basename "$t" .cpp)
  echo "$CXX $STD -g -pthread $COVERAGE_FLAGS $DEFS -isystem $DEPS/include -I$SRC/src -I$SRC/test $t \
    $TEST_DIR/libir.a -L$DEPS/lib -lgtest_main -lgmock -lgtest -o $TEST_DIR/$n"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
