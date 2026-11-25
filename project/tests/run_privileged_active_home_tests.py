#!/usr/bin/env python3
"""Test the read-only helper and its Bash caller with isolated fixtures."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "oem-tasks/opg_active_home_inspect.py"
SPEC = importlib.util.spec_from_file_location("helper", HELPER)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
SOURCE = (ROOT / "project/patchGD_guard.sh").read_text(encoding="utf-8")
HOME = "/opt/oracle/dbhome_1"
UID, GID = 65534, 65534
POLICY = {"uid": UID, "gid": GID, "oracle_home": HOME,
          "namespaces": {name: "{}:[123]".format(name) for name in helper.NAMESPACES}}
BINDING = "OPG_ACTIVE_HOME_INSPECTION|version=1|mode={}|home={}|exit_code={}"
HIT = 'ACTIVE_HOME_FILE|pid=1|uid=1001|process="fixture"|file="{}/bin/oracle"'.format(HOME)


def function(name):
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S).group()


class HelperTests(unittest.TestCase):
    def test_rejects_unprivileged_invocation_and_arbitrary_arguments(self):
        with patch.object(helper.os, "getuid", return_value=UID), \
                patch.object(helper, "load_policy") as load, contextlib.redirect_stdout(io.StringIO()):
            for args in (["scan"], ["scan", HOME], ["--visibility"], []):
                self.assertEqual(helper.main(args), 30)
        load.assert_not_called()

    def test_binds_sudo_caller_before_scanning(self):
        for credentials in ({}, {"SUDO_UID": "0", "SUDO_GID": str(GID)},
                            {"SUDO_UID": str(UID), "SUDO_GID": "1"}):
            with self.subTest(credentials=credentials), patch.dict(os.environ, credentials, clear=True), \
                    patch.object(helper.os, "getuid", return_value=0), \
                    patch.object(helper.os, "geteuid", return_value=0), \
                    patch.object(helper, "load_policy", return_value=POLICY), \
                    patch.object(helper, "restrict_observer") as restrict, \
                    contextlib.redirect_stdout(io.StringIO()) as evidence:
                self.assertEqual(helper.main(["scan"]), 30)
                self.assertIn("caller is not authorized", evidence.getvalue())
                restrict.assert_not_called()

    def test_refuses_unsafe_file_and_parent_permissions(self):
        path = Path("/fixture/scanner.py")
        safe_file = SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o644)
        safe_parent = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        for file, parent, allowed in (
                (safe_file, safe_parent, True),
                (SimpleNamespace(st_uid=UID, st_mode=safe_file.st_mode), safe_parent, False),
                (SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o664), safe_parent, False),
                (SimpleNamespace(st_uid=0, st_mode=stat.S_IFLNK | 0o777), safe_parent, False),
                (safe_file, SimpleNamespace(st_uid=UID, st_mode=safe_parent.st_mode), False),
                (safe_file, SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o775), False)):
            with self.subTest(file=file, parent=parent), \
                    patch.object(Path, "lstat", side_effect=(file, parent, safe_parent)):
                if allowed:
                    helper.require_trusted_file(path, 0o644)
                else:
                    with self.assertRaises(PermissionError):
                        helper.require_trusted_file(path, 0o644)

    def test_rejects_wrong_namespace_and_malformed_policy(self):
        with patch.object(helper, "readlink", return_value="pid:[456]"):
            with self.assertRaises(PermissionError):
                helper.require_host_namespaces(POLICY["namespaces"])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            with patch.object(helper, "POLICY", path), patch.object(helper, "require_trusted_file"):
                path.write_text(json.dumps(POLICY))
                self.assertEqual(helper.load_policy(), POLICY)
                for invalid in (json.dumps(POLICY).replace(HOME, HOME + "/../other"),
                                json.dumps(POLICY).replace('"uid": 65534', '"uid": 0, "uid": 65534'),
                                json.dumps(POLICY).replace('"gid": 65534', '"gid": true')):
                    path.write_text(invalid)
                    with self.assertRaises(ValueError):
                        helper.load_policy()

    def test_missing_ptrace_capability_fails_before_reading_targets(self):
        with patch.object(helper, "status_fields", return_value={"CapPrm": "0"}), \
                patch.object(helper, "set_process_option") as set_option:
            with self.assertRaisesRegex(PermissionError, "CAP_SYS_PTRACE unavailable"):
                helper.restrict_observer(UID, GID)
        set_option.assert_not_called()

    def test_helper_emits_versioned_binding(self):
        credentials = {"SUDO_UID": str(UID), "SUDO_GID": str(GID)}
        metadata = SimpleNamespace(st_uid=UID, st_mode=stat.S_IFDIR | 0o755)
        for mode, code, subject in (("visibility", 0, None), ("scan", 0, os.fsencode(HOME)),
                                    ("scan", 20, os.fsencode(HOME))):
            with self.subTest(mode=mode, code=code):
                inspect = Mock(return_value=code)
                with patch.dict(os.environ, credentials, clear=True), \
                        patch.object(helper.os, "getuid", return_value=0), \
                        patch.object(helper.os, "geteuid", return_value=0), \
                        patch.object(helper, "load_policy", return_value=POLICY), \
                        patch.object(helper, "require_host_namespaces"), \
                        patch.object(helper, "require_trusted_file"), \
                        patch.object(helper, "restrict_observer"), \
                        patch.object(helper.os, "stat", return_value=metadata), \
                        patch.object(helper.os.path, "realpath", return_value=HOME), \
                        patch.object(helper.runpy, "run_path", return_value={"inspect_proc": inspect}), \
                        contextlib.redirect_stdout(io.StringIO()) as evidence:
                    actual = helper.main([mode])
                self.assertEqual(actual, code)
                self.assertEqual(evidence.getvalue().strip(), BINDING.format(mode, HOME, code))
                inspect.assert_called_once_with(subject)


class GuardTests(unittest.TestCase):
    def inspect(self, mode, rc, transcript, trust="yes", route="inspect"):
        shell = r'''
set -uo pipefail
ACTIVE_HOME_INSPECTION_MODE=privileged
EXIT_UNKNOWN=30 EXIT_BLOCKED=20
TARGET_ORACLE_HOME=$1; RUN_DIR=$2
PATCH_ROOT=/fixture; MONTH=TEST
case "$5" in
  missing) active_home_executable_trusted() { return 1; } ;;
  yes) active_home_executable_trusted() {
    [[ "$*" == '/usr/bin/sudo 4755' || "$*" == '/usr/local/sbin/opg_active_home_inspect 755' ]]
  } ;;
esac
opg_run_capture() {
  case "$1" in
    active_files_*) : >"$2"; return 0 ;;
    verify_ojvm) printf '%s\n' "$OJVM_PATCH" >"$2"; return 0 ;;
  esac
  [[ "$#" == 9 && "$3 $4 $5 $6 $7 $8" == '/usr/bin/sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect' ]] || return 99
  printf '%s\n' "$*" >>"$RUN_DIR/calls"
  cat "$RUN_DIR/helper-output" >"$2"
  return "$TEST_HELPER_RC"
}
check_active_home_tools() { :; }
verify_manifest_databases_stopped() { :; }
active_files_prereq_result() { :; }
record_binary_readiness() {
  printf '%s|%s|%s\n' "$1" "$2" "$4"
  [[ "$1" == PASS ]]
}
publish_apply_retry() { return 1; }
begin_apply_retry() { printf 'checkpoint consumed\n'; }
opg_run_critical() { printf 'patch command: %s\n' "$1"; }
opg_write_state() { :; }
TEST_HELPER_RC=$4
case "$6" in
  inspect) run_active_home_inspection test "$RUN_DIR/result" "$3" ;;
  visibility) preapply_active_home_visibility ;;
  retry) DB_PATCH=111111; OJVM_PATCH=222222; retry_stage=before_ojvm; apply_binary_patches ;;
  *) require_binary_home_ready "$6" 111111 ;;
esac
'''
        functions = "\n".join(function(name) for name in (
            "run_active_home_inspection", "preapply_active_home_visibility", "require_binary_home_ready",
            "apply_binary_patches"))
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "helper-output").write_text(transcript)
            result = subprocess.run(["bash", "-c", functions + "\n" + shell, "_", HOME, tmp, mode,
                                     str(rc), trust, route], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            calls = Path(tmp) / "calls"
            return result, calls.read_text() if calls.exists() else ""

    def test_requires_matching_home_mode_rc_and_evidence(self):
        ok = "ACTIVE_HOME_SCAN_CLEAR\n" + BINDING.format("scan", HOME, 0)
        for code, transcript, expected in (
                (0, ok, 0), (0, ok.replace(HOME, HOME + "/other"), 30),
                (0, ok.replace("mode=scan", "mode=visibility"), 30),
                (0, ok + "\n" + ok, 30), (0, ok.split("\n")[1], 30),
                (0, ok + "\n" + HIT, 30), (0, ok + "\nPROC_COVERAGE_UNKNOWN|fixture", 30),
                (20, HIT + "\n" + BINDING.format("scan", HOME, 20), 20),
                (20, BINDING.format("scan", HOME, 20), 30), (30, "access denied", 30),
                (1, "sudo denied", 30), (124, ok, 30)):
            with self.subTest(code=code, transcript=transcript):
                result, calls = self.inspect("scan", code, transcript)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn("opg_active_home_inspect scan", calls)

    def test_rejects_legacy_or_incompatible_protocol_in_both_modes(self):
        for mode, marker in (("visibility", "PROC_COVERAGE_CONFIRMED"), ("scan", "ACTIVE_HOME_SCAN_CLEAR")):
            for version in ("", "|version=0", "|version=2", "|version=01", "|version=1|version=2"):
                with self.subTest(mode=mode, version=version):
                    binding = BINDING.format(mode, HOME, 0).replace("|version=1", version)
                    result, _ = self.inspect(mode, 0, marker + "\n" + binding)
                    self.assertEqual(result.returncode, 30, result.stderr)

    def test_missing_helper_fails_before_sudo(self):
        result, calls = self.inspect("scan", 0, "", trust="missing")
        self.assertEqual(result.returncode, 30, result.stderr)
        self.assertEqual(calls, "")

    def test_missing_executable_is_untrusted(self):
        with tempfile.TemporaryDirectory() as tmp:
            command = function("active_home_executable_trusted") + '\nactive_home_executable_trusted "$1" 755'
            result = subprocess.run(["bash", "-c", command, "_", tmp + "/missing"])
            self.assertEqual(result.returncode, 1)

    def test_all_binary_stages_and_preflight_use_bound_helper(self):
        visibility = "PROC_COVERAGE_CONFIRMED\n" + BINDING.format("visibility", HOME, 0)
        result, calls = self.inspect("visibility", 0, visibility, route="visibility")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("opg_active_home_inspect visibility", calls)
        for stage in ("before_db", "before_ojvm", "resume_ojvm"):
            for rc, transcript, evidence in (
                    (0, "ACTIVE_HOME_SCAN_CLEAR", b"PASS|files|0"),
                    (20, HIT, b"BLOCKED|files|20"),
                    (124, "", b"UNKNOWN|files|30")):
                with self.subTest(stage=stage, rc=rc):
                    result, calls = self.inspect("scan", rc, transcript + "\n" + BINDING.format("scan", HOME, rc),
                                                 route=stage)
                    self.assertEqual(result.returncode, 0 if rc == 0 else 1, result.stderr)
                    self.assertIn(evidence, result.stdout)
                    self.assertIn("active_home_{}".format(stage), calls)

    def test_retry_requires_bound_scan_before_consuming_checkpoint(self):
        result, calls = self.inspect("scan", 20, HIT + "\n" + BINDING.format("scan", HOME, 20),
                                     route="retry")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("active_home_before_ojvm", calls)
        self.assertNotIn(b"checkpoint consumed", result.stdout)
        self.assertNotIn(b"patch command:", result.stdout)

        result, calls = self.inspect("scan", 0, "ACTIVE_HOME_SCAN_CLEAR\n" + BINDING.format("scan", HOME, 0),
                                     route="retry")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("active_home_before_ojvm", calls)
        self.assertIn(b"checkpoint consumed\npatch command: apply_ojvm", result.stdout)


@unittest.skipUnless(os.getuid() == 0 and os.environ.get("OPG_TEST_PRIVILEGED_SCAN") == "1",
                     "requires root, capabilities and OPG_TEST_PRIVILEGED_SCAN=1 in an isolated Linux test")
class LinuxPrivilegeTests(unittest.TestCase):
    def test_launcher_requires_safe_owner_mode_and_parents(self):
        def become_oracle():
            os.setgroups([])
            os.setgid(GID)
            os.setuid(UID)

        command = function("active_home_executable_trusted") + '\nactive_home_executable_trusted "$1" 755'
        with tempfile.TemporaryDirectory(prefix="opg-privileged-active-home.", dir="/run") as tmp:
            directory = Path(tmp)
            directory.chmod(0o755)
            executable = directory / "helper"
            executable.write_text("#!/bin/false\n")
            for mode, uid, parent_mode, expected in (
                    (0o755, 0, 0o755, 0), (0o775, 0, 0o755, 1), (0o755, UID, 0o755, 1),
                    (0o755, 0, 0o777, 1)):
                with self.subTest(mode=mode, uid=uid, parent_mode=parent_mode):
                    executable.chmod(mode)
                    os.chown(str(executable), uid, 0)
                    directory.chmod(parent_mode)
                    result = subprocess.run(["bash", "-c", command, "_", str(executable)],
                                            preexec_fn=become_oracle)
                    self.assertEqual(result.returncode, expected)

    def test_scan_non_dumpable_mapping_and_release_with_reduced_privileges(self):
        launcher = """
