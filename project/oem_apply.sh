#!/usr/bin/env bash
# OEM-wrapper voor een reeds centraal goedgekeurde run.
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  printf 'Gebruik: oem_apply.sh RUN_ID APPROVED_MANIFEST APPROVAL_TOKEN [CONFIG]\n' >&2
}
[[ $# -ge 3 && $# -le 4 ]] || { usage; exit 70; }
RUN_ID=$1; APPROVED_MANIFEST=$2; APPROVAL_TOKEN=$3; CONFIG=${4:-}
[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ && "$APPROVED_MANIFEST" == /* && "$APPROVAL_TOKEN" == /* ]] || { usage; exit 70; }
[[ -z "$CONFIG" || "$CONFIG" == /etc/oracle-patch-guard/* ]] || { usage; exit 70; }
ARGS=(apply --non-interactive --run-id "$RUN_ID" --approved-manifest "$APPROVED_MANIFEST" --approval-token "$APPROVAL_TOKEN")
[[ -n "$CONFIG" ]] && ARGS+=(--config "$CONFIG")

# Een TERM van OEM wordt geregistreerd. Het lokale proces krijgt geen tweede
# startopdracht; status bepaalt daarna of het nog draait of is gestopt.
TIMEOUT_MARKER_ROOT=${OPG_RUN_ROOT:-/var/log/oracle-patch-guard}
if [[ -n "$CONFIG" && -r "$CONFIG" ]]; then
  configured_run_root=$(awk -F= '$1=="RUN_ROOT"{sub(/^[^=]*=/,"");gsub(/^"|"$/ ,"");print;exit}' "$CONFIG")
  [[ "$configured_run_root" == /* ]] && TIMEOUT_MARKER_ROOT=$configured_run_root
fi
# Wordt uitsluitend via de trap hieronder aangeroepen.
# shellcheck disable=SC2317,SC2329
on_timeout() {
  local marker="${TIMEOUT_MARKER_ROOT}/${RUN_ID}/oem_timeout.marker"
  printf '%s|wrapper_pid=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" >"$marker" 2>/dev/null || true
  printf 'OEM_JOB_TIMED_OUT|run_id=%s\n' "$RUN_ID"
}
trap on_timeout TERM INT HUP
/bin/bash "${SCRIPT_DIR}/patchGD_guard.sh" "${ARGS[@]}"
exit $?
