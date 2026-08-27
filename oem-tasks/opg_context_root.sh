#!/usr/bin/env bash
# Root-only, fixed-scope filesystem helper for the OEM run context.
set -Eeuo pipefail
umask 077
IFS=$'\n\t'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP
cd / || exit 30

readonly EXIT_BLOCKED=20 EXIT_UNKNOWN=30 EXIT_USAGE=70
ACTION=${1:-}
INCOMING_FILE=

die() {
  local code=$1 message=$2
  printf 'OPG CONTEXT HELPER: %s\n' "$message" >&2
  exit "$code"
}

cleanup() {
  if [[ -n ${INCOMING_FILE:-} && -f $INCOMING_FILE ]]; then rm -f -- "$INCOMING_FILE"; fi
  return 0
}
trap cleanup EXIT

if [[ ${OPG_CONTEXT_HELPER_TEST_MODE:-0} == 1 ]]; then
  CONTEXT_ROOT=${OPG_CONTEXT_HELPER_TEST_ROOT:-}
  RUN_ROOT=${OPG_CONTEXT_HELPER_TEST_RUN_ROOT:-}
  APPROVAL_ROOT=${OPG_CONTEXT_HELPER_TEST_APPROVAL_ROOT:-${CONTEXT_ROOT}/approvals}
  CONTEXT_GROUP=${OPG_CONTEXT_HELPER_TEST_GROUP:-$(id -gn)}
  CONTEXT_OWNER=$(id -un)
  case "$CONTEXT_ROOT" in /tmp/opg-context-helper-tests.*|/tmp/opg-oem-wrapper-tests.*|/tmp/opg-oem14-tests.*) ;; *) die "$EXIT_USAGE" 'Ongeldige context-helper-testroot.' ;; esac
  case "$RUN_ROOT" in /tmp/opg-context-helper-tests.*|/tmp/opg-oem-wrapper-tests.*|/tmp/opg-oem14-tests.*) ;; *) die "$EXIT_USAGE" 'Ongeldige run-helper-testroot.' ;; esac
  case "$APPROVAL_ROOT" in /tmp/opg-context-helper-tests.*|/tmp/opg-oem-wrapper-tests.*|/tmp/opg-oem14-tests.*) ;; *) die "$EXIT_USAGE" 'Ongeldige approval-helper-testroot.' ;; esac
else
  (( EUID == 0 )) || die "$EXIT_USAGE" 'Deze helper moet via de begrensde root-sudo-regel worden uitgevoerd.'
  CONTEXT_ROOT=/var/lib/oracle-patch-guard
  RUN_ROOT=/var/log/oracle-patch-guard
  APPROVAL_ROOT=/mnt/patch-share/oracle-patch-guard/approvals
  CONTEXT_GROUP=oinstall
  CONTEXT_OWNER=root
fi

CONTEXT_FILE=${CONTEXT_ROOT}/current_run.json
ARCHIVE_DIR=${CONTEXT_ROOT}/archive
HISTORY_FILE=${CONTEXT_ROOT}/context_history.log
LOCK_FILE=${CONTEXT_ROOT}/.context.lock

