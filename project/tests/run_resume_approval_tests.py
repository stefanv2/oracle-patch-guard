#!/usr/bin/env python3
"""Real signatures/verifier; stub Oracle operations and count every mutation."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "patchGD_guard.sh").read_text()
ROUTES = (
    "MEDIA_VALIDATED:OPATCH_UPGRADE", "OPATCH_STAGED:OPATCH_UPGRADE",
    "OPATCH_BACKED_UP:OPATCH_UPGRADE", "OPATCH_INSTALLED_UNVERIFIED:OPATCH_UPGRADE",
    "OPATCH_READY:OPATCH_UPGRADE", "PARTIAL:OPATCH_STAGED",
    "PARTIAL:OPATCH_BACKED_UP", "PARTIAL:OPATCH_INSTALLED_UNVERIFIED",
    "PARTIAL:DB_BINARY", "06_DB_BINARY_APPLIED:DB_BINARY",
    "07_OJVM_BINARY_APPLIED:OJVM_BINARY", "PARTIAL:START_DATABASES",
    "PARTIAL:START_LISTENER", "08_DATABASES_STARTED:START_DATABASES",
    "PARTIAL:DATAPATCH", "09_DATAPATCH_COMPLETE:DATAPATCH", "PARTIAL:UTLRP",
    "10_UTLRP_COMPLETE:UTLRP", "PARTIAL:VALIDATION",
    "MANUAL_INTERVENTION_REQUIRED:VALIDATION",
)


def function(name):
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S).group()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def openssl(*args):
    subprocess.run(["openssl"] + list(map(str, args)), check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def case(work, private, public, route, fault):
    manifest = {"run_id": "RESUME1", "hostname": "host.example.com",
                "target_oracle_home": "/oracle/home",
                "approval_public_key_sha256": digest(public)}
    for name, field, value in (
        ("wrong_run", "run_id", "OTHER"),
        ("manifest_host", "hostname", "other.example.com"),
        ("manifest_home", "target_oracle_home", "/other/home"),
        ("fingerprint", "approval_public_key_sha256", "0" * 64),
    ):
        if fault == name:
            manifest[field] = value
    approved = work / "approved.json"
    local = work / "patch_manifest.json"
    token = work / "approval.json"
    write_json(approved, manifest)
    local.write_bytes(approved.read_bytes())
    if fault == "changed_local":
        local.write_text(local.read_text() + " ")
    (work / "patch_manifest.sha256").write_text(digest(local) + "\n")
    if fault == "changed_checksum":
        (work / "patch_manifest.sha256").write_text("0" * 64 + "\n")
    approval = {"manifest_sha256": digest(approved), "hostname": "host.example.com",
                "target_oracle_home": "/oracle/home", "approved": True,
                "expires_epoch": 4102444800,
                "manifest_signature_file": str(work / "manifest.sig"),
                "approval_signature_file": str(work / "approval.sig")}
    if fault == "expired":
        approval["expires_epoch"] = 1
    if fault == "token_host":
        approval["hostname"] = "other.example.com"
    if fault == "token_home":
        approval["target_oracle_home"] = "/other/home"
    write_json(token, approval)
    signing_key = private if fault != "changed_key" else work.parent / "other.pem"
    openssl("dgst", "-sha256", "-sign", signing_key, "-out", work / "manifest.sig", approved)
    openssl("dgst", "-sha256", "-sign", signing_key, "-out", work / "approval.sig", token)
    if fault in ("bad_manifest_signature", "bad_token_signature"):
        (work / ("manifest.sig" if fault == "bad_manifest_signature" else "approval.sig")).write_bytes(b"invalid")
    if fault == "changed_signed_manifest":
        approved.write_text(approved.read_text() + " ")
        local.write_bytes(approved.read_bytes())
        (work / "patch_manifest.sha256").write_text(digest(local) + "\n")
        approval["manifest_sha256"] = digest(approved)
        write_json(token, approval)
        openssl("dgst", "-sha256", "-sign", private, "-out", work / "approval.sig", token)
    if fault == "missing_token":
        token.unlink()
    key = public if fault != "changed_key" else work.parent / "other-public.pem"
    (work / "findings.psv").write_text("")
    (work / "execution_state.json").write_text("original recovery state\n")
    state, phase = route.split(":")
    variables = {"RUN_DIR": str(work), "RUN_ID": "RESUME1", "HOST_NAME": "host.example.com",
                 "TARGET_ORACLE_HOME": "/oracle/home", "APPROVAL_PUBLIC_KEY": str(key),
                 "APPROVED_MANIFEST": str(approved), "APPROVAL_TOKEN": str(token),
                 "CURRENT_STATE": state, "CURRENT_PHASE": phase,
                 "LOCAL_MEDIA_MODE": "disabled", "DRY_RUN": "false",
                 "DB_PATCH": "111", "OJVM_PATCH": "222", "PATCH_ROOT": "/media", "MONTH": "JUL2026"}
    if fault == "missing_args":
        variables.update(APPROVED_MANIFEST="", APPROVAL_TOKEN="")
    if fault == "dry_run":
        variables.update(DRY_RUN="true", APPROVED_MANIFEST="", APPROVAL_TOKEN="")
    code = "source " + shlex.quote(str(ROOT / "lib/opg_core.sh")) + "\n"
    code += "\n".join(function(n) for n in (
        "approval_public_key_sha256", "verify_approval", "report_approval_blocked", "perform_resume"))
    code += "\nset -u\nunset OPG_TEST_MODE\n"
    code += "\n".join(k + "=" + shlex.quote(v) for k, v in variables.items())
    code += r'''
load_run_context() { :; }
initialize_local_media() { :; }
opg_acquire_lock() { :; }
opg_release_lock() { :; }
opg_prepare_database_baseline_snapshot() { :; }
verify_resume_environment() { :; }
verify_resume_listener_progress() { :; }
opg_write_state() { :; }
opg_run_capture() {
  printf '111\n' >"$2"
  if [[ "$CURRENT_STATE" != 06_DB_BINARY_APPLIED && "$CURRENT_STATE:$CURRENT_PHASE" != PARTIAL:DB_BINARY || "$1" != resume_inventory ]]; then
    printf '222\n' >>"$2"
  fi
}
mutation() { printf 'mutation\n' >>"$RUN_DIR/mutations"; }
perform_opatch_upgrade() { mutation; }
stop_databases() { mutation; }
apply_binary_patches() { mutation; }
start_original_databases() { mutation; }
register_original_databases() { mutation; }
start_original_listeners() { mutation; }
run_datapatch_all() { mutation; }
run_utlrp_all() { mutation; }
validate_all() { mutation; }
opg_run_critical() { mutation; }
perform_resume
'''
    result = subprocess.run(["bash", "-o", "pipefail", "-c", code],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    allowed = fault in ("valid", "dry_run") or state == "12_COMPLETE"
    expected_mutation = allowed and fault != "dry_run" and state != "12_COMPLETE"
    assert result.returncode == (0 if allowed else 20), (route, fault, result.stdout, result.stderr)
    assert (work / "mutations").exists() == expected_mutation, (route, fault, "mutation boundary")
    assert (work / "execution_state.json").read_text() == "original recovery state\n"


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix="opg-resume-approval.") as directory:
        base = Path(directory)
        private, public = base / "private.pem", base / "public.pem"
        openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private)
        openssl("pkey", "-in", private, "-pubout", "-out", public)
        openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", base / "other.pem")
        openssl("pkey", "-in", base / "other.pem", "-pubout", "-out", base / "other-public.pem")
        faults = ("valid", "missing_args", "missing_token", "bad_manifest_signature", "bad_token_signature",
                  "changed_local", "changed_checksum", "changed_signed_manifest", "wrong_run", "manifest_host",
                  "manifest_home", "token_host", "token_home", "fingerprint", "changed_key", "expired", "dry_run")
        for route in ROUTES + ("12_COMPLETE:COMPLETE",):
            for fault in faults if not route.startswith("12_COMPLETE") else ("expired", "missing_args"):
                work = base / str(count)
                work.mkdir()
                case(work, private, public, route, fault)
                count += 1
    print("Resume authorization: {} cases passed".format(count))


if __name__ == "__main__":
    main()
