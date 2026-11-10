#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the googletest binaries that mayhem/build.sh produced (one per test/*_test.cpp) and sum their
# summaries. A binary that prints no summary (crashed, neutered, missing) counts as a failure.
TEST_DIR="$SRC/mayhem/build-tests"
passed=0 failed=0 skipped=0 ran_files=0
for src in "$SRC"/test/*_test.cpp; do
  n=$(basename "$src" .cpp)
  bin="$TEST_DIR/$n"
  if [ ! -x "$bin" ]; then echo "MISSING test binary $bin (build.sh should have built it)" >&2; failed=$((failed + 1)); continue; fi
  out=$("$bin" 2>&1) ; rc=$?
  ran=$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' | tail -1)
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]\+\) tests\?\..*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]\+\) tests\?, listed below.*/\1/p' | tail -1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?, listed below.*/\1/p' | tail -1)
  if [ -z "$ran" ]; then
    echo "NO gtest summary from $n (exit $rc)" >&2; printf '%s\n' "$out" | tail -5 >&2
    failed=$((failed + 1)); continue
  fi
  ran_files=$((ran_files + 1))
  p=${p:-0} f=${f:-0} s=${s:-0}
  # Every test reported by "ran" must be accounted for as passed, failed or skipped.
  if [ $((p + f + s)) -ne "$ran" ] || [ "$rc" -ne 0 -a "$f" -eq 0 ]; then
    echo "INCONSISTENT gtest result from $n: ran=$ran passed=$p failed=$f skipped=$s exit=$rc" >&2
    failed=$((failed + 1))
  fi
  passed=$((passed + p)) failed=$((failed + f)) skipped=$((skipped + s))
done

# Known-answer floor: the suite has this many files and at least this many cases; a collapse of either
# (stripped build context, neutered binaries) must not read as success.
MIN_FILES=80 MIN_TESTS=1000
if [ "$ran_files" -lt "$MIN_FILES" ] || [ $((passed + failed + skipped)) -lt "$MIN_TESTS" ]; then
  echo "suite collapsed: $ran_files test binaries ran, $((passed + failed + skipped)) tests (expected >= $MIN_FILES / $MIN_TESTS)" >&2
  failed=$((failed + 1))
fi

emit_ctrf "googletest" "$passed" "$failed" "$skipped"
