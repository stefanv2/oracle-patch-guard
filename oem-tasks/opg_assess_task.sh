#!/usr/bin/env bash
set -u
set -o pipefail

CORE=/mnt/datadomain/software/patches/Linux/oracle-patch-guard/current/project/oem_assess.sh

/bin/bash "$CORE" "$@"
rc=$?

case "$rc" in
  0)
    echo "OPG_OEM_ASSESS_RESULT|status=READY|patch_guard_exit_code=0|oem_exit_code=0"
    exit 0
    ;;
  10)
    echo "OPG_OEM_ASSESS_RESULT|status=CONDITIONAL|patch_guard_exit_code=10|oem_exit_code=0"
    exit 0
    ;;
  *)
    echo "OPG_OEM_ASSESS_RESULT|status=FAILED|patch_guard_exit_code=$rc|oem_exit_code=$rc"
    exit "$rc"
    ;;
esac
