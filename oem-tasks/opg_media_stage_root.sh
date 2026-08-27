#!/usr/bin/env bash
# Fixed-path privilege-boundary launcher for the Pilot07 Python media engine.
set -u
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ ${OPG_MEDIA_TEST_MODE:-0} == 1 && $EUID -ne 0 ]]; then
  ENGINE=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/opg_media_stage_root.py
  EXPECTED_OWNER=$(id -un); EXPECTED_GROUP=$(id -gn); PARENT_STOP=${ENGINE%/*}
else
  ENGINE=/usr/local/libexec/opg_media_stage_root.py
  EXPECTED_OWNER=root; EXPECTED_GROUP=root; PARENT_STOP=/
fi

fail() { printf 'OPG_MEDIA_ERROR|exit_code=30|message=%s\n' "$1" >&2; exit 30; }
[[ -f "$ENGINE" && -x "$ENGINE" && ! -L "$ENGINE" ]] || fail 'media-engine ontbreekt, is niet executable/regulier of is een symlink'
identity=$(stat -c '%U:%G:%a' "$ENGINE" 2>/dev/null) || fail 'media-enginepermissions zijn onbekend'
[[ "$identity" == "${EXPECTED_OWNER}:${EXPECTED_GROUP}:755" ]] || fail "media-enginepermissions wijken af: ${identity}"
parent=${ENGINE%/*}
while :; do
  [[ -d "$parent" && ! -L "$parent" ]] || fail "media-engine-parent ontbreekt of is een symlink: ${parent}"
  parent_identity=$(stat -c '%U:%a' "$parent" 2>/dev/null) || fail "media-engine-parentpermissions zijn onbekend: ${parent}"
  owner=${parent_identity%%:*}; mode=${parent_identity##*:}
  [[ "$owner" == "$EXPECTED_OWNER" && "$mode" =~ ^[0-7]{3,4}$ ]] || fail "media-engine-parentowner/mode is ongeldig: ${parent_identity}|${parent}"
  (( (8#$mode & 0022) == 0 )) || fail "media-engine-parent is group/world-writable: ${parent_identity}|${parent}"
  [[ "$parent" == "$PARENT_STOP" ]] && break
  [[ "$parent" != / ]] || fail 'media-engine-parentgrens werd niet veilig bereikt'
  parent=${parent%/*}; [[ -n "$parent" ]] || parent=/
done

exec /usr/bin/python3 -I "$ENGINE" "$@"
