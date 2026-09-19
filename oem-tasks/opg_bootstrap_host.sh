#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${OPG_BOOTSTRAP_TEST_MODE:-0} == 1 ]]; then
    TEST_ROOT=${OPG_BOOTSTRAP_TEST_ROOT:-}
    [[ "$TEST_ROOT" == /tmp/opg-bootstrap-tests.* ]] || {
        printf 'OPG_BOOTSTRAP_RESULT|status=FAILED|exit_code=30|message=ongeldige testroot\n' >&2
        exit 30
    }
    BASE="$TEST_ROOT/base/current"
    DST_CONTEXT="$TEST_ROOT/usr/local/sbin/opg_context_root.sh"
    DST_MEDIA_SH="$TEST_ROOT/usr/local/sbin/opg_media_stage_root.sh"
    DST_MEDIA_PY="$TEST_ROOT/usr/local/libexec/opg_media_stage_root.py"
    STAGE_ANCHOR="$TEST_ROOT/u01/stage"
    STAGE_ROOT="$TEST_ROOT/u01/stage/oracle-patch-guard"
    SUDOERS_DST="$TEST_ROOT/etc/sudoers.d/oracle-patch-guard-context"
    CONFIG_DST="$TEST_ROOT/etc/oracle-patch-guard/patchGD_guard.conf"
    CONTEXT_ROOT="$TEST_ROOT/var/lib/oracle-patch-guard"
    LOG_ROOT="$TEST_ROOT/var/log/oracle-patch-guard"
    VISUDO_BIN=${OPG_BOOTSTRAP_TEST_VISUDO:-$TEST_ROOT/usr/sbin/visudo}
    RUN_USER=root
    PRIVILEGED_GROUP=root
    STAGE_GROUP=root
    CONFIG_GROUP=root
else
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    BASE=${OPG_BOOTSTRAP_BASE:-/mnt/datadomain/software/patches/Linux/oracle-patch-guard/current}
    DST_CONTEXT=/usr/local/sbin/opg_context_root.sh
    DST_MEDIA_SH=/usr/local/sbin/opg_media_stage_root.sh
    DST_MEDIA_PY=/usr/local/libexec/opg_media_stage_root.py
    STAGE_ANCHOR=/u01/stage
    STAGE_ROOT=/u01/stage/oracle-patch-guard
    SUDOERS_DST=/etc/sudoers.d/oracle-patch-guard-context
    CONFIG_DST=/etc/oracle-patch-guard/patchGD_guard.conf
    CONTEXT_ROOT=/var/lib/oracle-patch-guard
    LOG_ROOT=/var/log/oracle-patch-guard
    VISUDO_BIN=/usr/sbin/visudo
    RUN_USER=oracle
    PRIVILEGED_GROUP=root
    STAGE_GROUP=oinstall
    CONFIG_GROUP=oinstall
fi

SRC_CONTEXT="$BASE/oem-tasks/opg_context_root.sh"
SRC_MEDIA_SH="$BASE/oem-tasks/opg_media_stage_root.sh"
SRC_MEDIA_PY="$BASE/oem-tasks/opg_media_stage_root.py"
SRC_SUDOERS="$BASE/config/examples/oracle-patch-guard-context.sudoers"
SUDOERS_DIR=${SUDOERS_DST%/*}
CONFIG_DIR=${CONFIG_DST%/*}
KEY_DST="$CONFIG_DIR/approval_public.pem"
PROCEDURE_DST="$CONFIG_DIR/oracle_home_rebuild.md"
declare -A CONFIG_VALUES=()
SUDOERS_TEMP=
CONFIG_TEMP=
SOURCE_STAGE=

log() {
    printf 'OPG_BOOTSTRAP|%s\n' "$*"
}

fail() {
    local msg="$1"
    printf 'OPG_BOOTSTRAP_RESULT|status=FAILED|exit_code=30|message=%s\n' "$msg" >&2
    exit 30
}

[[ "$BASE" == /*/current && "$BASE" != /current ]] \
    || fail "BASE moet een absoluut Oracle Patch Guard-currentpad zijn: $BASE"
OPG_ROOT=${BASE%/current}
[[ "$OPG_ROOT" == /* && "$OPG_ROOT" =~ ^/[A-Za-z0-9_./-]+$ && "$OPG_ROOT" != *'//'*
   && "$OPG_ROOT" != */../* && "$OPG_ROOT" != */./* && "$OPG_ROOT" != */.. && "$OPG_ROOT" != */. ]] \
    || fail "OPG_ROOT kon niet veilig uit BASE worden afgeleid"
