#!/bin/bash
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <RUN_ID> <ORACLE_SID> <ORACLE_HOME>"
  exit 70
fi

RUN_ID="$1"
ORACLE_SID="$2"
ORACLE_HOME="$3"

[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || exit 70
[[ "$ORACLE_SID" =~ ^[A-Za-z0-9_#$]+$ ]] || exit 70
[[ "$ORACLE_HOME" == /* && -d "$ORACLE_HOME" ]] || exit 70

CONFIG=${OPG_CONFIG_FILE:-/etc/oracle-patch-guard/patchGD_guard.conf}

config_path_value() {
  local wanted=$1 raw key value found='' mode perm
  [[ -f "$CONFIG" && -r "$CONFIG" && ! -L "$CONFIG" ]] || return 1
  mode=$(stat -c '%a' "$CONFIG" 2>/dev/null) || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  perm=$((8#$mode)); (( (perm & 0022) == 0 )) || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw=${raw%$'\r'}
    [[ "$raw" =~ ^[[:space:]]*$ || "$raw" =~ ^[[:space:]]*# ]] && continue
    [[ "$raw" == *=* ]] || continue
    key=${raw%%=*}; value=${raw#*=}
    key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    [[ "$key" == "$wanted" ]] || continue
    [[ -z "$found" ]] || return 2
    found=$value
  done <"$CONFIG"
  [[ -n "$found" && "$found" == /* && "$found" =~ ^/[A-Za-z0-9_./-]+$ && "$found" != *'//'*
     && "$found" != */../* && "$found" != */./* && "$found" != */.. && "$found" != */. ]] || return 3
  printf '%s' "$found"
}

if [[ -n ${OPG_ROOT:-} ]]; then PROJECT=${OPG_ROOT}/current/project; else OPG_ROOT=$(config_path_value OPG_ROOT) || exit 30; PROJECT=${OPG_ROOT}/current/project; fi
if [[ -n ${OPG_APPROVAL_ROOT:-} ]]; then APPROVAL_ROOT=$OPG_APPROVAL_ROOT; else APPROVAL_ROOT=$(config_path_value APPROVAL_ROOT) || exit 30; fi
for deployment_path in "$OPG_ROOT" "$APPROVAL_ROOT"; do
  [[ "$deployment_path" == /* && "$deployment_path" =~ ^/[A-Za-z0-9_./-]+$ && "$deployment_path" != *'//'*
     && "$deployment_path" != */../* && "$deployment_path" != */./* && "$deployment_path" != */.. && "$deployment_path" != */. ]] || exit 30
done
APPROVAL_DIR=${APPROVAL_ROOT}/$RUN_ID

exec /usr/bin/env \
  ORACLE_HOME="$ORACLE_HOME" \
  LD_LIBRARY_PATH="$ORACLE_HOME/lib:/lib:/usr/lib" \
  ORACLE_SID="$ORACLE_SID" \
  PATH="$ORACLE_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  /bin/bash "$PROJECT/patchGD_guard.sh" apply \
    --dry-run \
    --non-interactive \
    --run-id "$RUN_ID" \
    --approved-manifest "$APPROVAL_DIR/patch_manifest.json" \
    --approval-token "$APPROVAL_DIR/approval.json" \
    --config "$CONFIG"
