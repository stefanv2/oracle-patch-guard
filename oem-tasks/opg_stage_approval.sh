#!/bin/bash
#
# Oracle Patch Guard - Stage approval artifacts
#
# Doel:
#   Publiceer na een succesvolle PLAN-run uitsluitend de artifacts die de
#   signing-server nodig heeft om de run te beoordelen en goed te keuren.
#
# Gebruik:
#   opg_stage_approval.sh RUN_ID
#
# Bron:
#   /var/log/oracle-patch-guard/<RUN_ID>/
#
# Doel:
#   /mnt/patch-share/oracle-patch-guard/approvals/<RUN_ID>/
#
# Dit script:
#   - approveert NIETS
#   - signeert NIETS
#   - wijzigt execution_state.json NIET
#   - accepteert alleen een succesvolle PLAN-run
#   - weigert een bestaande approval-directory
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=${0##*/}

RUN_ROOT=${OPG_STAGE_RUN_ROOT:-/var/log/oracle-patch-guard}
APPROVAL_ROOT=${OPG_STAGE_APPROVAL_ROOT:-/mnt/patch-share/oracle-patch-guard/approvals}
APPROVAL_DIRECTORY_OWNER=${OPG_APPROVAL_DIRECTORY_OWNER:-root}
APPROVAL_GROUP=${OPG_APPROVAL_GROUP:-oinstall}
SUDO_BIN=${OPG_STAGE_SUDO_BIN:-/usr/bin/sudo}
CONTEXT_HELPER=${OPG_STAGE_CONTEXT_HELPER:-/usr/local/sbin/opg_context_root.sh}
CONTEXT_HELPER_OWNER=${OPG_STAGE_CONTEXT_HELPER_OWNER:-root}
CONTEXT_HELPER_GROUP=${OPG_STAGE_CONTEXT_HELPER_GROUP:-root}
CONTEXT_HELPER_PARENT_STOP=${OPG_STAGE_CONTEXT_HELPER_PARENT_STOP:-/}

EXIT_USAGE=2
EXIT_BLOCKED=20
EXIT_ERROR=30

usage() {
    printf 'Usage: %s RUN_ID\n' "$SCRIPT_NAME" >&2
}

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

json_get() {
    local file=$1
    local key=$2

    python3 - "$file" "$key" <<'PY'
import json
import sys

path = sys.argv[1]
key = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

value = data.get(key)

if value is None:
    sys.exit(1)

if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

require_privileged_helper() {
    local identity parent parent_identity parent_owner parent_mode
    [[ -x "$SUDO_BIN" && -f "$SUDO_BIN" && ! -L "$SUDO_BIN" ]] || {
        error "sudo is niet veilig beschikbaar: $SUDO_BIN"
        exit "$EXIT_ERROR"
    }
    [[ -x "$CONTEXT_HELPER" && -f "$CONTEXT_HELPER" && -r "$CONTEXT_HELPER" && ! -L "$CONTEXT_HELPER" ]] || {
        error "Lokale root-helper ontbreekt of is onveilig: $CONTEXT_HELPER"
        exit "$EXIT_ERROR"
    }
    identity=$(stat -c '%U:%G:%a' "$CONTEXT_HELPER" 2>/dev/null) || {
        error "Lokale root-helperpermissions konden niet worden bepaald."
        exit "$EXIT_ERROR"
    }
    [[ "$identity" == "${CONTEXT_HELPER_OWNER}:${CONTEXT_HELPER_GROUP}:755" ]] || {
        error "Lokale root-helperpermissions wijken af: $identity"
        exit "$EXIT_ERROR"
    }
    if [[ ${OPG_STAGE_TEST_MODE:-0} != 1 && -w "$CONTEXT_HELPER" ]]; then
        error "Lokale root-helper is schrijfbaar door de staginggebruiker."
        exit "$EXIT_ERROR"
    fi
    parent=${CONTEXT_HELPER%/*}
    while :; do
        [[ -d "$parent" && ! -L "$parent" ]] || {
            error "Helper-parentdirectory ontbreekt of is een symlink: $parent"
            exit "$EXIT_ERROR"
        }
        parent_identity=$(stat -c '%U:%G:%a' "$parent" 2>/dev/null) || {
            error "Helper-parentpermissions konden niet worden bepaald: $parent"
            exit "$EXIT_ERROR"
        }
        parent_owner=${parent_identity%%:*}
        parent_mode=${parent_identity##*:}
        [[ "$parent_owner" == "$CONTEXT_HELPER_OWNER" ]] || {
            error "Helper-parent heeft een onveilige owner: ${parent_identity}|${parent}"
            exit "$EXIT_ERROR"
        }
        (( (8#$parent_mode & 0022) == 0 )) || {
            error "Helper-parent is group/world-writable: ${parent_identity}|${parent}"
            exit "$EXIT_ERROR"
        }
        if [[ ${OPG_STAGE_TEST_MODE:-0} != 1 && -w "$parent" ]]; then
            error "Helper-parent is schrijfbaar door de staginggebruiker: $parent"
            exit "$EXIT_ERROR"
        fi
        [[ "$parent" == "$CONTEXT_HELPER_PARENT_STOP" ]] && break
        [[ "$parent" != / ]] || {
            error "Helper-parentgrens werd niet veilig bereikt."
            exit "$EXIT_ERROR"
        }
        parent=${parent%/*}
        [[ -n "$parent" ]] || parent=/
    done
}

[[ $# -eq 1 ]] || {
    usage
    exit "$EXIT_USAGE"
}

RUN_ID=$1

[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || {
    error "Unsafe RUN_ID: $RUN_ID"
    exit "$EXIT_USAGE"
}

command -v python3 >/dev/null 2>&1 || {
    error "python3 ontbreekt."
    exit "$EXIT_ERROR"
}

command -v sha256sum >/dev/null 2>&1 || {
    error "sha256sum ontbreekt."
    exit "$EXIT_ERROR"
}

command -v tar >/dev/null 2>&1 || {
    error "tar ontbreekt."
    exit "$EXIT_ERROR"
}

require_privileged_helper

SRC="${RUN_ROOT}/${RUN_ID}"
DST="${APPROVAL_ROOT}/${RUN_ID}"

MANIFEST="${SRC}/patch_manifest.json"
ASSESSMENT="${SRC}/assessment.json"
FINDINGS="${SRC}/findings.psv"
STATE_FILE="${SRC}/execution_state.json"
MANIFEST_HASH_FILE="${SRC}/patch_manifest.sha256"

#
# Basiscontroles.
#
[[ -d "$SRC" ]] || {
    error "Run directory bestaat niet: $SRC"
    exit "$EXIT_BLOCKED"
}

[[ -d "$APPROVAL_ROOT" ]] || {
    error "Approval root bestaat niet: $APPROVAL_ROOT"
    exit "$EXIT_ERROR"
}

getent group "$APPROVAL_GROUP" >/dev/null 2>&1 || {
    error "Approval group bestaat niet: $APPROVAL_GROUP"
    exit "$EXIT_ERROR"
}

for file in \
    "$MANIFEST" \
    "$ASSESSMENT" \
    "$FINDINGS" \
    "$STATE_FILE"
do
    [[ -r "$file" ]] || {
        error "Vereist PLAN-artifact ontbreekt of is niet leesbaar: $file"
        exit "$EXIT_BLOCKED"
    }
done

#
# JSON eerst syntactisch valideren.
#
python3 - "$MANIFEST" "$ASSESSMENT" "$STATE_FILE" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    with open(path, "r", encoding="utf-8") as f:
        json.load(f)
PY

#
# Identiteit/state uitlezen.
#
MANIFEST_RUN_ID=$(json_get "$MANIFEST" run_id 2>/dev/null || true)
HOSTNAME=$(json_get "$MANIFEST" hostname 2>/dev/null || true)
ORACLE_HOME=$(json_get "$MANIFEST" target_oracle_home 2>/dev/null || true)

STATE_RUN_ID=$(json_get "$STATE_FILE" run_id 2>/dev/null || true)
STATE=$(json_get "$STATE_FILE" state 2>/dev/null || true)
PHASE=$(json_get "$STATE_FILE" phase 2>/dev/null || true)

ASSESS_RUN_ID=$(json_get "$ASSESSMENT" run_id 2>/dev/null || true)
ASSESS_STATUS=$(json_get "$ASSESSMENT" status 2>/dev/null || true)
BLOCKED_COUNT=$(json_get "$ASSESSMENT" blocked_count 2>/dev/null || true)
UNKNOWN_COUNT=$(json_get "$ASSESSMENT" unknown_count 2>/dev/null || true)

#
# RUN_ID moet in alle artifacts exact overeenkomen.
#
[[ "$MANIFEST_RUN_ID" == "$RUN_ID" ]] || {
    error "RUN_ID mismatch in patch_manifest.json: ${MANIFEST_RUN_ID:-MISSING}"
    exit "$EXIT_BLOCKED"
}

[[ "$STATE_RUN_ID" == "$RUN_ID" ]] || {
    error "RUN_ID mismatch in execution_state.json: ${STATE_RUN_ID:-MISSING}"
    exit "$EXIT_BLOCKED"
}

[[ "$ASSESS_RUN_ID" == "$RUN_ID" ]] || {
    error "RUN_ID mismatch in assessment.json: ${ASSESS_RUN_ID:-MISSING}"
    exit "$EXIT_BLOCKED"
}

[[ -n "$HOSTNAME" && -n "$ORACLE_HOME" ]] || {
    error "Hostname of Oracle Home ontbreekt in patch_manifest.json."
    exit "$EXIT_BLOCKED"
}

#
# Alleen na succesvolle PLAN.
#
[[ "$STATE" == "03_PLAN_GENERATED" && "$PHASE" == "PLAN" ]] || {
    error "Run is niet klaar voor approval staging: state=${STATE:-UNKNOWN}, phase=${PHASE:-UNKNOWN}"
    exit "$EXIT_BLOCKED"
}

case "$ASSESS_STATUS" in
    READY|CONDITIONAL)
        ;;
    *)
        error "Assessment is niet approvable: ${ASSESS_STATUS:-UNKNOWN}"
        exit "$EXIT_BLOCKED"
        ;;
esac

[[ "$BLOCKED_COUNT" == "0" ]] || {
    error "Assessment bevat BLOCKED findings: $BLOCKED_COUNT"
    exit "$EXIT_BLOCKED"
}

[[ "$UNKNOWN_COUNT" == "0" ]] || {
    error "Assessment bevat UNKNOWN findings: $UNKNOWN_COUNT"
    exit "$EXIT_BLOCKED"
}

#
# Dubbele controle op findings.psv.
#
if awk -F'|' '$1 == "BLOCKED" || $1 == "UNKNOWN" {found=1} END {exit(found ? 0 : 1)}' "$FINDINGS"; then
    error "findings.psv bevat BLOCKED en/of UNKNOWN findings."
    exit "$EXIT_BLOCKED"
fi

#
# Manifest-integriteit lokaal controleren.
#
LOCAL_SHA=$(sha256sum "$MANIFEST" | awk '{print $1}')

[[ "$LOCAL_SHA" =~ ^[0-9a-f]{64}$ ]] || {
    error "Kan geen geldige SHA-256 voor patch_manifest.json bepalen."
    exit "$EXIT_ERROR"
}

if [[ -r "$MANIFEST_HASH_FILE" ]]; then
    RECORDED_SHA=$(awk 'NR==1 {print $1}' "$MANIFEST_HASH_FILE")

    [[ "$RECORDED_SHA" == "$LOCAL_SHA" ]] || {
        error "patch_manifest.json wijkt af van patch_manifest.sha256."
        exit "$EXIT_BLOCKED"
    }
fi

#
# Een bestaande approval-set wordt nooit vanuit staging overschreven.
#
if [[ -e "$DST" ]]; then
    error "Approval directory bestaat al: $DST"
    error "Staging weigert bestaande approval-input of signatures te overschrijven."
    exit "$EXIT_BLOCKED"
fi

#
# Maak eerst een tijdelijke directory op dezelfde filesystem-share.
# Daarna atomisch hernoemen naar de definitieve RUN_ID-directory.
#
TMP_DIR=$(mktemp -d "/tmp/opg-approval-stage.${RUN_ID}.XXXXXX") || {
    error "Kan tijdelijke staging-directory niet maken."
    exit "$EXIT_ERROR"
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        case "$TMP_DIR" in
            /tmp/opg-approval-stage.${RUN_ID}.*) rm -rf -- "$TMP_DIR" ;;
            *) error "Cleanup weigerde onverwacht tijdelijk pad: $TMP_DIR" ;;
        esac
    fi
}

trap cleanup EXIT

chmod 0750 "$TMP_DIR"

cp -p "$MANIFEST" "$TMP_DIR/patch_manifest.json"
cp -p "$ASSESSMENT" "$TMP_DIR/assessment.json"
cp -p "$FINDINGS" "$TMP_DIR/findings.psv"
cp -p "$STATE_FILE" "$TMP_DIR/execution_state.json"

#
# Controleer na kopiëren expliciet dat het manifest byte-identiek is.
#
STAGED_SHA=$(sha256sum "$TMP_DIR/patch_manifest.json" | awk '{print $1}')

[[ "$STAGED_SHA" == "$LOCAL_SHA" ]] || {
    error "SHA-256 mismatch na staging."
    exit "$EXIT_ERROR"
}

#
# Ook de andere drie bestanden moeten byte-identiek zijn.
#
for name in assessment.json findings.psv execution_state.json
do
    SRC_SHA=$(sha256sum "$SRC/$name" | awk '{print $1}')
    DST_SHA=$(sha256sum "$TMP_DIR/$name" | awk '{print $1}')

    [[ "$SRC_SHA" == "$DST_SHA" ]] || {
        error "SHA-256 mismatch na staging: $name"
        exit "$EXIT_ERROR"
    }
done

#
# Approval-inputs read-only maken voor normale verwerking.
#
chmod 0440 \
    "$TMP_DIR/patch_manifest.json" \
    "$TMP_DIR/assessment.json" \
    "$TMP_DIR/findings.psv" \
    "$TMP_DIR/execution_state.json"

#
# De lokale root-helper ontvangt uitsluitend een tarstream met vier vaste
# bestandsnamen. Er wordt geen stagingpad aan de privileged boundary gegeven.
#
set +e
tar -C "$TMP_DIR" -cf - \
    patch_manifest.json \
    assessment.json \
    findings.psv \
    execution_state.json | "$SUDO_BIN" -n "$CONTEXT_HELPER" publish-approval-stage "$RUN_ID"
PIPE_RC=("${PIPESTATUS[@]}")
set -e

if (( PIPE_RC[0] != 0 )); then
    error "Approvalstream kon niet betrouwbaar worden opgebouwd."
    exit "$EXIT_ERROR"
fi
case "${PIPE_RC[1]}" in
    0) ;;
    "$EXIT_BLOCKED")
        error "Root-helper heeft approvalpublicatie veilig geweigerd."
        exit "$EXIT_BLOCKED"
        ;;
    *)
        error "Root-helper kon approvalstage niet publiceren."
        exit "$EXIT_ERROR"
        ;;
esac

[[ -d "$DST" && ! -L "$DST" ]] || {
    error "Gepubliceerde approvaldirectory ontbreekt of is onveilig."
    exit "$EXIT_ERROR"
}
[[ "$(stat -c '%U:%G:%a' "$DST")" == "${APPROVAL_DIRECTORY_OWNER}:${APPROVAL_GROUP}:750" ]] || {
    error "Gepubliceerde approvaldirectory heeft onjuiste ownership/mode."
    exit "$EXIT_ERROR"
}
for name in patch_manifest.json assessment.json findings.psv execution_state.json
do
    [[ -f "$DST/$name" && ! -L "$DST/$name" ]] || {
        error "Gepubliceerd approvalartifact ontbreekt of is onveilig: $name"
        exit "$EXIT_ERROR"
    }
    [[ "$(stat -c '%U:%G:%a' "$DST/$name")" == "${APPROVAL_DIRECTORY_OWNER}:${APPROVAL_GROUP}:440" ]] || {
        error "Gepubliceerd approvalartifact heeft onjuiste ownership/mode: $name"
        exit "$EXIT_ERROR"
    }
    [[ "$(sha256sum "$SRC/$name" | awk '{print $1}')" == "$(sha256sum "$DST/$name" | awk '{print $1}')" ]] || {
        error "SHA-256 mismatch na privileged publicatie: $name"
        exit "$EXIT_ERROR"
    }
done

trap - EXIT
rm -rf -- "$TMP_DIR"
TMP_DIR=

printf '\n'
printf '====================================================================\n'
printf ' Oracle Patch Guard - APPROVAL STAGING\n'
printf '====================================================================\n\n'

printf 'Host        : %s\n' "$HOSTNAME"
printf 'Oracle Home : %s\n' "$ORACLE_HOME"
printf 'Run ID      : %s\n' "$RUN_ID"
printf 'Assessment  : %s\n' "$ASSESS_STATUS"
printf 'State       : %s / %s\n' "$STATE" "$PHASE"
printf 'Manifest    : %s\n' "$LOCAL_SHA"
printf 'Destination : %s\n' "$DST"

printf '\nStaged files\n'
printf -- '------------\n'
printf 'patch_manifest.json\n'
printf 'assessment.json\n'
printf 'findings.psv\n'
printf 'execution_state.json\n'

printf '\nRESULT: WAITING FOR APPROVAL\n\n'

printf 'OPG_STAGE_RESULT|run_id=%s|host=%s|home=%s|status=STAGED|next=WAITING_FOR_APPROVAL|manifest_sha256=%s\n' \
    "$RUN_ID" \
    "$HOSTNAME" \
    "$ORACLE_HOME" \
    "$LOCAL_SHA"

exit 0
