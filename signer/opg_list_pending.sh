#!/usr/bin/env bash
# Read-only signer-side overzicht van gestagede Oracle Patch Guard approvals.
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
  cat <<'EOF'
Gebruik: opg_list_pending.sh [--pending|--list|--help]

Zonder optie / --pending  Toon uitsluitend correct gestagede runs zonder approval.
--list                    Toon alle runs als PENDING, APPROVED, COMPLETE of UNKNOWN.
--help                    Toon deze hulp.

PENDING   PLAN is coherent gestaged en bevat nog geen approval-resultaat.
APPROVED  Manifest en approval zijn volledig gebonden en RSA/SHA256-geverifieerd.
COMPLETE  APPROVED plus betrouwbare terminale 12_COMPLETE-executionmetadata.
UNKNOWN   Status kan niet betrouwbaar of ondubbelzinnig worden vastgesteld.

Cleanup is bewust niet geïmplementeerd: er is geen afzonderlijk ondertekend
completionbewijs op de approval-share dat destructieve retentie autoriseert.
EOF
}

MODE=pending
MACHINE=false
FILTER_RUN=
while (( $# > 0 )); do
  case $1 in
    --pending) MODE=pending ;;
    --list) MODE=list ;;
    --machine) MACHINE=true ;;
    --run-id)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 70; }
      FILTER_RUN=$1
      ;;
    --help) usage; exit 0 ;;
    --cleanup)
      printf 'Cleanup is niet geïmplementeerd; approvaldata is niet gewijzigd.\n' >&2
      exit 70
      ;;
    *) usage >&2; exit 70 ;;
  esac
  shift
done

