#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
SOURCE_HELPER=${ROOT}/oem-tasks/opg_media_stage_root.sh
SOURCE_HELPER_ENGINE=${ROOT}/oem-tasks/opg_media_stage_root.py
BUILDER=${ROOT}/oem-tasks/opg_build_artifact_manifest.py
BASE=/tmp/opg-media-stage-tests.$$
RUNTIME=${BASE}.runtime
mkdir -p "$RUNTIME"; cp "$SOURCE_HELPER" "$RUNTIME/opg_media_stage_root.sh"; cp "$SOURCE_HELPER_ENGINE" "$RUNTIME/opg_media_stage_root.py"; chmod 0755 "$RUNTIME" "$RUNTIME/opg_media_stage_root.sh" "$RUNTIME/opg_media_stage_root.py"
HELPER=$RUNTIME/opg_media_stage_root.sh
HELPER_ENGINE=$RUNTIME/opg_media_stage_root.py
PASS=0 FAIL=0
if [[ ${OPG_KEEP_TEST_TMP:-0} != 1 ]]; then trap 'rm -rf -- "$BASE".*' EXIT; else printf 'Pilot07 testtmp prefix: %s\n' "$BASE"; fi

record() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then printf 'ok - %s\n' "$name"; PASS=$((PASS+1)); else printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL+1)); fi
}

manifest_hash() { sha256sum "$CASE/central/JUL2026/artifact_manifest.json" | awk '{print $1}'; }
local_root() { printf '%s/u01/stage/oracle-patch-guard' "$CASE"; }

write_cycle_conf() {
  local db_sha ojvm_sha opatch_sha
  db_sha=$(sha256sum "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" | awk '{print $1}')
  ojvm_sha=$(sha256sum "$CASE/central/JUL2026/p39222882_190000_Linux-x86-64.zip" | awk '{print $1}')
  opatch_sha=$(sha256sum "$CASE/central/opatch/p6880880_190000_Linux-x86-64.zip" | awk '{print $1}')
  cat >"$CASE/central/JUL2026/opg_cycle.conf" <<EOF
PATCH_CYCLE=JUL2026
DB_RU_PATCH_ID=39472050
OJVM_PATCH_ID=39222882
OPATCH_VERSION=12.2.0.1.52
DB_RU_ZIP=p39472050_190000_Linux-x86-64.zip
DB_RU_ZIP_SHA256=$db_sha
OJVM_ZIP=p39222882_190000_Linux-x86-64.zip
OJVM_ZIP_SHA256=$ojvm_sha
OPATCH_ZIP=p6880880_190000_Linux-x86-64.zip
OPATCH_ZIP_SHA256=$opatch_sha
ARTIFACT_MANIFEST=artifact_manifest.json
ARTIFACT_MANIFEST_SIG=artifact_manifest.sig
EOF
}

sign_manifest() {
  rm -f -- "$CASE/central/JUL2026/artifact_manifest.json" "$CASE/central/JUL2026/artifact_manifest.sig"
  python3 "$BUILDER" --cycle JUL2026 --db-patch-id 39472050 --db-zip "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" \
    --ojvm-patch-id 39222882 --ojvm-zip "$CASE/central/JUL2026/p39222882_190000_Linux-x86-64.zip" \
    --opatch-version 12.2.0.1.52 --opatch-zip "$CASE/central/opatch/p6880880_190000_Linux-x86-64.zip" \
    --private-key "$CASE/private.pem" --output-dir "$CASE/central/JUL2026" >/dev/null
  write_cycle_conf
}