import os, runpy, signal, sys
entry = runpy.run_path(sys.argv[1], run_name='fixture')
from pathlib import Path
entry['main'].__globals__.update(POLICY=Path(sys.argv[2]), SCANNER=Path(sys.argv[3]))
if 'OPG_FIXTURE_ALARM' in os.environ:
    signal.signal(signal.SIGALRM, entry['timed_out'])
    signal.alarm(1)
sys.exit(entry['main'](sys.argv[4:]))
"""
        mapped_child = """
import ctypes, mmap, sys
with open(sys.argv[1], 'rb') as evidence:
    mapping = mmap.mmap(evidence.fileno(), 0, access=mmap.ACCESS_READ)
assert ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) == 0
print('ready', flush=True)
sys.stdin.read()
"""
        credentials = {"SUDO_UID": str(UID), "SUDO_GID": str(GID)}
        with tempfile.TemporaryDirectory(prefix="opg-privileged-active-home.", dir="/run") as tmp:
            directory = Path(tmp)
            directory.chmod(0o755)
            home = directory / "dbhome"
            home.mkdir(mode=0o755)
            os.chown(str(home), UID, GID)
            mapping = home / "mapped.bin"
            mapping.write_bytes(b"fixture data")
            scanner = directory / "opg_active_home.py"
            scanner.write_bytes((ROOT / "project/lib/opg_active_home.py").read_bytes())
            scanner.chmod(0o644)
            policy = directory / "policy.json"
            policy.write_text(json.dumps(dict(POLICY, oracle_home=str(home), namespaces={
                name: os.readlink("/proc/1/ns/" + name) for name in helper.NAMESPACES})))
            policy.chmod(0o400)
            command = [sys.executable, "-IBS", "-c", launcher, str(HELPER), str(policy), str(scanner)]

            def inspect(mode, expected):
                result = subprocess.run(command + [mode], env=credentials, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, timeout=10)
                self.assertEqual(result.returncode, expected, (result.stdout, result.stderr))
                return result.stdout

            def become_oracle():
                os.setgroups([])
                os.setgid(GID)
                os.setuid(UID)

            with subprocess.Popen([sys.executable, "-IBS", "-c", mapped_child, str(mapping)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, preexec_fn=become_oracle) as child:
                try:
                    self.assertEqual(child.stdout.readline(), b"ready\n")
                    self.assertIn(b"PROC_COVERAGE_CONFIRMED", inspect("visibility", 0))
                    self.assertIn(os.fsencode(mapping), inspect("scan", 20))
                finally:
                    child.stdin.close()
            self.assertIn(b"ACTIVE_HOME_SCAN_CLEAR", inspect("scan", 0))
            os.chown(str(home), 0, 0)
            self.assertIn(b"Oracle Home binding", inspect("scan", 30))
            os.chown(str(home), UID, GID)
            scanner.write_text("import time\ndef inspect_proc(home):\n    time.sleep(5)\n")
            credentials["OPG_FIXTURE_ALARM"] = "1"
            self.assertIn(b"inspection deadline exceeded", inspect("scan", 30))
            policy.chmod(0o644)
            self.assertIn(b"untrusted file", inspect("scan", 30))


class InspectionTestResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.privileged_tests = 0

    def startTest(self, test):
        super().startTest(test)
        if isinstance(test, LinuxPrivilegeTests):
            self.privileged_tests += 1


if __name__ == "__main__":
    runner = unittest.TextTestRunner(verbosity=2, resultclass=InspectionTestResult)
    result = unittest.main(testRunner=runner, exit=False).result
    privileged_skips = sum(isinstance(test, LinuxPrivilegeTests) for test, _ in result.skipped)
    standard_skips = len(result.skipped) - privileged_skips
    print("Standaardtests: {} uitgevoerd, {} overgeslagen".format(
        result.testsRun - result.privileged_tests - standard_skips, standard_skips))
    print("Root-/capabilitytests: {} uitgevoerd, {} overgeslagen".format(
        result.privileged_tests - privileged_skips, privileged_skips))
    sys.exit(0 if result.wasSuccessful() else 1)
