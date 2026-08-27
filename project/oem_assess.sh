#!/usr/bin/env bash
# OEM-wrapper: compacte stdout, uitgebreide logging door de lokale guard.
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  printf 'Gebruik: oem_assess.sh TARGET_ORACLE_HOME RUN_ID DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE [CONFIG]\n' >&2
}
[[ $# -ge 7 && $# -le 8 ]] || { usage; exit 70; }
TARGET_ORACLE_HOME=$1; RUN_ID=$2; shift 2
[[ "$TARGET_ORACLE_HOME" =~ ^/[A-Za-z0-9_./-]+$ && "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || { usage; exit 70; }
ARGS=(assess --non-interactive --target-oracle-home "$TARGET_ORACLE_HOME" --run-id "$RUN_ID")
[[ $# -eq 6 ]] && CONFIG=${6} || CONFIG=
[[ -z "$CONFIG" || "$CONFIG" == /etc/oracle-patch-guard/* ]] || { usage; exit 70; }
ARGS+=("$1" "$2" "$3" "$4" "$5")
[[ -n "$CONFIG" ]] && ARGS+=(--config "$CONFIG")
exec /bin/bash "${SCRIPT_DIR}/patchGD_guard.sh" "${ARGS[@]}"