[[ "$CONTEXT_GROUP" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "$EXIT_USAGE" 'Ongeldige contextgroup.'
getent group "$CONTEXT_GROUP" >/dev/null 2>&1 || die "$EXIT_UNKNOWN" "Contextgroup bestaat niet: ${CONTEXT_GROUP}"

ensure_context_root() {
  if [[ -e "$CONTEXT_ROOT" ]]; then
    [[ -d "$CONTEXT_ROOT" && ! -L "$CONTEXT_ROOT" ]] || die "$EXIT_BLOCKED" 'Contextroot is geen veilige directory.'
  else
    install -d -o "$CONTEXT_OWNER" -g "$CONTEXT_GROUP" -m 0750 -- "$CONTEXT_ROOT" || die "$EXIT_UNKNOWN" 'Contextroot kon niet worden gemaakt.'
  fi
  chown "${CONTEXT_OWNER}:${CONTEXT_GROUP}" "$CONTEXT_ROOT" || die "$EXIT_UNKNOWN" 'Contextroot ownership kon niet worden afgedwongen.'
  chmod 0750 "$CONTEXT_ROOT" || die "$EXIT_UNKNOWN" 'Contextroot mode kon niet worden afgedwongen.'
  [[ "$(stat -c '%U:%G:%a' "$CONTEXT_ROOT")" == "${CONTEXT_OWNER}:${CONTEXT_GROUP}:750" ]] || die "$EXIT_UNKNOWN" 'Contextroot postcondition faalt.'
}

lock_context() {
  exec 9>"$LOCK_FILE" || die "$EXIT_UNKNOWN" 'Contextlock kon niet worden geopend.'
  if ! chown "${CONTEXT_OWNER}:${CONTEXT_GROUP}" "$LOCK_FILE" || ! chmod 0640 "$LOCK_FILE"; then
    die "$EXIT_UNKNOWN" 'Contextlock permissions faalden.'
  fi
  flock -n 9 || die "$EXIT_BLOCKED" 'Een andere contextoperatie is actief.'
}

receive_context() {
  INCOMING_FILE=$(mktemp "${CONTEXT_ROOT}/.incoming.XXXXXX") || die "$EXIT_UNKNOWN" 'Incoming context kon niet worden gemaakt.'
  if ! /usr/bin/python3 - "$INCOMING_FILE" 3<&0 <<'PY'
import json, os, re, sys

target = sys.argv[1]
raw = os.fdopen(3, "rb", closefd=False).read(16385)
if not raw or len(raw) > 16384:
    raise SystemExit(1)
try:
    text = raw.decode("utf-8")
    data = json.loads(text)
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)

required = {
    "schema_version", "run_id", "short_hostname", "fqdn", "oracle_sid",
    "oracle_home", "patch_cycle", "db_ru_patch_id", "ojvm_patch_id",
    "opatch_version", "opatch_zip", "config_path", "window_id", "created_at",
}
if set(data) != required or any(not isinstance(data[k], str) or not data[k] for k in required):
    raise SystemExit(1)
patterns = {
    "schema_version": r"1",
    "run_id": r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}",
    "short_hostname": r"[A-Za-z0-9][A-Za-z0-9.-]{0,62}",
    "fqdn": r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}",
    "oracle_sid": r"[A-Za-z0-9_#$]+",
    "patch_cycle": r"[A-Z][A-Z0-9_-]{2,31}",
    "db_ru_patch_id": r"[0-9]{6,10}",
    "ojvm_patch_id": r"[0-9]{6,10}",
    "opatch_version": r"[0-9]+(?:[.][0-9]+){3,5}",
    "opatch_zip": r"[A-Za-z0-9][A-Za-z0-9._-]*[.]zip",
    "window_id": r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}",
    "created_at": r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
}
if any(re.fullmatch(pattern, data[key]) is None for key, pattern in patterns.items()):
    raise SystemExit(1)
for key in ("oracle_home", "config_path"):
    if re.fullmatch(r"/[A-Za-z0-9_./-]+", data[key]) is None or ".." in data[key].split("/"):
        raise SystemExit(1)
with open(target, "wb") as handle:
    handle.write(raw)
PY
  then
    die "$EXIT_BLOCKED" 'Aangeboden context-JSON is ongeldig.'
  fi
  if ! chown "${CONTEXT_OWNER}:${CONTEXT_GROUP}" "$INCOMING_FILE" || ! chmod 0640 "$INCOMING_FILE"; then
    die "$EXIT_UNKNOWN" 'Incoming contextpermissions faalden.'
  fi
}