setup_case() {
  local name=$1 build
  CASE=${BASE}.${name}; build=$CASE/build
  mkdir -p "$build/39472050/etc/config" "$build/39222882/files" "$build/OPatch" "$CASE/central/JUL2026" "$CASE/central/opatch" "$CASE/central/oracle-patch-guard/config" "$(local_root)"
  chmod 0755 "$CASE/u01" "$CASE/u01/stage"
  chmod 0750 "$(local_root)"
  printf 'db payload\n' >"$build/39472050/etc/config/db.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$build/39472050/etc/config/run.sh"; chmod 0755 "$build/39472050/etc/config/run.sh"
  printf 'ojvm payload\n' >"$build/39222882/files/ojvm.txt"
  printf 'OPATCH_VERSION: 12.2.0.1.52\n' >"$build/OPatch/version.txt"
  python3 - "$build" "$CASE/central" <<'PY'
import pathlib,sys,zipfile
build=pathlib.Path(sys.argv[1]); central=pathlib.Path(sys.argv[2])
for top,target in (("39472050",central/"JUL2026/p39472050_190000_Linux-x86-64.zip"),("39222882",central/"JUL2026/p39222882_190000_Linux-x86-64.zip"),("OPatch",central/"opatch/p6880880_190000_Linux-x86-64.zip")):
    with zipfile.ZipFile(target,"w",zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((build/top).rglob("*")):
            archive.write(path,path.relative_to(build).as_posix())
PY
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CASE/private.pem" >/dev/null 2>&1
  openssl pkey -in "$CASE/private.pem" -pubout -out "$CASE/public.pem" >/dev/null 2>&1
  printf 'JUL2026\n' >"$CASE/central/oracle-patch-guard/config/active_cycle"
  sign_manifest
  export OPG_MEDIA_TEST_MODE=1 OPG_MEDIA_TEST_ROOT=$CASE
  unset OPG_MEDIA_TEST_FREE_BYTES OPG_MEDIA_TEST_FREE_INODES
}

stage() { "$HELPER" stage-active-cycle >"$CASE/stage.out" 2>"$CASE/stage.err"; }
verify() { "$HELPER" verify-active-stage JUL2026 >"$CASE/verify.out" 2>"$CASE/verify.err"; }
v2_hash() { python3 - "$HELPER" "$1" <<'PY'
import importlib.machinery,sys
m=importlib.machinery.SourceFileLoader('opg_vector',sys.argv[1].replace('.sh','.py')).load_module()
print(m.tree_hash_v2(m.Path(sys.argv[2])))
PY
}
add_default_oracle_write_acl() {
  python3 - "$1" <<'PY'
import os, struct, sys
undefined = 0xffffffff
entries = ((0x01, 0o7, undefined), (0x02, 0o7, 424242),
           (0x04, 0o5, undefined), (0x10, 0o7, undefined),
           (0x20, 0o5, undefined))
data = struct.pack('<I', 2) + b''.join(struct.pack('<HHI', *entry) for entry in entries)
os.setxattr(sys.argv[1], 'system.posix_acl_default', data, follow_symlinks=False)
PY
}

validate_local_with_fake_identity() {
  local field=$1 value=$2
  python3 - "$HELPER_ENGINE" "$CASE" "$field" "$value" <<'PY'
import importlib.machinery, os, sys
m = importlib.machinery.SourceFileLoader('opg_local_identity', sys.argv[1]).load_module()
local = m.Path(sys.argv[2]) / 'u01/stage/oracle-patch-guard'
field = {'owner': 4, 'group': 5}[sys.argv[3]]
value = int(sys.argv[4])
real_lstat = m.Path.lstat
def lstat_with_fake_identity(path):
    info = real_lstat(path)
    if path == local:
        values = list(info); values[field] = value
        return os.stat_result(values)
    return info
m.Path.lstat = lstat_with_fake_identity
m.validate_local_parents(local)
PY
}

setup_case valid; stage; record 'RU/OJVM met alleen patch-ID-directory publiceren READY' 0 $?; verify; record 'gepubliceerde stage verifieert READY' 0 $?
identity=$(manifest_hash); [[ $(cat "$(local_root)/ready/JUL2026/active_stage") == "$identity" ]]; record 'stage-identiteit is signed-manifest SHA256' 0 $?
stage_root="$(local_root)/ready/JUL2026/$identity"
[[ $(stat -c %a "$stage_root") == 750 && $(stat -c %a "$stage_root/stage_manifest.psv") == 440 && \
   $(find "$stage_root/media" "$stage_root/opatch" -type d -printf '%m\n' | sort -u) == 750 && \
   $(stat -c %a "$stage_root/media/JUL2026/39472050/etc/config/db.txt") == 640 && \
   $(stat -c %a "$stage_root/media/JUL2026/39472050/etc/config/run.sh") == 750 && \
   $(stat -c %a "$stage_root/opatch/p6880880_190000_Linux-x86-64.zip") == 640 ]]
record 'execution media gebruikt 0750 directories en 0640/0750 files' 0 $?
python3 - "$HELPER_ENGINE" "$CASE" <<'PY'
import importlib.machinery, os, pathlib, sys
m = importlib.machinery.SourceFileLoader('opg_execution_owner', sys.argv[1]).load_module()
root = pathlib.Path(sys.argv[2]) / 'ownership'; (root/'media/patch').mkdir(parents=True); (root/'opatch').mkdir()
(root/'stage_manifest.psv').write_text('metadata'); (root/'media/patch/data').write_text('data')
(root/'media/patch/run').write_text('run'); os.chmod(root/'media/patch/run', 0o700); (root/'opatch/file.zip').write_text('zip')
owners = {}; real_chown = m.os.chown
m.os.chown = lambda path, owner, gid: owners.__setitem__(str(path), owner)
try: m.secure_tree(root, os.getgid(), 424242)
finally: m.os.chown = real_chown
assert owners[str(root/'stage_manifest.psv')] == os.getuid()
assert owners[str(root/'media')] == owners[str(root/'media/patch/data')] == 424242
assert owners[str(root/'opatch')] == owners[str(root/'opatch/file.zip')] == 424242
assert (root/'media/patch/data').stat().st_mode & 0o777 == 0o640
assert (root/'media/patch/run').stat().st_mode & 0o777 == 0o750
PY
record 'execution ownership is oracle en metadataownership blijft root' 0 $?
baseline_db_hash=$(cut -d'|' -f9 "$CASE/verify.out")

setup_case patchsearch; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" "$CASE/central/JUL2026/p39222882_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
for path in sys.argv[1:]:
    with zipfile.ZipFile(path, 'a') as archive:
        archive.writestr('PatchSearch.xml', '<PatchSearch/>\n')
PY
sign_manifest; stage; record 'RU/OJVM patch-ID-directory plus PatchSearch.xml is toegestaan' 0 $?; verify; rc=$?
patchsearch_db_hash=$(cut -d'|' -f9 "$CASE/verify.out"); [[ $rc -eq 0 && "$patchsearch_db_hash" == "$baseline_db_hash" && ! -e "$(local_root)/ready/JUL2026/$(manifest_hash)/media/PatchSearch.xml" ]]
record 'PatchSearch.xml valt buiten de V2 patch-ID-tree' 0 $?

setup_case patchsearch_symlink; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import stat, sys, zipfile
entry=zipfile.ZipInfo('PatchSearch.xml'); entry.create_system=3; entry.external_attr=(stat.S_IFLNK|0o777)<<16
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr(entry, '/etc/passwd')
PY
sign_manifest; stage; record 'PatchSearch.xml als symlink wordt geblokkeerd' 20 $?
setup_case patchsearch_special; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import stat, sys, zipfile
entry=zipfile.ZipInfo('PatchSearch.xml'); entry.create_system=3; entry.external_attr=(stat.S_IFIFO|0o660)<<16
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr(entry, 'fifo')
PY
sign_manifest; stage; record 'PatchSearch.xml als speciaal object wordt geblokkeerd' 20 $?
setup_case rootxml; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr('foo.xml', 'x')
PY
sign_manifest; stage; record 'andere top-level XML-entry wordt geblokkeerd' 20 $?
setup_case patchsearch_case; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr('patchsearch.xml', 'x')
PY
sign_manifest; stage; record 'alternate spelling van PatchSearch.xml wordt geblokkeerd' 20 $?
setup_case extradir; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr('extra/payload', 'x')
PY
sign_manifest; stage; record 'extra top-level directory wordt geblokkeerd' 20 $?
setup_case absolutepath; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive: archive.writestr('/39472050/payload', 'x')
PY
sign_manifest; stage; record 'absoluut ZIP-pad wordt geblokkeerd' 20 $?
setup_case opatchextra; python3 - "$CASE/central/opatch/p6880880_190000_Linux-x86-64.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as archive: archive.writestr('PatchSearch.xml', 'x')
PY
sign_manifest; stage; record 'OPatch ZIP met extra rootbestand wordt geblokkeerd' 20 $?

setup_case u01owner; stage >/dev/null
python3 - "$HELPER_ENGINE" "$CASE" <<'PY'
import importlib.machinery, os, stat, sys
m = importlib.machinery.SourceFileLoader('opg_u01_owner', sys.argv[1]).load_module()
u01 = m.Path(sys.argv[2]) / 'u01'; real_lstat = m.Path.lstat
def lstat_with_oracle_owned_u01(path):
    info = real_lstat(path)
    if path == u01:
        values = list(info)
        values[0] = stat.S_IFDIR | 0o775
        values[4] = 424243
        values[5] = 424244
        return os.stat_result(values)
    return info
m.Path.lstat = lstat_with_oracle_owned_u01
m.validate_local_parents(u01 / 'stage/oracle-patch-guard')
PY
record '/u01 oracle:oinstall 0775 valt buiten de trusted stage-boundary' 0 $?
setup_case anchorowner; stage >/dev/null; export OPG_MEDIA_TEST_EXPECTED_OWNER_UID=424243; verify; record 'niet-root-owned trusted anchor wordt geblokkeerd' 20 $?; unset OPG_MEDIA_TEST_EXPECTED_OWNER_UID
setup_case anchormode; stage >/dev/null; chmod 0775 "$CASE/u01/stage"; verify; record 'group-writable trusted anchor wordt geblokkeerd' 20 $?
setup_case rootowner; stage >/dev/null; validate_local_with_fake_identity owner 424243; record 'verkeerde owner lokale stage-root wordt geblokkeerd' 20 $?
setup_case rootgroup; stage >/dev/null; validate_local_with_fake_identity group 424244; record 'verkeerde group lokale stage-root wordt geblokkeerd' 20 $?
setup_case rootmode; stage >/dev/null; chmod 0775 "$(local_root)"; verify; record 'verkeerde mode lokale stage-root wordt geblokkeerd' 20 $?
setup_case anchorsymlink; stage >/dev/null; mv "$CASE/u01/stage" "$CASE/u01/stage.real"; ln -s stage.real "$CASE/u01/stage"; verify; record 'symlink trusted anchor wordt geblokkeerd' 20 $?
setup_case rootsymlink; stage >/dev/null; mv "$(local_root)" "$CASE/u01/stage/root.real"; ln -s root.real "$(local_root)"; verify; record 'symlink lokale stage-root wordt geblokkeerd' 20 $?
setup_case anchoracl; stage >/dev/null; add_default_oracle_write_acl "$CASE/u01/stage"; verify; record 'oracle write-ACL op trusted anchor wordt geblokkeerd' 20 $?
setup_case rootacl; stage >/dev/null; add_default_oracle_write_acl "$(local_root)"; verify; record 'oracle write-ACL op lokale stage-root wordt geblokkeerd' 20 $?
setup_case rootcontrolled; stage >/dev/null; verify; record 'bestaande volledig root-controlled layout blijft toegestaan' 0 $?

setup_case roots; stage >/dev/null; identity=$(manifest_hash); cp -a "$(local_root)/ready/JUL2026/$identity/media/JUL2026/39472050" "$CASE/copy"
h1=$(python3 - "$HELPER_ENGINE" "$(local_root)/ready/JUL2026/$identity/media/JUL2026/39472050" <<'PY'
import importlib.machinery, sys
m=importlib.machinery.SourceFileLoader('opg_hash',sys.argv[1]).load_module()
print(m.tree_hash_v2(m.Path(sys.argv[2])))
PY
); h2=$(python3 - "$HELPER_ENGINE" "$CASE/copy" <<'PY'
import importlib.machinery, sys
m=importlib.machinery.SourceFileLoader('opg_hash2',sys.argv[1]).load_module()
print(m.tree_hash_v2(m.Path(sys.argv[2])))
PY
); [[ "$h1" == "$h2" ]]; record 'V2 is onafhankelijk van absolute root' 0 $?
mkdir "$CASE/vector-empty" "$CASE/vector-abc" "$CASE/vector-weird"; printf abc >"$CASE/vector-abc/a.txt"; printf x >"$CASE/vector-weird/a|b"; printf y >"$CASE/vector-weird/line
break"
[[ $(v2_hash "$CASE/vector-empty") == fc7148770e90462c53b00b50bf17c592601347ca8413c60df09caf6722e9d597 && $(v2_hash "$CASE/vector-abc") == 5d6926712e919b727b504ee586bd9280834355e7d804d115102c3f09641be616 && $(v2_hash "$CASE/vector-weird") == 0e3d6c0065671517043627886bff3b8f7b79962e85211c76e2e5d41c2b266c5b ]]; record 'V2 golden vectors zijn stabiel' 0 $?
before_hidden=$(v2_hash "$CASE/vector-empty"); printf hidden >"$CASE/vector-empty/.hidden"; [[ $(v2_hash "$CASE/vector-empty") != "$before_hidden" ]]; record 'V2 neemt hidden files mee' 0 $?
ln -s /etc/passwd "$CASE/vector-abc/link"; v2_hash "$CASE/vector-abc" >/dev/null 2>&1; record 'V2 weigert symlinks fail-closed' 20 $?
rm "$CASE/vector-abc/link"; ln "$CASE/vector-abc/a.txt" "$CASE/vector-abc/hard"; v2_hash "$CASE/vector-abc" >/dev/null 2>&1; record 'V2 weigert hardlinks fail-closed' 20 $?
rm "$CASE/vector-abc/hard"; mkfifo "$CASE/vector-abc/fifo"; v2_hash "$CASE/vector-abc" >/dev/null 2>&1; record 'V2 weigert speciale files fail-closed' 20 $?

setup_case mutate; stage >/dev/null; identity=$(manifest_hash); chmod u+w "$(local_root)/ready/JUL2026/$identity/media/JUL2026/39472050/etc/config/db.txt"; printf 'tamper\n' >>"$(local_root)/ready/JUL2026/$identity/media/JUL2026/39472050/etc/config/db.txt"; verify; record 'gewijzigde lokale stage wordt geblokkeerd' 20 $?
setup_case pointer; stage >/dev/null; chmod u+w "$(local_root)/ready/JUL2026/active_stage"; printf '%064d\n' 0 >"$(local_root)/ready/JUL2026/active_stage"; verify; record 'verwisselde stage-identiteit wordt geblokkeerd' 20 $?
setup_case idempotent; stage >/dev/null; first=$(cat "$(local_root)/ready/JUL2026/active_stage"); stage >/dev/null; second=$(cat "$(local_root)/ready/JUL2026/active_stage"); [[ "$first" == "$second" ]]; record 'exacte restage is idempotent' 0 $?
setup_case signature; chmod u+w "$CASE/central/JUL2026/artifact_manifest.json"; printf ' ' >>"$CASE/central/JUL2026/artifact_manifest.json"; stage; record 'ongeldige manifest-signature wordt geblokkeerd' 20 $?
setup_case checksum; sed -i 's/^DB_RU_ZIP_SHA256=.*/DB_RU_ZIP_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$CASE/central/JUL2026/opg_cycle.conf"; stage; record 'checksum-mismatch in cyclemetadata wordt geblokkeerd' 20 $?

setup_case traversal; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:z.writestr('../escape','x')
PY
sign_manifest; stage; record 'ZIP path traversal wordt geblokkeerd' 20 $?
setup_case wrongtop; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:z.writestr('394720501/payload','x')
PY
sign_manifest; stage; record 'verkeerde top-level patch-ID wordt geblokkeerd' 20 $?
setup_case symlinkzip; python3 - "$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip" <<'PY'
import stat,sys,zipfile
i=zipfile.ZipInfo('39472050/link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16
with zipfile.ZipFile(sys.argv[1],'w') as z:z.writestr(i,'/etc/passwd')
PY
sign_manifest; stage; record 'symlink-entry in ZIP wordt geblokkeerd' 20 $?
setup_case space; export OPG_MEDIA_TEST_FREE_BYTES=0; stage; record 'onvoldoende stagingruimte wordt geblokkeerd' 20 $?
setup_case inodes; export OPG_MEDIA_TEST_FREE_INODES=0; stage; record 'onvoldoende staginginodes wordt geblokkeerd' 20 $?
setup_case interrupted; mkdir -p "$(local_root)/incoming/JUL2026.abandoned"; printf partial >"$(local_root)/incoming/JUL2026.abandoned/file"; stage; record 'onvolledige incoming wordt nooit als ready hergebruikt' 0 $?
setup_case corrupt; printf 'not a zip' >"$CASE/central/JUL2026/p39472050_190000_Linux-x86-64.zip"; sign_manifest; stage; record 'corrupte ZIP wordt vóór publicatie geblokkeerd' 20 $?
setup_case concurrent; stage >"$CASE/one.out" 2>"$CASE/one.err" & p1=$!; stage >"$CASE/two.out" 2>"$CASE/two.err" & p2=$!; wait "$p1"; r1=$?; wait "$p2"; r2=$?; verify; rv=$?; [[ $r1 -eq 0 && $r2 -eq 0 && $rv -eq 0 ]]; record 'concurrent identiek stagen convergeert veilig' 0 $?
setup_case noshare; stage >/dev/null; mv "$CASE/central" "$CASE/central.offline"; verify; record 'verify/apply-media heeft geen share-fallback nodig' 0 $?
setup_case keychange; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CASE/other.pem" >/dev/null 2>&1; openssl pkey -in "$CASE/other.pem" -pubout -out "$CASE/public.pem" >/dev/null 2>&1; stage; record 'vervangen artifact trust-anchor blokkeert' 20 $?
setup_case keymode; chmod 0666 "$CASE/public.pem"; stage; record 'group/world-writable artifact key wordt geblokkeerd' 20 $?
setup_case opatchversion; python3 - "$CASE/central/opatch/p6880880_190000_Linux-x86-64.zip" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:z.writestr('OPatch/version.txt','OPATCH_VERSION: 12.2.0.1.51\n')
PY
sign_manifest; stage; record 'verkeerde interne OPatch-versie wordt geblokkeerd' 20 $?

setup_case unknownfield; chmod u+w "$CASE/central/JUL2026/artifact_manifest.json"; python3 - "$CASE/central/JUL2026/artifact_manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['unexpected']='x'; open(p,'w').write(json.dumps(d,separators=(',',':'))+'\n')
PY
chmod u+w "$CASE/central/JUL2026/artifact_manifest.sig"
openssl dgst -sha256 -sign "$CASE/private.pem" -out "$CASE/central/JUL2026/artifact_manifest.sig" "$CASE/central/JUL2026/artifact_manifest.json"; stage; record 'onbekend signed-manifestveld wordt geblokkeerd' 20 $?

launch="$BASE.launcher"; mkdir -p "$launch"; cp "$SOURCE_HELPER" "$launch/opg_media_stage_root.sh"; cp "$SOURCE_HELPER_ENGINE" "$launch/opg_media_stage_root.py"; chmod 0755 "$launch" "$launch/opg_media_stage_root.sh"; chmod 0775 "$launch/opg_media_stage_root.py"
OPG_MEDIA_TEST_MODE=1 OPG_MEDIA_TEST_ROOT="$CASE" "$launch/opg_media_stage_root.sh" verify-active-stage JUL2026 >/dev/null 2>&1; record 'writable lokale media-engine wordt geweigerd' 30 $?
rm "$launch/opg_media_stage_root.py"; ln -s "$SOURCE_HELPER_ENGINE" "$launch/opg_media_stage_root.py"
OPG_MEDIA_TEST_MODE=1 OPG_MEDIA_TEST_ROOT="$CASE" "$launch/opg_media_stage_root.sh" verify-active-stage JUL2026 >/dev/null 2>&1; record 'symlink lokale media-engine wordt geweigerd' 30 $?

printf '\nPilot07 media results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
