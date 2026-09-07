#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP_BASE=$(mktemp -d /tmp/opg-media-lock-fd-tests.XXXXXX) || exit 1
PASS=0 FAIL=0
trap 'rm -rf -- "$TMP_BASE"' EXIT

# shellcheck source=../lib/opg_core.sh
source "$ROOT/project/lib/opg_core.sh"

record() {
  local name=$1 actual=$2
  if [[ $actual -eq 0 ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (actual=%s)\n' "$name" "$actual"; FAIL=$((FAIL + 1))
  fi
}

RUN_DIR=$TMP_BASE/run
mkdir -p "$RUN_DIR"
COMMAND_TIMEOUT_SECONDS=5
DRY_RUN=false
OPG_TEST_MODE=0
CHILD=$TMP_BASE/check-child.sh
FLOCK_BIN=$(command -v flock)
cat >"$CHILD" <<'EOF'
#!/bin/bash
fd=$1 lock_file=$2 flock_bin=$3
if [[ -e "/proc/self/fd/${fd}" ]]; then
  printf 'CHILD_FD_OPEN\n'
  exit 91
fi
if "$flock_bin" -xn "$lock_file" -c true; then
  printf 'PARENT_LOCK_MISSING\n'
  exit 92
fi
printf 'CHILD_FD_CLOSED\nPARENT_LOCK_HELD\n'
EOF
chmod 0755 "$CHILD"

run_capture_case() {
  local mode=$1 output rc=0 old_path=$PATH lock_file
  output=$TMP_BASE/${mode}.out
  lock_file=$TMP_BASE/${mode}.lock
  : >"$lock_file"
  exec {MEDIA_LOCK_FD}<"$lock_file" || return 80
  flock -sn "$MEDIA_LOCK_FD" || return 81
  if [[ $mode == fallback ]]; then
    mkdir -p "$TMP_BASE/no-timeout-bin"
    ln -sf "$(command -v date)" "$TMP_BASE/no-timeout-bin/date"
    PATH=$TMP_BASE/no-timeout-bin
  fi
  opg_run_capture "fd_${mode}" "$output" "$CHILD" "$MEDIA_LOCK_FD" "$lock_file" "$FLOCK_BIN" || rc=$?
  PATH=$old_path
  [[ $rc -eq 0 && -e "/proc/$$/fd/${MEDIA_LOCK_FD}" ]] || rc=82
  grep -q '^CHILD_FD_CLOSED$' "$output" || rc=83
  record "${mode}: extern child erft MEDIA_LOCK_FD niet" "$rc"
  rc=0
  grep -q '^PARENT_LOCK_HELD$' "$output" || rc=84
  flock -xn "$lock_file" -c true && rc=85
  [[ -e "/proc/$$/fd/${MEDIA_LOCK_FD}" ]] || rc=86
  record "${mode}: parent houdt media-lock tijdens en na child" "$rc"
  opg_release_media_lock
}

run_capture_case timeout
run_capture_case fallback

run_non_external_case() {
  local mode=$1 output lock_file rc=0
  output=$TMP_BASE/${mode}.out
  lock_file=$TMP_BASE/${mode}.lock
  : >"$lock_file"
  exec {MEDIA_LOCK_FD}<"$lock_file" || return 80
  flock -sn "$MEDIA_LOCK_FD" || return 81
  if [[ $mode == dry_run ]]; then
    DRY_RUN=true
  else
    OPG_TEST_MODE=1
  fi
  opg_run_capture "fd_${mode}" "$output" "$CHILD" "$MEDIA_LOCK_FD" "$lock_file" "$FLOCK_BIN" || rc=$?
  [[ $rc -eq 0 && -e "/proc/$$/fd/${MEDIA_LOCK_FD}" ]] || rc=82
  if [[ $mode == dry_run ]]; then
    grep -q '^DRY_RUN:' "$output" || rc=83
    DRY_RUN=false
  else
    grep -q '^MOCK label=fd_mock ' "$output" || rc=84
    OPG_TEST_MODE=0
  fi
  record "${mode}: bestaand niet-uitvoerend capturegedrag en parent-lock blijven behouden" "$rc"
  opg_release_media_lock
}

run_non_external_case dry_run
run_non_external_case mock

printf '\nMedia lock FD results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
