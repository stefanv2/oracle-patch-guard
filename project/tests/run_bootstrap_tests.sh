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
cp -a "$ROOT/oem-tasks/." "$FIXTURE_ROOT/oem-tasks/"
cp -a "$ROOT/project" "$FIXTURE_ROOT/project"
cp "$ROOT/config/examples/oracle-patch-guard-context.sudoers" "$SUDOERS_SOURCE"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$BASE/private.pem" >/dev/null 2>&1
openssl pkey -in "$BASE/private.pem" -pubout -out "$CENTRAL_OPG_ROOT/config/approval_public.pem" >/dev/null 2>&1
printf 'Site-approved Oracle Home recovery procedure\n' >"$CENTRAL_OPG_ROOT/config/oracle_home_rebuild.md"

write_valid_config() {
  cat >"$CONFIG_SOURCE" <<EOF
PATCH_ROOT=$BASE/central/patches
OPATCH_ROOT=$BASE/central/patches/opatch
RUN_ROOT=$BASE/var/log/oracle-patch-guard
LOCK_ROOT=$BASE/var/lock/oracle-patch-guard
OPG_ROOT=$CENTRAL_OPG_ROOT
APPROVAL_ROOT=$CENTRAL_OPG_ROOT/approvals
LOCAL_MEDIA_MODE=required
LOCAL_STAGE_ROOT=$BASE/u01/stage/oracle-patch-guard
MEDIA_STAGE_HELPER=$BASE/usr/local/sbin/opg_media_stage_root.sh
APPROVAL_PUBLIC_KEY=$BASE/etc/oracle-patch-guard/approval_public.pem
HOME_RECOVERY_PROCEDURE=$BASE/etc/oracle-patch-guard/oracle_home_rebuild.md
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
exec /usr/sbin/visudo "$@"
EOF
chmod 0755 "$VISUDO"

run_bootstrap() {
  OPG_BOOTSTRAP_TEST_MODE=1 OPG_BOOTSTRAP_TEST_ROOT=$BASE \
  OPG_BOOTSTRAP_TEST_VISUDO=$VISUDO OPG_VISUDO_LOG=$VISUDO_LOG \
    bash "$BOOTSTRAP" >"$OUT" 2>&1
}

run_bootstrap; rc=$?
if (( rc != 0 )); then cat "$OUT"; exit 1; fi
[[ -f "$SUDOERS_TARGET" && ! -L "$SUDOERS_TARGET" ]] || rc=99
cmp -s "$SUDOERS_SOURCE" "$SUDOERS_TARGET" || rc=98
grep -q "OPG_BOOTSTRAP|INSTALLED|$SUDOERS_TARGET" "$OUT" || rc=97
grep -q '/usr/local/sbin/opg_context_root.sh publish-completion [*]' "$SUDOERS_TARGET" || rc=96
grep -q '/usr/local/sbin/opg_media_stage_root.sh purge-run [*]' "$SUDOERS_TARGET" || rc=95
record 'eerste bootstrap installeert meegeleverde sudoers inclusief publish-completion' 0 "$rc"

fresh_rc=0
for installed in "$BASE/usr/local/sbin/opg_context_root.sh" "$BASE/usr/local/sbin/opg_media_stage_root.sh" "$BASE/usr/local/libexec/opg_media_stage_root.py"; do
  [[ -f "$installed" && ! -L "$installed" && $(stat -c '%U:%G:%a' "$installed") == root:root:755 ]] || fresh_rc=99
done
[[ -d "$BASE/u01/stage" && $(stat -c '%U:%G:%a' "$BASE/u01/stage") == root:root:755 ]] || fresh_rc=98
[[ -d "$BASE/u01/stage/oracle-patch-guard" && $(stat -c '%U:%G:%a' "$BASE/u01/stage/oracle-patch-guard") == root:root:750 ]] || fresh_rc=97
record 'fresh host krijgt alle lokale helpers en stage-anchors zonder handmatige stap' 0 "$fresh_rc"

log_root="$BASE/var/log/oracle-patch-guard"
log_root_rc=0
[[ -d "$log_root" && ! -L "$log_root" && $(stat -c '%U:%G:%a' "$log_root") == root:root:750 ]] || log_root_rc=99
grep -Fq "OPG_BOOTSTRAP|CREATED|$log_root" "$OUT" || log_root_rc=98
grep -Fq "OPG_BOOTSTRAP|LOG_ROOT_OK|$log_root|owner=root|group=root|mode=750" "$OUT" || log_root_rc=97
record 'test-mode bootstrap maakt ontbrekende LOG_ROOT root:root 0750 aan' 0 "$log_root_rc"

lock_rc=0
[[ -d "$BASE/u01/stage/oracle-patch-guard/.locks" && $(stat -c '%U:%G:%a' "$BASE/u01/stage/oracle-patch-guard/.locks") == root:root:750 ]] || lock_rc=99
[[ -f "$BASE/u01/stage/oracle-patch-guard/.locks/media-stage.lock" && ! -L "$BASE/u01/stage/oracle-patch-guard/.locks/media-stage.lock" && $(stat -c '%U:%G:%a:%h' "$BASE/u01/stage/oracle-patch-guard/.locks/media-stage.lock") == root:root:640:1 ]] || lock_rc=98
record 'bootstrap installeert de gedeelde veilige media-lock' 0 "$lock_rc"

cleanup_evidence_rc=0
[[ -d "$BASE/var/lib/oracle-patch-guard/stage-cleanup" && ! -L "$BASE/var/lib/oracle-patch-guard/stage-cleanup" && $(stat -c '%U:%G:%a' "$BASE/var/lib/oracle-patch-guard/stage-cleanup") == root:root:750 ]] || cleanup_evidence_rc=99
record 'bootstrap maakt autoritatieve cleanup-evidenceroot veilig aan' 0 "$cleanup_evidence_rc"

config_rc=0
[[ -f "$CONFIG_TARGET" && ! -L "$CONFIG_TARGET" ]] || config_rc=99
cmp -s "$CONFIG_SOURCE" "$CONFIG_TARGET" || config_rc=98
grep -q "OPG_BOOTSTRAP|INSTALLED|$CONFIG_TARGET" "$OUT" || config_rc=97
record 'eerste bootstrap installeert centrale runtimeconfig' 0 "$config_rc"
for name in approval_public.pem oracle_home_rebuild.md; do
  target=$BASE/etc/oracle-patch-guard/$name
  rc=0
  cmp -s "$CENTRAL_OPG_ROOT/config/$name" "$target" || rc=99
  [[ $(stat -c '%U:%G:%a' "$target") == root:root:640 && ! -L "$target" ]] || rc=98
  record "bootstrap installeert $name met veilige ownership/mode" 0 "$rc"
done
[[ $(stat -c '%U:%G:%a' "$BASE/var/lock/oracle-patch-guard") == root:root:2770 ]]
record 'bootstrap maakt de Oracle Home LOCK_ROOT zonder PREPARE' 0 $?
[[ ! -e "$BASE/var/lib/oracle-patch-guard/current_run.json" ]]
record 'bootstrap maakt geen lifecyclecontext' 0 $?
python3 "$ROOT/project/tests/run_bootstrap_readiness_tests.py" "$BASE" "$ROOT" >"$BASE/readiness.out" 2>&1
rc=$?; (( rc == 0 )) || cat "$BASE/readiness.out"
record 'bootstrap -> echte signed media-stage -> core PRECHECK zonder PREPARE' 0 "$rc"
OPG_PREPARE_TEST_ROOT=$BASE bash "$ROOT/oem-tasks/opg_prepare_host.sh" >"$OUT" 2>&1
record 'latere PREPARE valideert bootstrap zonder sudo install' 0 $?
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
grep -q '^    LOG_ROOT=/var/log/oracle-patch-guard$' "$BOOTSTRAP" && grep -q '^    RUN_USER=oracle$' "$BOOTSTRAP"
record 'productiecontract beheert LOG_ROOT voor oracle' 0 $?
mode_rc=0
printf '[safe]\n\tdirectory = %s\n' "$ROOT" >"$BASE/gitconfig"
[[ $(GIT_CONFIG_GLOBAL="$BASE/gitconfig" git -C "$ROOT" ls-files -s -- oem-tasks/opg_bootstrap_host.sh | awk '{print $1}') == 100755 ]] || mode_rc=99
[[ $(GIT_CONFIG_GLOBAL="$BASE/gitconfig" git -C "$ROOT" ls-files -s -- oem-tasks/opg_oem.sh | awk '{print $1}') == 100755 ]] || mode_rc=98
[[ $(GIT_CONFIG_GLOBAL="$BASE/gitconfig" git -C "$ROOT" ls-files -s -- project/patchGD_guard.sh | awk '{print $1}') == 100755 ]] || mode_rc=97
record 'release bewaart executable bits van bootstrap OEM-wrapper en patchguard' 0 "$mode_rc"

first_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
run_bootstrap; rc=$?
second_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$first_hash" == "$second_hash" ]] || rc=99
grep -q "OPG_BOOTSTRAP|UNCHANGED|$SUDOERS_TARGET" "$OUT" || rc=98
record 'tweede identieke bootstrap is idempotent' 0 "$rc"
grep -q "OPG_BOOTSTRAP|UNCHANGED|$CONFIG_TARGET" "$OUT"
record 'tweede identieke configinstallatie is UNCHANGED' 0 $?
for name in approval_public.pem oracle_home_rebuild.md; do
  grep -Fq "OPG_BOOTSTRAP|UNCHANGED|$BASE/etc/oracle-patch-guard/$name" "$OUT"
  record "tweede bootstrap behoudt $name" 0 $?
done
grep -Fq "OPG_BOOTSTRAP|LOG_ROOT_OK|$log_root|owner=root|group=root|mode=750" "$OUT"
record 'tweede bootstrap hergebruikt veilige LOG_ROOT idempotent' 0 $?

chmod 0755 "$log_root"; run_bootstrap; rc=$?; chmod 0750 "$log_root"
record 'bestaande LOG_ROOT met verkeerde mode faalt gesloten' 30 "$rc"
chown 65534:root "$log_root"; run_bootstrap; rc=$?; chown root:root "$log_root"
record 'bestaande LOG_ROOT met verkeerde owner faalt gesloten' 30 "$rc"
chown root:65534 "$log_root"; run_bootstrap; rc=$?; chown root:root "$log_root"
record 'bestaande LOG_ROOT met verkeerde group faalt gesloten' 30 "$rc"

printf '\n# gecontroleerde policy-update\n' >>"$SUDOERS_SOURCE"
changed_hash=$(sha256sum "$SUDOERS_SOURCE" | awk '{print $1}')
run_bootstrap; rc=$?
target_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$changed_hash" == "$target_hash" && "$target_hash" != "$second_hash" ]] || rc=99
grep -q "OPG_BOOTSTRAP|INSTALLED|$SUDOERS_TARGET" "$OUT" || rc=98
record 'gewijzigde geldige sudoers wordt vervangen' 0 "$rc"

valid_hash=$target_hash
installed_before=$(sha256sum "$BASE/usr/local/sbin/opg_context_root.sh" "$CONFIG_TARGET")
printf '\n# incoming helper update\n' >>"$FIXTURE_ROOT/oem-tasks/opg_context_root.sh"
printf '\n# incoming config update\n' >>"$CONFIG_SOURCE"
printf 'BROKEN_SUDOERS\n' >"$SUDOERS_SOURCE"
run_bootstrap; rc=$?
after_invalid_hash=$(sha256sum "$SUDOERS_TARGET" | awk '{print $1}')
[[ "$after_invalid_hash" == "$valid_hash" ]] || rc=99
grep -q 'faalt visudo-validatie' "$OUT" || rc=98
compgen -G "$BASE/etc/sudoers.d/.oracle-patch-guard-context.tmp.*" >/dev/null && rc=97
record 'corrupte sudoers wordt geweigerd en oude geldige file blijft behouden' 30 "$rc"
[[ $(sha256sum "$BASE/usr/local/sbin/opg_context_root.sh" "$CONFIG_TARGET") == "$installed_before" ]]
record 'ongeldige sudoers behoudt helper en config byte-identiek ondanks inkomende updates' 0 $?
cp "$ROOT/oem-tasks/opg_context_root.sh" "$FIXTURE_ROOT/oem-tasks/opg_context_root.sh"

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
[[ "$visudo_calls" -ge 5 ]] && awk '$1!="-cf" || $2 !~ /[.]tmp[.]/ {exit 1}' "$VISUDO_LOG"
record 'iedere kandidaat wordt vóór activatie met visudo -cf gevalideerd' 0 $?

for name in approval_public.pem oracle_home_rebuild.md; do
  write_valid_config
  mv "$CENTRAL_OPG_ROOT/config/$name" "$BASE/artifact.saved"
  run_bootstrap; rc=$?
  [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
  record "ontbrekend $name blokkeert met behoud van lokale config" 30 "$rc"
  mv "$BASE/artifact.saved" "$CENTRAL_OPG_ROOT/config/$name"
done
for key in LOCAL_MEDIA_MODE LOCAL_STAGE_ROOT MEDIA_STAGE_HELPER APPROVAL_PUBLIC_KEY HOME_RECOVERY_PROCEDURE; do
  write_valid_config; sed -i "/^$key=/d" "$CONFIG_SOURCE"
  run_bootstrap; rc=$?
  [[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
  record "semantisch ontbrekende $key behoudt lokale config" 30 "$rc"
done
write_valid_config
printf 'BACKUP_CHECK_COMMAND=%s/project/checks/check_rman_backup\nEXPECTED_BACKUP_HOST=\n' "$FIXTURE_ROOT" >>"$CONFIG_SOURCE"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ingeschakelde RMAN-hook zonder sitewaarden blokkeert vóór configvervanging' 30 "$rc"
write_valid_config
printf 'ORACLE_HOME_RECOVERY_CHECK_COMMAND=%s/project/checks/check_oracle_home_recovery\n' "$FIXTURE_ROOT" >>"$CONFIG_SOURCE"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ingeschakelde rebuild-hook zonder media/checksums behoudt config' 30 "$rc"
write_valid_config
printf 'BACKUP_CHECK_COMMAND=/missing/site/hook\n' >>"$CONFIG_SOURCE"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ontbrekende geconfigureerde hook behoudt config' 30 "$rc"
write_valid_config
sed -i 's/^PATCH_ROOT=/PATCH_ROOT = /' "$CONFIG_SOURCE"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'shell-invalid assignment behoudt lokale config' 30 "$rc"
write_valid_config
cp "$CENTRAL_OPG_ROOT/config/approval_public.pem" "$BASE/key.saved"
printf 'not a public key\n' >"$CENTRAL_OPG_ROOT/config/approval_public.pem"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'ongeldige public key behoudt bestaande config' 30 "$rc"
mv "$BASE/key.saved" "$CENTRAL_OPG_ROOT/config/approval_public.pem"
write_valid_config
cp "$CENTRAL_OPG_ROOT/config/oracle_home_rebuild.md" "$BASE/procedure.saved"
: >"$CENTRAL_OPG_ROOT/config/oracle_home_rebuild.md"
run_bootstrap; rc=$?
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=99
record 'lege herstelprocedure behoudt bestaande config' 30 "$rc"
mv "$BASE/procedure.saved" "$CENTRAL_OPG_ROOT/config/oracle_home_rebuild.md"
write_valid_config
missing_tool_bin=$BASE/missing-tool-bin
mkdir "$missing_tool_bin"
for cmd in bash python3 openssl sudo flock timeout sha256sum stat readlink realpath mktemp \
           install cmp mv rm chown chmod awk grep sed cut head tail tr sort find xargs \
           pgrep df du date hostname id getent unzip cp cat sync; do
  ln -s "$(command -v "$cmd")" "$missing_tool_bin/$cmd"
done
OPG_BOOTSTRAP_TEST_MODE=1 OPG_BOOTSTRAP_TEST_ROOT=$BASE PATH=$missing_tool_bin \
  "$missing_tool_bin/bash" "$BOOTSTRAP" >"$OUT" 2>&1
rc=$?
grep -Fq 'vereiste OS-tool ontbreekt: zipinfo' "$OUT" || rc=99
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=98
record 'ontbrekende OS-tool blokkeert duidelijk vóór configvervanging' 30 "$rc"
write_valid_config
printf 'ORACLE_HOME_RECOVERY_CHECK_COMMAND=%s/project/checks/check_oracle_home_recovery\nRECOVERY_BASE_IMAGE=%s/base-image.zip\nRECOVERY_BASE_IMAGE_SHA256=placeholder\nOPATCH_ZIP_SHA256=placeholder\n' "$FIXTURE_ROOT" "$BASE" >>"$CONFIG_SOURCE"
printf 'image fixture\n' >"$BASE/base-image.zip"
run_bootstrap; rc=$?
grep -Fq 'geldige checksum ontbreekt:' "$OUT" || rc=99
[[ $(sha256sum "$CONFIG_TARGET" | awk '{print $1}') == "$preserved_config_hash" ]] || rc=98
record 'placeholder recovery-checksums behouden bestaande config' 30 "$rc"
write_valid_config
printf 'BACKUP_CHECK_COMMAND=""\nDATAGUARD_CHECK_COMMAND=\n' >>"$CONFIG_SOURCE"
run_bootstrap
record 'bestaande host blijft bruikbaar met optionele hooks ongeconfigureerd' 0 $?
printf '\n# central config changed\n' >>"$CONFIG_SOURCE"
OPG_PREPARE_TEST_ROOT=$BASE bash "$ROOT/oem-tasks/opg_prepare_host.sh" >"$OUT" 2>&1; rc=$?
cmp -s "$CONFIG_SOURCE" "$CONFIG_TARGET" && rc=99
record 'PREPARE weigert centrale drift zonder lokale config te vervangen' 20 "$rc"

write_valid_config
printf 'MAINTENANCE_WINDOW_CHECK_COMMAND=%s/project/checks/check_maintenance_window\n' "$FIXTURE_ROOT" >>"$CONFIG_SOURCE"
run_bootstrap; rc=$?
grep -Fq 'MAINTENANCE_WINDOW_MANIFEST-pad ontbreekt' "$OUT" || rc=99
record 'standaard maintenance checker vereist manifestconfiguratie' 30 "$rc"
write_valid_config
printf '#!/bin/sh\nexit 0\n' >"$BASE/custom_window_check"
chmod 0755 "$BASE/custom_window_check"
printf 'MAINTENANCE_WINDOW_CHECK_COMMAND=%s/custom_window_check\n' "$BASE" >>"$CONFIG_SOURCE"
run_bootstrap
record 'custom maintenance hook zonder manifest blijft toegestaan' 0 $?
write_valid_config
run_bootstrap
record 'geen maintenance hook blijft optioneel' 0 $?

printf '\nBootstrap results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
