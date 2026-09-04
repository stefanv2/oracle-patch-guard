#!/usr/bin/env bash
set -euo pipefail

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
    VISUDO_BIN=${OPG_BOOTSTRAP_TEST_VISUDO:-$TEST_ROOT/usr/sbin/visudo}
    PRIVILEGED_GROUP=root
    STAGE_GROUP=root
    CONFIG_GROUP=root
else
    BASE=/mnt/datadomain/software/patches/Linux/oracle-patch-guard/current
    DST_CONTEXT=/usr/local/sbin/opg_context_root.sh
    DST_MEDIA_SH=/usr/local/sbin/opg_media_stage_root.sh
    DST_MEDIA_PY=/usr/local/libexec/opg_media_stage_root.py
    STAGE_ANCHOR=/u01/stage
    STAGE_ROOT=/u01/stage/oracle-patch-guard
    SUDOERS_DST=/etc/sudoers.d/oracle-patch-guard-context
    CONFIG_DST=/etc/oracle-patch-guard/patchGD_guard.conf
    CONTEXT_ROOT=/var/lib/oracle-patch-guard
    VISUDO_BIN=/usr/sbin/visudo
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
SUDOERS_TEMP=
CONFIG_TEMP=

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

cleanup() {
    if [[ -n ${SUDOERS_TEMP:-} && -f $SUDOERS_TEMP && ! -L $SUDOERS_TEMP ]]; then
        rm -f -- "$SUDOERS_TEMP"
    fi
    if [[ -n ${CONFIG_TEMP:-} && -f $CONFIG_TEMP && ! -L $CONFIG_TEMP ]]; then
        rm -f -- "$CONFIG_TEMP"
    fi
}
trap cleanup EXIT

validate_config_candidate() {
    local candidate=$1 raw key value required_key
    declare -A seen=()
    declare -A required=(
        [PATCH_ROOT]=1
        [OPATCH_ROOT]=1
        [RUN_ROOT]=1
        [LOCK_ROOT]=1
        [OPG_ROOT]=1
        [APPROVAL_ROOT]=1
    )

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
        [[ -z ${seen[$key]+x} ]] || fail "dubbele configsleutel: $key"
        seen[$key]=1
        if [[ -n ${required[$key]+x} ]]; then
            [[ -n "$value" ]] || fail "lege verplichte configwaarde: $key"
            [[ "$value" == /* && "$value" =~ ^/[A-Za-z0-9_./-]+$ && "$value" != *'//'*
               && "$value" != */../* && "$value" != */./* && "$value" != */.. && "$value" != */. ]] \
                || fail "ongeldig absoluut pad voor $key"
        fi
    done <"$candidate"

    for required_key in PATCH_ROOT OPATCH_ROOT RUN_ROOT LOCK_ROOT OPG_ROOT APPROVAL_ROOT; do
        [[ -n ${seen[$required_key]+x} ]] \
            || fail "verplichte configsleutel ontbreekt: $required_key"
    done
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || fail "bootstrap moet als root draaien"

log "START|host=$(hostname -f 2>/dev/null || hostname)"

# ---------------------------------------------------------------------------
# Validate source files
# ---------------------------------------------------------------------------

for src in "$SRC_CONTEXT" "$SRC_MEDIA_SH" "$SRC_MEDIA_PY" "$SRC_SUDOERS" "$SRC_CONFIG"; do
    [[ -f "$src" ]] || fail "bronbestand ontbreekt: $src"
    [[ ! -L "$src" ]] || fail "bronbestand is een symlink: $src"
done

config_source_mode=$(stat -c '%a' "$SRC_CONFIG") \
    || fail "stat mislukt voor centrale config: $SRC_CONFIG"
[[ "$config_source_mode" =~ ^[0-7]{3,4}$ ]] \
    || fail "centrale config heeft ongeldige mode: $config_source_mode"
(( (8#$config_source_mode & 0022) == 0 )) \
    || fail "centrale config is group/world-writable: $SRC_CONFIG"
validate_config_candidate "$SRC_CONFIG"

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
        install -o root -g "$PRIVILEGED_GROUP" -m 0755 "$src" "$dst"
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
    local dir_identity target_identity

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

    if [[ -e "$CONFIG_DST" || -L "$CONFIG_DST" ]]; then
        [[ -f "$CONFIG_DST" && ! -L "$CONFIG_DST" ]] \
            || fail "bestaande lokale config is geen veilig regulier bestand"
    fi

    CONFIG_TEMP=$(mktemp "${CONFIG_DIR}/.patchGD_guard.conf.tmp.XXXXXX") \
        || fail "tijdelijke configcandidate kon niet worden gemaakt"
    install -o root -g "$CONFIG_GROUP" -m 0640 "$SRC_CONFIG" "$CONFIG_TEMP" \
        || fail "configcandidate kon niet veilig worden gestaged"
    cmp -s "$SRC_CONFIG" "$CONFIG_TEMP" \
        || fail "configcandidate wijkt af van centrale bron"
    validate_config_candidate "$CONFIG_TEMP"

    if [[ -f "$CONFIG_DST" ]] && cmp -s "$CONFIG_TEMP" "$CONFIG_DST"; then
        target_identity=$(stat -c '%U:%G:%a' "$CONFIG_DST") \
            || fail "stat mislukt voor bestaande lokale config"
        if [[ "$target_identity" == "root:${CONFIG_GROUP}:640" ]]; then
            rm -f -- "$CONFIG_TEMP"
            CONFIG_TEMP=
            log "UNCHANGED|$CONFIG_DST"
            return 0
        fi
    fi

    mv -f -- "$CONFIG_TEMP" "$CONFIG_DST" \
        || fail "runtimeconfig kon niet atomisch worden geactiveerd"
    CONFIG_TEMP=
    target_identity=$(stat -c '%U:%G:%a' "$CONFIG_DST") \
        || fail "stat mislukt voor geïnstalleerde runtimeconfig"
    [[ "$target_identity" == "root:${CONFIG_GROUP}:640" ]] \
        || fail "onjuiste owner/mode voor runtimeconfig: $target_identity"
    log "INSTALLED|$CONFIG_DST"
}

install_runtime_config

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

for managed_dir in "$STAGE_ROOT/.locks" "$STAGE_ROOT/purging"; do
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
