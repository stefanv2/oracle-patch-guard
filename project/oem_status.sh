#!/usr/bin/env bash
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ $# -ge 1 && $# -le 2 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || { printf 'Gebruik: oem_status.sh RUN_ID [CONFIG]\n' >&2; exit 70; }
[[ -z ${2:-} || ${2:-} == /etc/oracle-patch-guard/* ]] || { printf 'Ongeldig configuratiepad.\n' >&2; exit 70; }
ARGS=(status --non-interactive --run-id "$1")
[[ -n ${2:-} ]] && ARGS+=(--config "$2")
exec /bin/bash "${SCRIPT_DIR}/patchGD_guard.sh" "${ARGS[@]}"
