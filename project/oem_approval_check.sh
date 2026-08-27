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

PROJECT=/mnt/patch-share/oracle-patch-guard/current/project
APPROVAL_DIR=/mnt/patch-share/oracle-patch-guard/approvals/$RUN_ID
CONFIG=/etc/oracle-patch-guard/patchGD_guard.conf

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