json_value() {
  local file=$1 key=$2
  /usr/bin/python3 - "$file" "$key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get(sys.argv[2])
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

validate_existing_context() {
  [[ -f "$CONTEXT_FILE" && ! -L "$CONTEXT_FILE" ]] || die "$EXIT_BLOCKED" 'Bestaande current_run.json ontbreekt of is onveilig.'
  [[ "$(stat -c '%U:%G:%a' "$CONTEXT_FILE")" == "${CONTEXT_OWNER}:${CONTEXT_GROUP}:640" ]] || die "$EXIT_BLOCKED" 'Bestaande contextpermissions wijken af.'
}

publish_context() {
  ensure_context_root
  lock_context
  [[ ! -e "$CONTEXT_FILE" ]] || die "$EXIT_BLOCKED" 'Actieve context bestaat al; publish overschrijft niet.'
  receive_context
  local new_run
  new_run=$(json_value "$INCOMING_FILE" run_id) || die "$EXIT_BLOCKED" 'Nieuwe RUN_ID is niet leesbaar.'
  [[ ! -e "${RUN_ROOT}/${new_run}" ]] || die "$EXIT_BLOCKED" 'Nieuwe RUN_ID bestaat al in RUN_ROOT.'
  mv -T -- "$INCOMING_FILE" "$CONTEXT_FILE" || die "$EXIT_UNKNOWN" 'Context kon niet atomisch worden gepubliceerd.'
  INCOMING_FILE=
}

rotate_context() {
  local reason=$1 old_run new_run state_file state stamp destination
  [[ -n "$reason" && ${#reason} -le 160 && "$reason" =~ ^[A-Za-z0-9][A-Za-z0-9_.:,/@+-]*(\ [A-Za-z0-9_.:,/@+-]+)*$ ]] || die "$EXIT_USAGE" 'Ongeldige new-run reden.'
  ensure_context_root
  lock_context
  validate_existing_context
  receive_context
  old_run=$(json_value "$CONTEXT_FILE" run_id) || die "$EXIT_BLOCKED" 'Oude RUN_ID ontbreekt.'
  new_run=$(json_value "$INCOMING_FILE" run_id) || die "$EXIT_BLOCKED" 'Nieuwe RUN_ID ontbreekt.'
  [[ "$new_run" != "$old_run" && ! -e "${RUN_ROOT}/${new_run}" ]] || die "$EXIT_BLOCKED" 'Nieuwe RUN_ID is niet uniek.'
  state_file=${RUN_ROOT}/${old_run}/execution_state.json
  [[ -f "$state_file" && -r "$state_file" && ! -L "$state_file" ]] || die "$EXIT_BLOCKED" 'Terminale oude run-state is niet veilig leesbaar.'
  state=$(json_value "$state_file" state) || die "$EXIT_BLOCKED" 'Oude run-state ontbreekt.'
  case "$state" in 12_COMPLETE|BLOCKED|UNKNOWN|MANUAL_INTERVENTION_REQUIRED) ;; *) die "$EXIT_BLOCKED" "Niet-terminale state kan niet worden geroteerd: ${state}" ;; esac
  if [[ -e "$ARCHIVE_DIR" ]]; then [[ -d "$ARCHIVE_DIR" && ! -L "$ARCHIVE_DIR" ]] || die "$EXIT_BLOCKED" 'Contextarchief is onveilig.'
  else install -d -o "$CONTEXT_OWNER" -g "$CONTEXT_GROUP" -m 0750 -- "$ARCHIVE_DIR" || die "$EXIT_UNKNOWN" 'Contextarchief kon niet worden gemaakt.'; fi
  if ! chown "${CONTEXT_OWNER}:${CONTEXT_GROUP}" "$ARCHIVE_DIR" || ! chmod 0750 "$ARCHIVE_DIR"; then
    die "$EXIT_UNKNOWN" 'Contextarchiefpermissions faalden.'
  fi
  stamp=$(date -u '+%Y%m%dT%H%M%SZ'); destination=${ARCHIVE_DIR}/${old_run}.${stamp}.$$.json
  [[ ! -e "$destination" ]] || die "$EXIT_BLOCKED" 'Contextarchiefdoel bestaat al.'
  ln -- "$CONTEXT_FILE" "$destination" || die "$EXIT_UNKNOWN" 'Oude context kon niet atomisch worden veiliggesteld.'
  mv -T -- "$INCOMING_FILE" "$CONTEXT_FILE" || die "$EXIT_UNKNOWN" 'Nieuwe context kon niet atomisch worden geplaatst.'
  INCOMING_FILE=
  printf '%s|run_id=%s|state=%s|reason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$old_run" "$state" "$reason" >>"$HISTORY_FILE"
  if ! chown "${CONTEXT_OWNER}:${CONTEXT_GROUP}" "$HISTORY_FILE" || ! chmod 0640 "$HISTORY_FILE"; then
    die "$EXIT_UNKNOWN" 'Contexthistory permissions faalden.'
  fi
}

publish_approval_stage() {
  local run_id=$1 rc
  [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || die "$EXIT_USAGE" 'Ongeldige approval RUN_ID.'
  set +e
  /usr/bin/python3 - "$APPROVAL_ROOT" "$run_id" "$CONTEXT_OWNER" "$CONTEXT_GROUP" 3<&0 <<'PY'
import grp
import io
import os
import pwd
import secrets
import stat
import sys
import tarfile

approval_root, run_id, owner_name, group_name = sys.argv[1:]
allowed = {
    "patch_manifest.json",
    "assessment.json",
    "findings.psv",
    "execution_state.json",
}
max_file_size = 16 * 1024 * 1024
root_fd = temp_fd = None
temp_name = None

def blocked(message):
    print(f"OPG CONTEXT HELPER: {message}", file=sys.stderr)
    raise SystemExit(20)

def unknown(message):
    print(f"OPG CONTEXT HELPER: {message}", file=sys.stderr)
    raise SystemExit(30)

try:
    owner_uid = pwd.getpwnam(owner_name).pw_uid
    group_gid = grp.getgrnam(group_name).gr_gid
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    root_fd = os.open(approval_root, flags)
    root_stat = os.fstat(root_fd)
    if root_stat.st_uid != owner_uid or root_stat.st_gid != group_gid or stat.S_IMODE(root_stat.st_mode) != 0o750:
        blocked("Approvalroot moet exact root/group 0750 zijn.")
    try:
        os.stat(run_id, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        blocked("Definitieve approvaldirectory bestaat al.")

    temp_name = f".{run_id}.staging.{os.getpid()}.{secrets.token_hex(6)}"
    os.mkdir(temp_name, 0o700, dir_fd=root_fd)
    temp_fd = os.open(temp_name, flags, dir_fd=root_fd)
    seen = set()
    stream = os.fdopen(3, "rb", closefd=False)
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            name = member.name
            if name not in allowed or name in seen or not member.isfile():
                blocked("Approvalstream bevat een onbekend, dubbel of niet-regulier item.")
            if member.size < 0 or member.size > max_file_size:
                blocked("Approvalstream bevat een te groot artifact.")
            source = archive.extractfile(member)
            if source is None:
                blocked("Approvalartifact kon niet uit de stream worden gelezen.")
            file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                file_flags |= os.O_NOFOLLOW
            file_fd = os.open(name, file_flags, 0o440, dir_fd=temp_fd)
            try:
                remaining = member.size
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        blocked("Approvalartifact is korter dan gedeclareerd.")
                    view = memoryview(chunk)
                    while view:
                        written = os.write(file_fd, view)
                        view = view[written:]
                    remaining -= len(chunk)
                os.fchown(file_fd, owner_uid, group_gid)
                os.fchmod(file_fd, 0o440)
                os.fsync(file_fd)
            finally:
                os.close(file_fd)
            seen.add(name)
    if seen != allowed:
        blocked("Approvalstream bevat niet exact de vier vereiste artifacts.")
    os.fchown(temp_fd, owner_uid, group_gid)
    os.fchmod(temp_fd, 0o750)
    os.fsync(temp_fd)
    os.rename(temp_name, run_id, src_dir_fd=root_fd, dst_dir_fd=root_fd)
    temp_name = None
    os.fsync(root_fd)
except SystemExit:
    raise
except (KeyError, OSError, tarfile.TarError) as exc:
    unknown(f"Approvalpublicatie faalde: {exc}")
finally:
    if temp_fd is not None:
        os.close(temp_fd)
    if temp_name is not None and root_fd is not None:
        try:
            cleanup_fd = os.open(temp_name, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0), dir_fd=root_fd)
            try:
                for name in allowed:
                    try:
                        os.unlink(name, dir_fd=cleanup_fd)
                    except FileNotFoundError:
                        pass
            finally:
                os.close(cleanup_fd)
            os.rmdir(temp_name, dir_fd=root_fd)
        except OSError:
            pass
    if root_fd is not None:
        os.close(root_fd)
PY
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    "$EXIT_BLOCKED") die "$EXIT_BLOCKED" 'Approvalstage werd veilig geweigerd.' ;;
    *) die "$EXIT_UNKNOWN" 'Approvalstage kon niet betrouwbaar worden gepubliceerd.' ;;
  esac
}

case "$ACTION" in
  prepare-root) [[ $# -eq 1 ]] || die "$EXIT_USAGE" 'prepare-root accepteert geen argumenten.'; ensure_context_root ;;
  publish) [[ $# -eq 1 ]] || die "$EXIT_USAGE" 'publish accepteert geen argumenten of paden.'; publish_context ;;
  rotate) [[ $# -eq 2 ]] || die "$EXIT_USAGE" 'rotate accepteert uitsluitend één reden.'; rotate_context "$2" ;;
  publish-approval-stage) [[ $# -eq 2 ]] || die "$EXIT_USAGE" 'publish-approval-stage accepteert uitsluitend één RUN_ID.'; publish_approval_stage "$2" ;;
  *) die "$EXIT_USAGE" 'Toegestane acties: prepare-root, publish, rotate, publish-approval-stage.' ;;
esac