if [[ -n "$FILTER_RUN" && ! "$FILTER_RUN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]; then
  printf 'OPG signer UNKNOWN: ongeldige RUN_ID-filter.\n' >&2
  exit 70
fi

APPROVAL_ROOT=${OPG_APPROVAL_ROOT:-/mnt/patch-share/oracle-patch-guard/approvals}
APPROVAL_PUBLIC_KEY=${OPG_APPROVAL_PUBLIC_KEY:-/secure/oracle-patch-guard/keys/approval_public.pem}

exec /usr/bin/python3 -I - "$MODE" "$APPROVAL_ROOT" "$APPROVAL_PUBLIC_KEY" "$MACHINE" "$FILTER_RUN" <<'PY'
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

mode, root_text, key_text, machine_text, filter_run = sys.argv[1:]
machine = machine_text == "true"
root = Path(root_text)
public_key = Path(key_text)
safe_run = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
safe_sid = re.compile(r"^[A-Za-z0-9_#$]+$")
safe_hash = re.compile(r"^[0-9a-f]{64}$")
safe_iso = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
required_input = ("patch_manifest.json", "assessment.json", "findings.psv", "execution_state.json")
approval_names = ("approval.json", "patch_manifest.sig", "approval.sig")


class InvalidRun(Exception):
    pass


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRun(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def safe_regular(path, maximum=16 * 1024 * 1024):
    try:
        info = path.lstat()
    except OSError as exc:
        raise InvalidRun(str(exc)) from exc
    if (path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            info.st_size < 0 or info.st_size > maximum or stat.S_IMODE(info.st_mode) & 0o022):
        raise InvalidRun(f"unsafe file: {path.name}")
    return info


def stable_bytes(path, maximum=16 * 1024 * 1024):
    before = safe_regular(path, maximum)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        data = b""
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            data += block
            if len(data) > maximum:
                raise InvalidRun(f"oversized file: {path.name}")
        after = os.fstat(fd)
    finally:
        os.close(fd)
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in fields):
        raise InvalidRun(f"file changed while reading: {path.name}")
    return data


def read_json(path):
    try:
        value = json.loads(stable_bytes(path).decode("utf-8"), object_pairs_hook=strict_object)
    except (UnicodeError, json.JSONDecodeError, InvalidRun) as exc:
        raise InvalidRun(str(exc)) from exc
    if not isinstance(value, dict):
        raise InvalidRun(f"JSON root is not an object: {path.name}")
    return value


def text(value):
    return value if isinstance(value, str) else ""


def integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def sanitize(value, fallback="UNKNOWN"):
    value = " ".join(str(value).split())
    return value[:160] if value else fallback


def created_epoch(value):
    if not safe_iso.fullmatch(value):
        return 0
    try:
        return int(datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp())
    except ValueError:
        return 0


def fallback_sid(run_id, host, cycle):
    prefix = host + "-"
    marker = "-" + cycle + "-OEM-"
    if not run_id.startswith(prefix) or marker not in run_id:
        return "UNKNOWN"
    candidate, suffix = run_id[len(prefix):].rsplit(marker, 1)
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", suffix) or not safe_sid.fullmatch(candidate):
        return "UNKNOWN"
    return candidate


def parse_findings(path):
    conditions = []
    try:
        lines = stable_bytes(path).decode("utf-8").splitlines()
    except UnicodeError as exc:
        raise InvalidRun(str(exc)) from exc
    for raw in lines:
        if not raw:
            continue
        fields = raw.split("|")
        if len(fields) < 2 or fields[0] not in ("READY", "CONDITIONAL", "BLOCKED", "UNKNOWN"):
            raise InvalidRun("invalid findings.psv")
        if fields[0] in ("BLOCKED", "UNKNOWN"):
            raise InvalidRun("staged findings are not approvable")
        if fields[0] == "CONDITIONAL":
            if not re.fullmatch(r"[A-Z0-9_]{1,80}", fields[1]):
                raise InvalidRun("invalid conditional finding ID")
            conditions.append(fields[1])
    return conditions


def verify_signature(signature, payload):
    safe_regular(signature)
    if not Path("/usr/bin/openssl").is_file():
        raise InvalidRun("openssl unavailable")
    result = subprocess.run(
        ["/usr/bin/openssl", "dgst", "-sha256", "-verify", str(public_key),
         "-signature", str(signature), str(payload)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        raise InvalidRun("signature verification failed")


def verify_approval(run_dir, manifest, conditions):
    token_path = run_dir / "approval.json"
    token = read_json(token_path)
    key_bytes = stable_bytes(public_key, 1024 * 1024)
    expected_key_hash = text(manifest.get("approval_public_key_sha256"))
    if not safe_hash.fullmatch(expected_key_hash) or hashlib.sha256(key_bytes).hexdigest() != expected_key_hash:
        raise InvalidRun("approval public key does not match manifest binding")
    manifest_hash = hashlib.sha256(stable_bytes(run_dir / "patch_manifest.json")).hexdigest()
    if (token.get("approved") is not True or text(token.get("manifest_sha256")) != manifest_hash or
            text(token.get("hostname")) != text(manifest.get("hostname")) or
            text(token.get("target_oracle_home")) != text(manifest.get("target_oracle_home"))):
        raise InvalidRun("approval binding mismatch")
    expires = integer(token.get("expires_epoch"))
    if expires is None or expires < 0:
        raise InvalidRun("invalid approval expiry")
    for condition in conditions:
        if text(token.get("accept_" + condition)) != condition:
            raise InvalidRun("conditional finding is not accepted")
    if Path(text(token.get("manifest_signature_file"))).name != "patch_manifest.sig":
        raise InvalidRun("manifest signature filename mismatch")
    if Path(text(token.get("approval_signature_file"))).name != "approval.sig":
        raise InvalidRun("approval signature filename mismatch")
    verify_signature(run_dir / "patch_manifest.sig", run_dir / "patch_manifest.json")
    verify_signature(run_dir / "approval.sig", token_path)
    return expires


def inspect_run(entry):
    run_id = entry.name
    result = {"host": "UNKNOWN", "sid": "UNKNOWN", "cycle": "UNKNOWN", "created": "UNKNOWN",
              "epoch": 0, "status": "UNKNOWN", "run_id": sanitize(run_id),
              "reason": "status is niet betrouwbaar vastgesteld"}
    if not safe_run.fullmatch(run_id):
        result["reason"] = "ongeldige RUN_ID"
        return result
    try:
        info = entry.stat(follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or entry.is_symlink() or stat.S_IMODE(info.st_mode) & 0o022:
            result["reason"] = "onveilig directorytype of directorymode"
            return result
        run_dir = Path(entry.path)
        for child in os.scandir(run_dir):
            child_info = child.stat(follow_symlinks=False)
            if child.is_symlink() or not stat.S_ISREG(child_info.st_mode):
                raise InvalidRun("unexpected non-regular run artifact")
        for name in required_input:
            safe_regular(run_dir / name)
        manifest = read_json(run_dir / "patch_manifest.json")
        assessment = read_json(run_dir / "assessment.json")
        state = read_json(run_dir / "execution_state.json")
        if any(text(document.get("run_id")) != run_id for document in (manifest, assessment, state)):
            raise InvalidRun("run ID mismatch")
        host = text(manifest.get("hostname")); home = text(manifest.get("target_oracle_home"))
        cycle = text(manifest.get("month")); created = text(manifest.get("created_at"))
        if (not host or not home or not re.fullmatch(r"[A-Z][A-Z0-9_-]{2,31}", cycle) or
                not safe_iso.fullmatch(created) or integer(manifest.get("created_epoch")) is None or
                not safe_hash.fullmatch(text(manifest.get("approval_public_key_sha256")))):
            raise InvalidRun("invalid manifest identity metadata")
        if text(assessment.get("hostname")) not in ("", host) or text(state.get("hostname")) not in ("", host):
            raise InvalidRun("hostname mismatch")
        if text(assessment.get("target_oracle_home")) not in ("", home) or text(state.get("target_oracle_home")) not in ("", home):
            raise InvalidRun("Oracle Home mismatch")
        if (text(assessment.get("status")) not in ("READY", "CONDITIONAL") or
                integer(assessment.get("blocked_count")) != 0 or integer(assessment.get("unknown_count")) != 0):
            raise InvalidRun("assessment is not approvable")
        conditions = parse_findings(run_dir / "findings.psv")
        state_name = text(state.get("state")); phase = text(state.get("phase"))
        plan_state = state_name == "03_PLAN_GENERATED" and phase == "PLAN"
        complete_state = (state_name == "12_COMPLETE" and phase == "COMPLETE" and
                          integer(state.get("exit_code")) == 0 and safe_iso.fullmatch(text(state.get("timestamp"))))
        if not plan_state and not complete_state:
            raise InvalidRun("execution state is neither PLAN nor COMPLETE")
        sid = text(state.get("sid"))
        if not safe_sid.fullmatch(sid):
            sid = fallback_sid(run_id, host, cycle)
        result.update(host=sanitize(host), sid=sanitize(sid), cycle=sanitize(cycle), created=created,
                      epoch=integer(manifest.get("created_epoch")) or created_epoch(created))
        present = [os.path.lexists(run_dir / name) for name in approval_names]
        if any(present):
            if not all(present):
                raise InvalidRun("incomplete approval artifact set")
            expires = verify_approval(run_dir, manifest, conditions)
            if complete_state:
                result["status"] = "COMPLETE"
                result["reason"] = "terminale COMPLETE-state met geldige approval"
            elif expires >= int(time.time()):
                result["status"] = "APPROVED"
                result["reason"] = "approval cryptografisch geverifieerd"
            else:
                raise InvalidRun("approval expired")
        elif plan_state:
            result["status"] = "PENDING"
            result["reason"] = "READY FOR APPROVAL"
        else:
            raise InvalidRun("COMPLETE has no cryptographically verified approval")
    except (InvalidRun, OSError, ValueError, subprocess.SubprocessError) as exc:
        result["status"] = "UNKNOWN"
        result["reason"] = sanitize(str(exc), "status is niet betrouwbaar vastgesteld")
    return result


try:
    root_info = root.lstat()
    if root.is_symlink() or not stat.S_ISDIR(root_info.st_mode) or stat.S_IMODE(root_info.st_mode) & 0o022:
        raise OSError("approval root is unsafe")
    rows = [inspect_run(entry) for entry in os.scandir(root)
            if not entry.name.startswith(".") and (not filter_run or entry.name == filter_run)]
except OSError as exc:
    print(f"OPG signer UNKNOWN: approval root is niet betrouwbaar leesbaar: {exc}", file=sys.stderr)
    raise SystemExit(30)

rows.sort(key=lambda item: (item["epoch"], item["run_id"]), reverse=True)
if mode == "pending":
    rows = [item for item in rows if item["status"] == "PENDING"]
if machine:
    keys = ("host", "sid", "cycle", "created", "status", "run_id", "reason")
    for row in rows:
        print("\t".join(sanitize(row[key], "-") for key in keys))
    raise SystemExit(0)
headers = ("HOST", "SID", "CYCLE", "CREATED", "STATUS", "RUN_ID")
keys = ("host", "sid", "cycle", "created", "status", "run_id")
widths = [len(header) for header in headers]
for row in rows:
    for index, key in enumerate(keys):
        widths[index] = max(widths[index], len(row[key]))
print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
for row in rows:
    print("  ".join(row[key].ljust(widths[index]) for index, key in enumerate(keys)))
PY
