#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
BOOTSTRAP=$ROOT/oem-tasks/opg_bootstrap_host.sh
BASE=$(mktemp -d /tmp/opg-bootstrap-tests.XXXXXX) || exit 1
PASS=0 FAIL=0
trap 'rm -rf -- "$BASE"' EXIT

record() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1)); [[ -r ${OUT:-} ]] && tail -n 30 "$OUT"
  fi
}

if (( EUID != 0 )); then
  printf 'Bootstrap regressions vereisen root voor echte ownershipvalidatie.\n' >&2
  exit 70
fi

FIXTURE_ROOT=$BASE/base/current
CENTRAL_OPG_ROOT=${FIXTURE_ROOT%/current}
SUDOERS_SOURCE=$FIXTURE_ROOT/config/examples/oracle-patch-guard-context.sudoers
SUDOERS_TARGET=$BASE/etc/sudoers.d/oracle-patch-guard-context
CONFIG_SOURCE=$CENTRAL_OPG_ROOT/config/patchGD_guard.conf
CONFIG_TARGET=$BASE/etc/oracle-patch-guard/patchGD_guard.conf
VISUDO=$BASE/usr/sbin/visudo
VISUDO_LOG=$BASE/visudo.log
OUT=$BASE/out

mkdir -p "$FIXTURE_ROOT/oem-tasks" "$FIXTURE_ROOT/config/examples" "$CENTRAL_OPG_ROOT/config" \
  "$BASE/etc/sudoers.d" "$BASE/usr/sbin" "$BASE/u01"
chmod 0755 "$BASE/etc/sudoers.d" "$BASE/usr/sbin" "$BASE/u01"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE_ROOT/oem-tasks/opg_context_root.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE_ROOT/oem-tasks/opg_media_stage_root.sh"
printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$FIXTURE_ROOT/oem-tasks/opg_media_stage_root.py"
cp "$ROOT/config/examples/oracle-patch-guard-context.sudoers" "$SUDOERS_SOURCE"

write_valid_config() {
  cat >"$CONFIG_SOURCE" <<EOF
PATCH_ROOT=$BASE/central/patches
OPATCH_ROOT=$BASE/central/patches/opatch
RUN_ROOT=$BASE/var/log/oracle-patch-guard
LOCK_ROOT=$BASE/var/lock/oracle-patch-guard
OPG_ROOT=$BASE/base/current
APPROVAL_ROOT=$BASE/base/current/approvals
LOCAL_MEDIA_MODE=required
EOF
  chmod 0600 "$CONFIG_SOURCE"
}
write_valid_config