SRC_CONFIG="$OPG_ROOT/config/patchGD_guard.conf"
SRC_KEY="$OPG_ROOT/config/approval_public.pem"
SRC_PROCEDURE="$OPG_ROOT/config/oracle_home_rebuild.md"

cleanup() {
    if [[ -n ${SOURCE_STAGE:-} ]]; then
        rm -f -- "$SOURCE_STAGE"/*
        rmdir -- "$SOURCE_STAGE"
    fi
    if [[ -n ${SUDOERS_TEMP:-} && -f $SUDOERS_TEMP && ! -L $SUDOERS_TEMP ]]; then
        rm -f -- "$SUDOERS_TEMP"
    fi
    if [[ -n ${CONFIG_TEMP:-} && -f $CONFIG_TEMP && ! -L $CONFIG_TEMP ]]; then
        rm -f -- "$CONFIG_TEMP"
    fi
}
trap cleanup EXIT

validate_config_candidate() {
    local candidate=$1 raw key value required_key semantic_value
    declare -A seen=()
    declare -A required=(
        [PATCH_ROOT]=1
        [OPATCH_ROOT]=1
        [RUN_ROOT]=1
        [LOCK_ROOT]=1
        [OPG_ROOT]=1
        [APPROVAL_ROOT]=1
        [LOCAL_STAGE_ROOT]=1
        [MEDIA_STAGE_HELPER]=1
        [APPROVAL_PUBLIC_KEY]=1
        [HOME_RECOVERY_PROCEDURE]=1
    )

    bash -n "$candidate" || fail "config is geen geldige shellconfig"
    CONFIG_VALUES=()
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        raw=${raw%$'\r'}
        raw=${raw#"${raw%%[![:space:]]*}"}
        raw=${raw%"${raw##*[![:space:]]}"}
        [[ -n "$raw" && ${raw:0:1} != '#' ]] || continue
        [[ "$raw" == *=* ]] || fail "ongeldige configregel zonder KEY=VALUE"
        key=${raw%%=*}; value=${raw#*=}
        key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "ongeldige configsleutel: $key"
        [[ "$raw" == "${key}="* && "${raw#*=}" != [[:space:]]* ]] || fail "config vereist shell KEY=VALUE zonder spaties rond '=': $key"
        [[ -z ${seen[$key]+x} ]] || fail "dubbele configsleutel: $key"
        seen[$key]=1
        semantic_value=$value
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then semantic_value=${value:1:${#value}-2}; fi
        CONFIG_VALUES[$key]=$semantic_value
        if [[ -n ${required[$key]+x} ]]; then
            [[ -n "$value" ]] || fail "lege verplichte configwaarde: $key"
            [[ "$value" == /* && "$value" =~ ^/[A-Za-z0-9_./-]+$ && "$value" != *'//'*
               && "$value" != */../* && "$value" != */./* && "$value" != */.. && "$value" != */. ]] \
                || fail "ongeldig absoluut pad voor $key"
        fi
    done <"$candidate"

    for required_key in "${!required[@]}"; do
        [[ -n ${seen[$required_key]+x} ]] \
            || fail "verplichte configsleutel ontbreekt: $required_key"
    done
    [[ ${CONFIG_VALUES[LOCAL_MEDIA_MODE]:-} == required ]] || fail "LOCAL_MEDIA_MODE=required ontbreekt"
    [[ ${CONFIG_VALUES[OPG_ROOT]} == "$OPG_ROOT" ]] || fail "OPG_ROOT wijkt af van bootstrap-release"
    [[ ${CONFIG_VALUES[LOCAL_STAGE_ROOT]} == "$STAGE_ROOT" ]] || fail "LOCAL_STAGE_ROOT wijkt af van vaste stage-root"
    [[ ${CONFIG_VALUES[MEDIA_STAGE_HELPER]} == "$DST_MEDIA_SH" ]] || fail "MEDIA_STAGE_HELPER wijkt af van geïnstalleerde helper"
    [[ ${CONFIG_VALUES[APPROVAL_PUBLIC_KEY]} == "$KEY_DST" ]] || fail "APPROVAL_PUBLIC_KEY wijkt af van bootstrap-doel"
    [[ ${CONFIG_VALUES[HOME_RECOVERY_PROCEDURE]} == "$PROCEDURE_DST" ]] || fail "HOME_RECOVERY_PROCEDURE wijkt af van bootstrap-doel"
    [[ ${CONFIG_VALUES[RUN_ROOT]} != / && ${CONFIG_VALUES[LOCK_ROOT]} != / &&
       ${CONFIG_VALUES[RUN_ROOT]} != "${CONFIG_VALUES[LOCK_ROOT]}" ]] || fail "onveilige RUN_ROOT/LOCK_ROOT"
    [[ ${CONFIG_VALUES[ALLOW_TEST_MODE]:-false} == false ]] || fail "ALLOW_TEST_MODE moet false blijven"

    # Hooks are optional. If configured, reject missing executables rather than
    # installing a config that depends on an undocumented /opt copy.
    for key in BACKUP_CHECK_COMMAND ORACLE_HOME_RECOVERY_CHECK_COMMAND MAINTENANCE_WINDOW_CHECK_COMMAND DATAGUARD_CHECK_COMMAND; do
        value=${CONFIG_VALUES[$key]:-}
        [[ -n "$value" ]] || continue
        [[ "$value" =~ ^/[A-Za-z0-9_./-]+$ && -f "$value" && -x "$value" && ! -L "$value" ]] \
            || fail "geconfigureerde hook ontbreekt of is onveilig: $key"
    done
    if [[ ${CONFIG_VALUES[BACKUP_CHECK_COMMAND]:-} == */check_rman_backup ]]; then
        for key in EXPECTED_SBT_LIBRARY EXPECTED_BACKUP_HOST EXPECTED_STORAGE_UNIT; do
            value=${CONFIG_VALUES[$key]:-}
            [[ "$value" =~ [^[:space:]] && "$value" != *example.com* ]] \
                || fail "sitewaarde ontbreekt voor RMAN-hook: $key"
        done
    fi
    if [[ ${CONFIG_VALUES[ORACLE_HOME_RECOVERY_CHECK_COMMAND]:-} == */check_oracle_home_recovery ]]; then
        value=${CONFIG_VALUES[RECOVERY_BASE_IMAGE]:-}
        [[ "$value" == /* && -r "$value" && -f "$value" && ! -L "$value" ]] \
            || fail "RECOVERY_BASE_IMAGE ontbreekt of is onveilig"
        for key in RECOVERY_BASE_IMAGE_SHA256 OPATCH_ZIP_SHA256; do
            [[ ${CONFIG_VALUES[$key]:-} =~ ^[A-Fa-f0-9]{64}$ ]] || fail "geldige checksum ontbreekt: $key"
        done
    fi
    value=${CONFIG_VALUES[MAINTENANCE_WINDOW_CHECK_COMMAND]:-}
    if [[ "$value" == "$BASE/project/checks/check_maintenance_window" ]] ||
       { [[ -n "$value" ]] && cmp -s "$value" "$BASE/project/checks/check_maintenance_window"; }; then
        [[ ${CONFIG_VALUES[MAINTENANCE_WINDOW_MANIFEST]:-} =~ ^/[A-Za-z0-9_./-]+$ ]] \
            || fail "MAINTENANCE_WINDOW_MANIFEST-pad ontbreekt"
        # CREATE-WINDOW supplies the actual lifecycle-bound file later.
    fi
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || fail "bootstrap moet als root draaien"

for dependency in bash python3 openssl sudo flock timeout sha256sum stat readlink realpath mktemp \
                  install cmp mv rm chown chmod awk grep sed cut head tail tr sort find xargs \
                  pgrep df du date hostname id getent unzip zipinfo cp cat sync rmdir; do
    command -v "$dependency" >/dev/null 2>&1 || fail "vereiste OS-tool ontbreekt: $dependency"
done
/usr/bin/python3 -I -c 'import sys, ssl, zipfile, hashlib, fcntl; assert sys.version_info >= (3, 6)' \
    || fail "Python 3.6+ met vereiste standaardmodules ontbreekt"
[[ -x /usr/bin/openssl ]] || fail "/usr/bin/openssl ontbreekt"
if ! id "$RUN_USER" >/dev/null 2>&1 || ! getent group "$STAGE_GROUP" >/dev/null; then
    fail "Oracle runtimegebruiker/groep ontbreekt"
fi

log "START|host=$(hostname -f 2>/dev/null || hostname)"

# ---------------------------------------------------------------------------
# Validate source files
# ---------------------------------------------------------------------------

for src in "$SRC_CONTEXT" "$SRC_MEDIA_SH" "$SRC_MEDIA_PY" "$SRC_SUDOERS" "$SRC_CONFIG" "$SRC_KEY" "$SRC_PROCEDURE"; do
    [[ -f "$src" ]] || fail "bronbestand ontbreekt: $src"
    [[ ! -L "$src" ]] || fail "bronbestand is een symlink: $src"
    [[ -r "$src" && -s "$src" ]] || fail "bronbestand is leeg of onleesbaar: $src"
    mode=$(stat -c '%a' "$src") || fail "bron-mode onleesbaar: $src"
    (( (8#$mode & 0022) == 0 )) || fail "bronbestand is group/world-writable: $src"
done
# Freeze the incoming bundle before validation; activation uses these same bytes.
SOURCE_STAGE=$(mktemp -d /tmp/opg-bootstrap-source.tmp.XXXXXX) || fail "staging mislukt"
for source_var in SRC_CONTEXT SRC_MEDIA_SH SRC_MEDIA_PY SRC_SUDOERS SRC_CONFIG SRC_KEY SRC_PROCEDURE; do
    src=${!source_var}
    install -o root -g root -m 0600 "$src" "$SOURCE_STAGE/$source_var" || fail "bronstaging mislukt"
    printf -v "$source_var" '%s' "$SOURCE_STAGE/$source_var"
done
for src in "$SRC_CONTEXT" "$SRC_MEDIA_SH"; do
    bash -n "$src" || fail "helper-shellsyntax ongeldig"
done
/usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$SRC_MEDIA_PY" \
    || fail "media-helper Python-syntax ongeldig"
for src in "$SRC_KEY" "$SRC_PROCEDURE"; do
    [[ -r "$src" && -s "$src" ]] || fail "centraal artifact is leeg of onleesbaar: $src"
    mode=$(stat -c '%a' "$src") || fail "artifact-mode onleesbaar: $src"
    (( (8#$mode & 0022) == 0 )) || fail "centraal artifact is group/world-writable: $src"
done
openssl pkey -pubin -in "$SRC_KEY" -noout >/dev/null 2>&1 || fail "approval_public.pem is geen geldige publieke sleutel"

config_source_mode=$(stat -c '%a' "$SRC_CONFIG") \
    || fail "stat mislukt voor centrale config: $SRC_CONFIG"
[[ "$config_source_mode" =~ ^[0-7]{3,4}$ ]] \
    || fail "centrale config heeft ongeldige mode: $config_source_mode"
(( (8#$config_source_mode & 0022) == 0 )) \
    || fail "centrale config is group/world-writable: $SRC_CONFIG"
validate_config_candidate "$SRC_CONFIG"
LOG_ROOT=${CONFIG_VALUES[RUN_ROOT]}
LOCK_ROOT=${CONFIG_VALUES[LOCK_ROOT]}
for runtime in "$BASE/oem-tasks/opg_oem.sh" "$BASE/project/patchGD_guard.sh"; do
    [[ -f "$runtime" && -x "$runtime" && ! -L "$runtime" ]] || fail "release-runtime ontbreekt: $runtime"
done
[[ -f "$BASE/project/lib/opg_core.sh" && -r "$BASE/project/lib/opg_core.sh" ]] || fail "core-library ontbreekt"

# Read-only destination preflight. No installed file or directory changes until
# every incoming artifact and existing installation prerequisite has passed.
validate_existing_directory() {
    local target=$1 expected=$2 parent
    parent=$target
    while [[ "$parent" != / ]]; do
        [[ ! -L "$parent" ]] || fail "directorypad bevat symlink: $parent"
        if [[ -e "$parent" ]]; then
            [[ -d "$parent" ]] || fail "directorypad is geen directory: $parent"
        fi
        parent=${parent%/*}; parent=${parent:-/}
    done
    if [[ -e "$target" ]]; then
        [[ $(stat -c '%U:%G:%a' "$target") == "$expected" ]] \
            || fail "onjuiste owner/mode voor directory: $target"
    fi
}
for spec in "$LOG_ROOT|${RUN_USER}:${STAGE_GROUP}:750" \
            "$LOCK_ROOT|root:${STAGE_GROUP}:2770" \
            "${DST_CONTEXT%/*}|root:${PRIVILEGED_GROUP}:755" \
            "${DST_MEDIA_PY%/*}|root:${PRIVILEGED_GROUP}:755" \
            "$CONFIG_DIR|root:root:755" "$STAGE_ANCHOR|root:${PRIVILEGED_GROUP}:755" \
            "$STAGE_ROOT|root:${STAGE_GROUP}:750" \
            "$STAGE_ROOT/.locks|root:${STAGE_GROUP}:750" \
            "$STAGE_ROOT/purging|root:${STAGE_GROUP}:750" \
            "$STAGE_ROOT/incoming|root:${STAGE_GROUP}:750" \
            "$STAGE_ROOT/ready|root:${STAGE_GROUP}:750" \
            "$CONTEXT_ROOT|root:${STAGE_GROUP}:750" \
            "$CONTEXT_ROOT/stage-cleanup|root:${STAGE_GROUP}:750"; do
    validate_existing_directory "${spec%%|*}" "${spec#*|}"
done
[[ -d ${STAGE_ANCHOR%/stage} && ! -L ${STAGE_ANCHOR%/stage} ]] || fail "stage-parent ontbreekt of is onveilig"
for spec in "$DST_CONTEXT|root:${PRIVILEGED_GROUP}:755" \
            "$DST_MEDIA_SH|root:${PRIVILEGED_GROUP}:755" \
            "$DST_MEDIA_PY|root:${PRIVILEGED_GROUP}:755" \
            "$SUDOERS_DST|root:root:440" "$CONFIG_DST|root:${CONFIG_GROUP}:640" \
            "$KEY_DST|root:${CONFIG_GROUP}:640" "$PROCEDURE_DST|root:${CONFIG_GROUP}:640" \
            "$STAGE_ROOT/.locks/media-stage.lock|root:${STAGE_GROUP}:640"; do
    target=${spec%%|*}
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" && $(stat -c '%h' "$target") == 1 &&
           $(stat -c '%U:%G:%a' "$target") == "${spec#*|}" ]] || fail "onveilig installatiedoel: $target"
    fi
done
[[ -d "$SUDOERS_DIR" && ! -L "$SUDOERS_DIR" ]] || fail "sudoers-directory ontbreekt of is onveilig"
sudoers_dir_identity=$(stat -c '%U:%G:%a' "$SUDOERS_DIR")
[[ "$sudoers_dir_identity" =~ ^root:root:[0-7]{3,4}$ ]] || fail "onveilige sudoers-directory"
(( (8#${sudoers_dir_identity##*:} & 0022) == 0 )) || fail "schrijfbare sudoers-directory"
[[ -x "$VISUDO_BIN" && -f "$VISUDO_BIN" && ! -L "$VISUDO_BIN" ]] || fail "visudo ontbreekt of is onveilig"
"$VISUDO_BIN" -cf "$SRC_SUDOERS" || fail "meegeleverde sudoers-file faalt visudo-validatie"

# All preflight validation succeeded. Begin activation.

# ---------------------------------------------------------------------------
# Authoritative run-log root
# ---------------------------------------------------------------------------

if [[ -e "$LOG_ROOT" || -L "$LOG_ROOT" ]]; then
    [[ -d "$LOG_ROOT" && ! -L "$LOG_ROOT" ]] \
        || fail "bestaande LOG_ROOT is geen veilige directory: $LOG_ROOT"
else
    install -d -o "$RUN_USER" -g "$STAGE_GROUP" -m 0750 "$LOG_ROOT" \
        || fail "LOG_ROOT kon niet veilig worden gemaakt: $LOG_ROOT"
    log "CREATED|$LOG_ROOT"
fi

log_root_identity=$(stat -c '%U:%G:%a' "$LOG_ROOT") \
    || fail "stat mislukt voor LOG_ROOT: $LOG_ROOT"
[[ "$log_root_identity" == "${RUN_USER}:${STAGE_GROUP}:750" ]] \
    || fail "onjuiste owner/mode voor LOG_ROOT: $log_root_identity"
log "LOG_ROOT_OK|$LOG_ROOT|owner=${RUN_USER}|group=${STAGE_GROUP}|mode=750"

# ---------------------------------------------------------------------------
# Ensure local privileged directories exist
# ---------------------------------------------------------------------------

install -d -o root -g "$PRIVILEGED_GROUP" -m 0755 "${DST_CONTEXT%/*}"
install -d -o root -g "$PRIVILEGED_GROUP" -m 0755 "${DST_MEDIA_PY%/*}"

# ---------------------------------------------------------------------------
# Install/update privileged helpers
# ---------------------------------------------------------------------------

install_if_changed() {
    local src="$1"
    local dst="$2"

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        log "UNCHANGED|$dst"
    else
        CONFIG_TEMP=$(mktemp "${dst%/*}/.opg-helper.XXXXXX") || fail "helperstaging mislukt"
        install -o root -g "$PRIVILEGED_GROUP" -m 0755 "$src" "$CONFIG_TEMP"
        mv -f -- "$CONFIG_TEMP" "$dst"
        CONFIG_TEMP=
        log "INSTALLED|$dst"
    fi

    [[ -f "$dst" ]] || fail "doelbestand ontbreekt na installatie: $dst"
    [[ ! -L "$dst" ]] || fail "doelbestand is een symlink: $dst"

    local identity
    identity=$(stat -c '%U:%G:%a' "$dst") \
        || fail "stat mislukt voor: $dst"

    [[ "$identity" == "root:${PRIVILEGED_GROUP}:755" ]] \
        || fail "onjuiste owner/mode voor $dst: $identity"
}

install_if_changed "$SRC_CONTEXT" "$DST_CONTEXT"
install_if_changed "$SRC_MEDIA_SH" "$DST_MEDIA_SH"
install_if_changed "$SRC_MEDIA_PY" "$DST_MEDIA_PY"

# ---------------------------------------------------------------------------
# Verify installed helper hashes
# ---------------------------------------------------------------------------

verify_hash() {
    local src="$1"
    local dst="$2"
    local src_hash
    local dst_hash

    src_hash=$(sha256sum "$src" | awk '{print $1}') \
        || fail "SHA256 bron mislukt: $src"

    dst_hash=$(sha256sum "$dst" | awk '{print $1}') \
        || fail "SHA256 doel mislukt: $dst"

    [[ "$src_hash" == "$dst_hash" ]] \
        || fail "hash mismatch voor $dst"

    log "HASH_OK|$dst|sha256=$dst_hash"
}

verify_hash "$SRC_CONTEXT" "$DST_CONTEXT"
verify_hash "$SRC_MEDIA_SH" "$DST_MEDIA_SH"
verify_hash "$SRC_MEDIA_PY" "$DST_MEDIA_PY"

# ---------------------------------------------------------------------------
# Validate and atomically install the supplied sudoers policy
# ---------------------------------------------------------------------------

install_sudoers() {
    local dir_identity target_identity

    [[ -d "$SUDOERS_DIR" && ! -L "$SUDOERS_DIR" ]] \
        || fail "sudoers-directory ontbreekt of is onveilig: $SUDOERS_DIR"
    dir_identity=$(stat -c '%U:%G:%a' "$SUDOERS_DIR") \
        || fail "stat mislukt voor sudoers-directory: $SUDOERS_DIR"
    [[ "$dir_identity" =~ ^root:root:[0-7]{3,4}$ ]] \
        || fail "sudoers-directory heeft onveilige owner/mode: $dir_identity"
    (( (8#${dir_identity##*:} & 0022) == 0 )) \
        || fail "sudoers-directory is group/world-writable: $SUDOERS_DIR"
    [[ -x "$VISUDO_BIN" && -f "$VISUDO_BIN" && ! -L "$VISUDO_BIN" ]] \
        || fail "visudo ontbreekt of is onveilig: $VISUDO_BIN"
    if [[ -e "$SUDOERS_DST" || -L "$SUDOERS_DST" ]]; then
        [[ -f "$SUDOERS_DST" && ! -L "$SUDOERS_DST" ]] \
            || fail "bestaande sudoers-doel is geen veilig regulier bestand"
    fi

    SUDOERS_TEMP=$(mktemp "${SUDOERS_DIR}/.oracle-patch-guard-context.tmp.XXXXXX") \
        || fail "tijdelijk sudoers-bestand kon niet worden gemaakt"
    install -o root -g root -m 0440 "$SRC_SUDOERS" "$SUDOERS_TEMP" \
        || fail "sudoers-candidate kon niet veilig worden gestaged"
    cmp -s "$SRC_SUDOERS" "$SUDOERS_TEMP" \
        || fail "sudoers-candidate wijkt af van meegeleverde bron"
    "$VISUDO_BIN" -cf "$SUDOERS_TEMP" \
        || fail "meegeleverde sudoers-file faalt visudo-validatie"

    if [[ -f "$SUDOERS_DST" ]] && cmp -s "$SUDOERS_TEMP" "$SUDOERS_DST"; then
        target_identity=$(stat -c '%U:%G:%a' "$SUDOERS_DST") \
            || fail "stat mislukt voor bestaande sudoers-file"
        if [[ "$target_identity" == root:root:440 ]]; then
            rm -f -- "$SUDOERS_TEMP"
            SUDOERS_TEMP=
            log "UNCHANGED|$SUDOERS_DST"
            return 0
        fi
    fi

    mv -f -- "$SUDOERS_TEMP" "$SUDOERS_DST" \
        || fail "sudoers-file kon niet atomisch worden geactiveerd"
    SUDOERS_TEMP=
    target_identity=$(stat -c '%U:%G:%a' "$SUDOERS_DST") \
        || fail "stat mislukt voor geïnstalleerde sudoers-file"
    [[ "$target_identity" == root:root:440 ]] \
        || fail "onjuiste owner/mode voor sudoers-file: $target_identity"
    log "INSTALLED|$SUDOERS_DST"
}

install_sudoers

# ---------------------------------------------------------------------------
# Validate and atomically install the central runtime configuration
# ---------------------------------------------------------------------------

install_runtime_config() {
    local dir_identity target_identity source=${1:-$SRC_CONFIG} destination=${2:-$CONFIG_DST}

    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] \
            || fail "configdirectory is geen veilige directory: $CONFIG_DIR"
    else
        install -d -o root -g root -m 0755 "$CONFIG_DIR" \
            || fail "configdirectory kon niet worden gemaakt: $CONFIG_DIR"
        log "CREATED|$CONFIG_DIR"
    fi
    install -d -o root -g root -m 0755 "$CONFIG_DIR" \
        || fail "configdirectory owner/mode kon niet worden afgedwongen"
    dir_identity=$(stat -c '%U:%G:%a' "$CONFIG_DIR") \
        || fail "stat mislukt voor configdirectory"
    [[ "$dir_identity" == root:root:755 ]] \
        || fail "onjuiste owner/mode voor configdirectory: $dir_identity"

    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] \
            || fail "bestaande lokale config is geen veilig regulier bestand"
    fi

    CONFIG_TEMP=$(mktemp "${CONFIG_DIR}/.patchGD_guard.conf.tmp.XXXXXX") \
        || fail "tijdelijke configcandidate kon niet worden gemaakt"
    install -o root -g "$CONFIG_GROUP" -m 0640 "$source" "$CONFIG_TEMP" \
        || fail "configcandidate kon niet veilig worden gestaged"
    cmp -s "$source" "$CONFIG_TEMP" \
        || fail "configcandidate wijkt af van centrale bron"
    if [[ "$destination" == "$CONFIG_DST" ]]; then
        validate_config_candidate "$CONFIG_TEMP"
        [[ ${CONFIG_VALUES[RUN_ROOT]} == "$LOG_ROOT" && ${CONFIG_VALUES[LOCK_ROOT]} == "$LOCK_ROOT" ]] \
            || fail "centrale runtimepaden wijzigden tijdens bootstrap"
    elif [[ "$destination" == "$KEY_DST" ]]; then
        openssl pkey -pubin -in "$CONFIG_TEMP" -noout >/dev/null 2>&1 || fail "ongeldige public-key candidate"
    else
        [[ -s "$CONFIG_TEMP" ]] || fail "lege herstelprocedure-candidate"
    fi

    if [[ -f "$destination" ]] && cmp -s "$CONFIG_TEMP" "$destination"; then
        target_identity=$(stat -c '%U:%G:%a' "$destination") \
            || fail "stat mislukt voor bestaande lokale config"
        if [[ "$target_identity" == "root:${CONFIG_GROUP}:640" ]]; then
            rm -f -- "$CONFIG_TEMP"
            CONFIG_TEMP=
            log "UNCHANGED|$destination"
            return 0
        fi
    fi

    mv -f -- "$CONFIG_TEMP" "$destination" \
        || fail "runtimeconfig kon niet atomisch worden geactiveerd"
    CONFIG_TEMP=
    target_identity=$(stat -c '%U:%G:%a' "$destination") \
        || fail "stat mislukt voor geïnstalleerde runtimeconfig"
    [[ "$target_identity" == "root:${CONFIG_GROUP}:640" ]] \
        || fail "onjuiste owner/mode voor runtimeconfig: $target_identity"
    log "INSTALLED|$destination"
}

# ---------------------------------------------------------------------------
# Trusted local stage anchor
# ---------------------------------------------------------------------------

U01_ROOT=${STAGE_ANCHOR%/stage}
[[ -d "$U01_ROOT" ]] || fail "$U01_ROOT ontbreekt"
[[ ! -L "$U01_ROOT" ]] || fail "$U01_ROOT is een symlink"

if [[ ! -e "$STAGE_ANCHOR" ]]; then
    install -d -o root -g "$PRIVILEGED_GROUP" -m 0755 "$STAGE_ANCHOR"
    log "CREATED|$STAGE_ANCHOR"
fi

[[ -d "$STAGE_ANCHOR" ]] \
    || fail "trusted stage anchor is geen directory: $STAGE_ANCHOR"

[[ ! -L "$STAGE_ANCHOR" ]] \
    || fail "trusted stage anchor is een symlink: $STAGE_ANCHOR"

stage_anchor_identity=$(stat -c '%U:%G:%a' "$STAGE_ANCHOR") \
    || fail "stat mislukt voor $STAGE_ANCHOR"

[[ "$stage_anchor_identity" == "root:${PRIVILEGED_GROUP}:755" ]] \
    || fail "onjuiste owner/mode voor $STAGE_ANCHOR: $stage_anchor_identity"

log "STAGE_ANCHOR_OK|$STAGE_ANCHOR|owner=root|group=${PRIVILEGED_GROUP}|mode=755"

# ---------------------------------------------------------------------------
# OPG stage management root
# ---------------------------------------------------------------------------

if [[ ! -e "$STAGE_ROOT" ]]; then
    install -d -o root -g "$STAGE_GROUP" -m 0750 "$STAGE_ROOT"
    log "CREATED|$STAGE_ROOT"
fi

[[ -d "$STAGE_ROOT" ]] \
    || fail "OPG stage root is geen directory: $STAGE_ROOT"

[[ ! -L "$STAGE_ROOT" ]] \
    || fail "OPG stage root is een symlink: $STAGE_ROOT"

stage_root_identity=$(stat -c '%U:%G:%a' "$STAGE_ROOT") \
    || fail "stat mislukt voor $STAGE_ROOT"

[[ "$stage_root_identity" == "root:${STAGE_GROUP}:750" ]] \
    || fail "onjuiste owner/mode voor $STAGE_ROOT: $stage_root_identity"

log "STAGE_ROOT_OK|$STAGE_ROOT|owner=root|group=${STAGE_GROUP}|mode=750"

# ---------------------------------------------------------------------------
# Stage coordination and cleanup evidence
# ---------------------------------------------------------------------------

for managed_dir in "$STAGE_ROOT/.locks" "$STAGE_ROOT/purging" "$STAGE_ROOT/incoming" "$STAGE_ROOT/ready"; do
    if [[ -e "$managed_dir" || -L "$managed_dir" ]]; then
        [[ -d "$managed_dir" && ! -L "$managed_dir" ]] || fail "stage-beheerdirectory is onveilig: $managed_dir"
    fi
    install -d -o root -g "$STAGE_GROUP" -m 0750 "$managed_dir"
done
MEDIA_LOCK="$STAGE_ROOT/.locks/media-stage.lock"
if [[ -e "$MEDIA_LOCK" || -L "$MEDIA_LOCK" ]]; then
    [[ -f "$MEDIA_LOCK" && ! -L "$MEDIA_LOCK" && $(stat -c '%h' "$MEDIA_LOCK") == 1 ]] || fail "media-lock is onveilig: $MEDIA_LOCK"
    chown root:"$STAGE_GROUP" "$MEDIA_LOCK"
    chmod 0640 "$MEDIA_LOCK"
else
    install -o root -g "$STAGE_GROUP" -m 0640 /dev/null "$MEDIA_LOCK"
fi
for evidence_dir in "$CONTEXT_ROOT" "$CONTEXT_ROOT/stage-cleanup"; do
    if [[ -e "$evidence_dir" || -L "$evidence_dir" ]]; then
        [[ -d "$evidence_dir" && ! -L "$evidence_dir" ]] || fail "cleanup-evidencedirectory is onveilig: $evidence_dir"
    fi
    install -d -o root -g "$STAGE_GROUP" -m 0750 "$evidence_dir"
done
log "STAGE_LOCK_OK|$MEDIA_LOCK|owner=root|group=${STAGE_GROUP}|mode=640"
log "STAGE_CLEANUP_EVIDENCE_OK|$CONTEXT_ROOT/stage-cleanup|owner=root|group=${STAGE_GROUP}|mode=750"

if [[ -e "$LOCK_ROOT" || -L "$LOCK_ROOT" ]]; then
    [[ -d "$LOCK_ROOT" && ! -L "$LOCK_ROOT" && $(stat -c '%U:%G:%a' "$LOCK_ROOT") == "root:${STAGE_GROUP}:2770" ]] \
        || fail "bestaande LOCK_ROOT heeft onveilige owner/mode/type: $LOCK_ROOT"
else
    install -d -o root -g "$STAGE_GROUP" -m 2770 "$LOCK_ROOT"
fi
log "LOCK_ROOT_OK|$LOCK_ROOT"

# Activate local configuration only after prerequisites have been established.
install_runtime_config "$SRC_KEY" "$KEY_DST"
install_runtime_config "$SRC_PROCEDURE" "$PROCEDURE_DST"
install_runtime_config

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

for dst in "$DST_CONTEXT" "$DST_MEDIA_SH" "$DST_MEDIA_PY"; do
    identity=$(stat -c '%U:%G:%a' "$dst") \
        || fail "final stat mislukt: $dst"

    [[ "$identity" == "root:${PRIVILEGED_GROUP}:755" ]] \
        || fail "final helper validation mislukt voor $dst: $identity"
done

sudoers_identity=$(stat -c '%U:%G:%a' "$SUDOERS_DST") \
    || fail "final stat mislukt voor sudoers-file"
[[ "$sudoers_identity" == root:root:440 ]] \
    || fail "final sudoers-validatie mislukt: $sudoers_identity"

config_identity=$(stat -c '%U:%G:%a' "$CONFIG_DST") \
    || fail "final stat mislukt voor runtimeconfig"
[[ "$config_identity" == "root:${CONFIG_GROUP}:640" ]] \
    || fail "final configvalidatie mislukt: $config_identity"

printf 'OPG_BOOTSTRAP_RESULT|status=READY|exit_code=0\n'