cat >"$VISUDO" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OPG_VISUDO_LOG"
[[ $# -eq 2 && $1 == -cf && -f $2 ]] || exit 2
grep -q 'BROKEN_SUDOERS' "$2" && exit 1
grep -q '/usr/local/sbin/opg_context_root.sh publish-completion [*]' "$2" || exit 1
exit 0
EOF
chmod 0755 "$VISUDO"

run_bootstrap() {
  OPG_BOOTSTRAP_TEST_MODE=1 OPG_BOOTSTRAP_TEST_ROOT=$BASE \
  OPG_BOOTSTRAP_TEST_VISUDO=$VISUDO OPG_VISUDO_LOG=$VISUDO_LOG \
    bash "$BOOTSTRAP" >"$OUT" 2>&1
}

run_bootstrap; rc=$?
[[ -f "$SUDOERS_TARGET" && ! -L "$SUDOERS_TARGET" ]] || rc=99
cmp -s "$SUDOERS_SOURCE" "$SUDOERS_TARGET" || rc=98
grep -q "OPG_BOOTSTRAP|INSTALLED|$SUDOERS_TARGET" "$OUT" || rc=97
grep -q '/usr/local/sbin/opg_context_root.sh publish-completion [*]' "$SUDOERS_TARGET" || rc=96
record 'eerste bootstrap installeert meegeleverde sudoers inclusief publish-completion' 0 "$rc"

fresh_rc=0
for installed in "$BASE/usr/local/sbin/opg_context_root.sh" "$BASE/usr/local/sbin/opg_media_stage_root.sh" "$BASE/usr/local/libexec/opg_media_stage_root.py"; do
  [[ -f "$installed" && ! -L "$installed" && $(stat -c '%U:%G:%a' "$installed") == root:root:755 ]] || fresh_rc=99
done
[[ -d "$BASE/u01/stage" && $(stat -c '%U:%G:%a' "$BASE/u01/stage") == root:root:755 ]] || fresh_rc=98
[[ -d "$BASE/u01/stage/oracle-patch-guard" && $(stat -c '%U:%G:%a' "$BASE/u01/stage/oracle-patch-guard") == root:root:750 ]] || fresh_rc=97
record 'fresh host krijgt alle lokale helpers en stage-anchors zonder handmatige stap' 0 "$fresh_rc"

config_rc=0
[[ -f "$CONFIG_TARGET" && ! -L "$CONFIG_TARGET" ]] || config_rc=99
cmp -s "$CONFIG_SOURCE" "$CONFIG_TARGET" || config_rc=98
grep -q "OPG_BOOTSTRAP|INSTALLED|$CONFIG_TARGET" "$OUT" || config_rc=97
record 'eerste bootstrap installeert centrale runtimeconfig' 0 "$config_rc"
[[ "$FIXTURE_ROOT" == */current && "$CONFIG_SOURCE" == "${FIXTURE_ROOT%/current}/config/patchGD_guard.conf" && ! -e "$FIXTURE_ROOT/config/patchGD_guard.conf" ]]
record 'BASE eindigt op current en runtimeconfig komt uitsluitend uit parent/config' 0 $?

identity=$(stat -c '%U:%G:%a' "$SUDOERS_TARGET" 2>/dev/null || true)
record 'sudoers-doel is root:root 0440' root:root:440 "$identity"
config_identity=$(stat -c '%U:%G:%a' "$CONFIG_TARGET" 2>/dev/null || true)
record 'runtimeconfig is root:root 0640 in geïsoleerde root-test' root:root:640 "$config_identity"
config_dir_identity=$(stat -c '%U:%G:%a' "${CONFIG_TARGET%/*}" 2>/dev/null || true)
record 'configdirectory is root:root 0755' root:root:755 "$config_dir_identity"
grep -q '^    CONFIG_GROUP=oinstall$' "$BOOTSTRAP" && grep -Fq "install -o root -g \"\$CONFIG_GROUP\" -m 0640" "$BOOTSTRAP"
record 'productiecontract installeert runtimeconfig root:oinstall 0640' 0 $?

first_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
run_bootstrap; rc=$?
second_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$first_hash" == "$second_hash" ]] || rc=99
grep -q "OPG_BOOTSTRAP|UNCHANGED|$SUDOERS_TARGET" "$OUT" || rc=98
record 'tweede identieke bootstrap is idempotent' 0 "$rc"
grep -q "OPG_BOOTSTRAP|UNCHANGED|$CONFIG_TARGET" "$OUT"
record 'tweede identieke configinstallatie is UNCHANGED' 0 $?

printf '\n# gecontroleerde policy-update\n' >>"$SUDOERS_SOURCE"
changed_hash=$(sha256sum "$SUDOERS_SOURCE" | awk '{print $1}')
run_bootstrap; rc=$?
target_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$changed_hash" == "$target_hash" && "$target_hash" != "$second_hash" ]] || rc=99
grep -q "OPG_BOOTSTRAP|INSTALLED|$SUDOERS_TARGET" "$OUT" || rc=98
record 'gewijzigde geldige sudoers wordt vervangen' 0 "$rc"

valid_hash=$target_hash
printf 'BROKEN_SUDOERS\n' >"$SUDOERS_SOURCE"
run_bootstrap; rc=$?
after_invalid_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$after_invalid_hash" == "$valid_hash" ]] || rc=99
grep -q 'faalt visudo-validatie' "$OUT" || rc=98
compgen -G "$BASE/etc/sudoers.d/.oracle-patch-guard-context.tmp.*" >/dev/null && rc=97
record 'corrupte sudoers wordt geweigerd en oude geldige file blijft behouden' 30 "$rc"

cp "$ROOT/config/examples/oracle-patch-guard-context.sudoers" "$SUDOERS_SOURCE"
valid_config_hash=$(sha256sum "$CONFIG_TARGET" | awk '{print $1}')
sed -i "s|^LOCK_ROOT=.*|LOCK_ROOT=$BASE/var/lock/oracle-patch-guard-v2|" "$CONFIG_SOURCE"
changed_config_hash=$(sha256sum "$CONFIG_SOURCE" | awk '{print $1}')
run_bootstrap; rc=$?
installed_config_hash=$(sha256sum "$CONFIG_TARGET" | awk '{print $1}')
[[ "$changed_config_hash" == "$installed_config_hash" && "$installed_config_hash" != "$valid_config_hash" ]] || rc=99
grep -q "OPG_BOOTSTRAP|INSTALLED|$CONFIG_TARGET" "$OUT" || rc=98
record 'gewijzigde geldige centrale config wordt vervangen' 0 "$rc"

preserved_config_hash=$installed_config_hash
write_valid_config; sed -i '/^LOCK_ROOT=/d' "$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ontbrekende verplichte configkey blokkeert met behoud van lokale config' 30 "$rc"

write_valid_config; printf 'PATCH_ROOT=/duplicate/path\n' >>"$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'duplicate configkey blokkeert met behoud van lokale config' 30 "$rc"

write_valid_config; sed -i 's|^OPG_ROOT=.*|OPG_ROOT=relative/oracle-patch-guard|' "$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'relatief verplicht configpad blokkeert' 30 "$rc"

write_valid_config; sed -i 's|^APPROVAL_ROOT=.*|APPROVAL_ROOT=/safe/root/../escape|' "$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'traversal in verplicht configpad blokkeert' 30 "$rc"

printf 'DIT IS GEEN KEY VALUE CONFIG\n' >"$CONFIG_SOURCE"; chmod 0600 "$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
compgen -G "$BASE/etc/oracle-patch-guard/.patchGD_guard.conf.tmp.*" >/dev/null && rc=98
record 'corrupte configcandidate laat bestaande lokale config intact' 30 "$rc"

rm -f -- "$CONFIG_SOURCE"
run_bootstrap; rc=$?; [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ontbrekende parent/config runtimeconfig faalt gesloten' 30 "$rc"

visudo_calls=$(wc -l <"$VISUDO_LOG")
[[ "$visudo_calls" -eq 5 ]] && awk '$1=="-cf" && $2 ~ /[.]tmp[.]/ {ok++} END{exit !(ok==5)}' "$VISUDO_LOG"
record 'iedere kandidaat wordt vóór activatie met visudo -cf gevalideerd' 0 $?

printf '\nBootstrap results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
