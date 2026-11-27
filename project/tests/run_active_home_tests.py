#!/usr/bin/env python3
"""Exercise lsof interpretation and PRECHECK without Oracle processes."""

import contextlib
import errno
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("active_home", PROJECT / "lib/opg_active_home.py")
active_home = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(active_home)
HOME = b"/opt/oracle/dbhome_1"
PROCESS = b"p421\0cpython3\0u1001\0\n"


def mapping(path, fd=b"mem"):
    return b"f" + fd + b"\0tREG\0n" + path + b"\0\n"


def proc_fixture(root, uid=1001, command=b"app", maps=b"", threads=1, exe=None):
    proc = root / "421"
    proc.mkdir()
    (proc / "status").write_bytes(
        b"Uid:\t" + b"\t".join([str(uid).encode()] * 4) + b"\nThreads:\t" + str(threads).encode() + b"\n")
    (proc / "comm").write_bytes(command + b"\n")
    (proc / "maps").write_bytes(maps)
    if exe is not None:
        (proc / "exe").symlink_to(os.fsdecode(exe))
    return proc


class InspectionTests(unittest.TestCase):
    def inspect_fixture(self, root, subject=os.fsdecode(HOME)):
        empty_lsof = subprocess.CompletedProcess([], 1, b"", b"")
        with patch.object(active_home, "PROC_ROOT", os.fsencode(root)), \
                patch.object(active_home, "proc_pids", return_value=[b"421"]), \
                patch.object(active_home.subprocess, "run", return_value=empty_lsof), \
                contextlib.redirect_stdout(io.StringIO()) as evidence:
            status = active_home.main(subject)
        return status, evidence.getvalue()

    def test_same_uid_sd_pam_and_other_uid_denials_mean_unknown(self):
        proc_file = active_home.proc_file
        observer_uid = os.geteuid()
        for uid, command, denied in ((observer_uid, b"(sd-pam)", errno.EACCES),
                                     (observer_uid + 1, b"other-user", errno.EPERM)):
            def deny_maps(proc_fd, name):
                if name == b"maps":
                    raise PermissionError(denied, "denied")
                return proc_file(proc_fd, name)

            for subject in (os.fsdecode(HOME), "--visibility"):
                with self.subTest(uid=uid, subject=subject), tempfile.TemporaryDirectory() as tmp:
                    proc_fixture(Path(tmp), uid=uid, command=command)
                    with patch.object(active_home, "proc_file", side_effect=deny_maps):
                        status, evidence = self.inspect_fixture(tmp, subject)
                    self.assertEqual(status, 30)
                    self.assertIn("PROC_COVERAGE_UNKNOWN|pid=421 entry=maps errno={}".format(denied), evidence)
                    self.assertNotIn("PROC_COVERAGE_CONFIRMED", evidence)
                    self.assertNotIn("ACTIVE_HOME_SCAN_CLEAR", evidence)

    def test_other_uid_mapping_then_release_with_full_visibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = HOME + b"/bin/oracle"
            mapped = b"1000-2000 r--p 00000000 00:01 123 " + path + b"\n"
            baseline = b"2000-3000 r-xp 00000000 00:01 321 /usr/bin/python3\n"
            proc = proc_fixture(Path(tmp), uid=2002, command=b"python3", maps=baseline + mapped,
                                exe=b"/usr/bin/python3")
            status, evidence = self.inspect_fixture(tmp)
            self.assertEqual(status, 20)
            self.assertIn('ACTIVE_HOME_FILE|pid=421|uid=2002|process="python3"', evidence)
            self.assertIn(os.fsdecode(path), evidence)
            (proc / "maps").write_bytes(baseline)
            status, evidence = self.inspect_fixture(tmp)
            self.assertEqual(status, 0)
            self.assertIn("ACTIVE_HOME_SCAN_CLEAR", evidence)
            self.assertEqual(self.inspect_fixture(tmp, "--visibility")[0], 0)

    def test_maps_hit_survives_exe_permission_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            mapped = b"1000-2000 r--p 00000000 00:01 123 " + HOME + b"/bin/oracle\n"
            proc_fixture(Path(tmp), maps=mapped)
            with patch.object(active_home, "readlink", side_effect=PermissionError(errno.EACCES, "denied")):
                status, evidence = self.inspect_fixture(tmp)
            self.assertEqual(status, 20)
            self.assertIn("ACTIVE_HOME_FILE", evidence)
            self.assertIn("PROC_COVERAGE_UNKNOWN|pid=421 entry=exe", evidence)

    def test_missing_proc_file_requires_exit_confirmation(self):
        for condition, expected in (("gone", 0), ("live_without_maps_file", 30), ("lone_without_mappings", 0)):
            with self.subTest(condition=condition), tempfile.TemporaryDirectory() as tmp:
                if condition != "gone":
                    proc = proc_fixture(Path(tmp))
                    if condition == "live_without_maps_file":
                        (proc / "maps").unlink()
                status, _ = self.inspect_fixture(tmp)
                self.assertEqual(status, expected)

    def test_pid_exits_after_directory_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc_fixture(Path(tmp))
            for confirmation, expected in ((ProcessLookupError(errno.ESRCH, "exited"), 0),
                                           (PermissionError(errno.EACCES, "denied"), 30)):
                with self.subTest(confirmation=confirmation), \
                        patch.object(active_home, "proc_file",
                                     side_effect=(FileNotFoundError(errno.ENOENT, "maps"), confirmation)):
                    self.assertEqual(self.inspect_fixture(tmp)[0], expected)

    def test_no_executable_with_surviving_threads_is_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc_fixture(Path(tmp), threads=2)
            status, evidence = self.inspect_fixture(tmp)
            self.assertEqual(status, 30)
            self.assertIn("PROC_COVERAGE_UNKNOWN|pid=421 entry=exe", evidence)

    def test_proc_mount_that_hides_pids_is_unknown(self):
        mountinfo = b"21 20 0:15 / /proc rw,nosuid - proc proc rw,hidepid=2\n"
        with patch.object(active_home, "readlink", side_effect=(active_home.INITIAL_PID_NAMESPACE,
                          str(os.getpid()).encode("ascii"))), \
                patch("builtins.open", return_value=io.BytesIO(mountinfo)), \
                contextlib.redirect_stdout(io.StringIO()) as evidence:
            self.assertEqual(active_home.main("--visibility"), 30)
            self.assertIn("FILE_INSPECTION_UNKNOWN", evidence.getvalue())

    def test_local_proc_inspection_refuses_nested_or_unbound_pid_view(self):
        for links in ((b"pid:[999]",), (active_home.INITIAL_PID_NAMESPACE, b"0")):
            with self.subTest(links=links), patch.object(active_home, "readlink", side_effect=links), \
                    patch("builtins.open") as mountinfo, contextlib.redirect_stdout(io.StringIO()) as evidence:
                self.assertEqual(active_home.main("--visibility"), 30)
                self.assertNotIn("PROC_COVERAGE_CONFIRMED", evidence.getvalue())
                mountinfo.assert_not_called()

    def inspect(self, rc, output=b"", stderr=b"", proc=(set(), None)):
        result = subprocess.CompletedProcess([], rc, output, stderr)
        evidence = io.StringIO()
        with patch.object(active_home.subprocess, "run", return_value=result) as command, \
                patch.object(active_home, "scan_proc", return_value=proc) as scan, \
                contextlib.redirect_stdout(evidence):
            status = active_home.main(os.fsdecode(HOME))
        command.assert_called_once_with(
            ["lsof", "-nP", "-a", "-d", "txt,mem,DEL", "-F0pcuftn"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return status, evidence.getvalue(), scan.call_count

    def test_external_executable_with_target_mappings(self):
        stdout = PROCESS + mapping(b"/usr/bin/python3", b"txt")
        for name in (b"libclntsh.so.19.1", b"libsqlplus.so", b"libother.so"):
            stdout += mapping(HOME + b"/lib/" + name)
        status, evidence, proc_calls = self.inspect(0, stdout)
        self.assertEqual(status, 20)
        self.assertEqual(proc_calls, 0)
        self.assertEqual(evidence.count("ACTIVE_HOME_FILE|pid=421|uid=1001|process=\"python3\""), 3)
        self.assertIn("libother.so", evidence)

    def test_deleted_mapping(self):
        status, evidence, _ = self.inspect(0, PROCESS + mapping(HOME + b"/other.so (deleted)", b"DEL"))
        self.assertEqual(status, 20)
        self.assertIn("other.so (deleted)", evidence)

    def test_other_home_with_same_prefix(self):
        stdout = PROCESS + mapping(HOME + b"0/bin/sqlplus", b"txt")
        status, evidence, proc_calls = self.inspect(0, stdout)
        self.assertEqual(status, 0)
        self.assertEqual(proc_calls, 1)
        self.assertIn("ACTIVE_HOME_SCAN_CLEAR", evidence)

    def test_empty_exit_one_requires_proc_corroboration(self):
        self.assertEqual(self.inspect(1)[0], 0)
        status, evidence, calls = self.inspect(1, proc=(set(), "pid=17 errno=13"))
        self.assertEqual(status, 30)
        self.assertEqual(calls, 1)
        self.assertIn("PROC_COVERAGE_UNKNOWN", evidence)

    def test_silent_lsof_omission_can_be_detected_via_proc(self):
        hit = (23, 101, b"oracle", HOME + b"/lib/additional.so")
        status, evidence, _ = self.inspect(1, proc=({hit}, "pid=17 errno=13"))
        self.assertEqual(status, 20)
        self.assertIn("additional.so", evidence)

    def test_unreliable_results(self):
        cases = [
            (0, b"", b""), (0, b"unrecognizable", b""),
            (0, PROCESS + b"fmem\0tREG\0", b""),
            (1, PROCESS, b""), (2, b"", b""), (124, b"", b""),
            (1, b"", b"lsof: permission denied"),
        ]
        for rc, stdout, stderr in cases:
            with self.subTest(rc=rc, stdout=stdout, stderr=stderr):
                status, evidence, calls = self.inspect(rc, stdout, stderr)
                self.assertEqual(status, 30)
                self.assertEqual(calls, 0)
                self.assertNotIn("ACTIVE_HOME_SCAN_CLEAR", evidence)

    def test_missing_lsof(self):
        with patch.object(active_home.subprocess, "run", side_effect=FileNotFoundError("lsof")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(active_home.main(os.fsdecode(HOME)), 30)

    @unittest.skipUnless(shutil.which("lsof"), "lsof ontbreekt voor live fixture")
    def test_live_external_mapping(self):
        with tempfile.TemporaryDirectory(prefix="opg-active-file.") as tmp:
            path = Path(tmp) / "other-library.so"
            path.write_bytes(b"test mapping")
            code = "import mmap,sys; f=open(sys.argv[1],'rb'); "
            code += "m=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ); f.close(); "
            code += "print('ready',flush=True); sys.stdin.read()"
            with subprocess.Popen([sys.executable, "-c", code, str(path)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
                try:
                    self.assertEqual(process.stdout.readline(), b"ready\n")
                    evidence = io.StringIO()
                    with contextlib.redirect_stdout(evidence):
                        status = active_home.main(tmp)
                    self.assertEqual(status, 20, evidence.getvalue())
                    self.assertIn("pid={}".format(process.pid), evidence.getvalue())
                    self.assertIn(str(path), evidence.getvalue())
                finally:
                    process.stdin.close()


class NativePrerequisiteTests(unittest.TestCase):
    def test_acc_opatch_verdicts(self):
        passed = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 passed.\n'
        failed = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 failed.\n'
        incomplete = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 passed'
        cases = (
            ("passed", passed, "39915792", 0),
            ("failed", failed, "39915792", 20),
            ("different patch passed", passed, "39803650", 30),
            ("different patch failed", failed, "39803650", 30),
            ("contradictory", passed + failed, "39915792", 30),
            ("incomplete", incomplete, "39915792", 30),
            ("incomplete after pass", passed + incomplete, "39915792", 30),
            ("other patch after pass", passed + failed.replace("39915792", "39803650"), "39915792", 30),
        )
        source = (PROJECT / "patchGD_guard.sh").read_text(encoding="utf-8")
        definition = source.split("\nactive_files_prereq_result() {", 1)[1].split("\n}", 1)[0]
        script = "active_files_prereq_result() {" + definition + '\n}\nactive_files_prereq_result "$@"'
        with tempfile.TemporaryDirectory(prefix="opg-native-prereq.") as tmp:
            output = Path(tmp) / "prereq.log"
            for label, contents, patch_id, expected in cases:
                with self.subTest(label=label):
                    output.write_bytes(contents.encode("ascii"))
                    result = subprocess.run(["bash", "-c", script, "_", str(output), patch_id])
                    self.assertEqual(result.returncode, expected)


class PrecheckTests(unittest.TestCase):
    def find_processes(self, client):
        source = (PROJECT / "patchGD_guard.sh").read_text()
        function = source.split("\ndetect_home_processes() {", 1)[1].split("\n}", 1)[0]
        script = r'''
set -u
TARGET_ORACLE_HOME=$1
RUN_DIR=$2
unset OPG_TEST_MODE
opg_add_finding() { printf '%s|%s\n' "$1" "$2"; }
opg_manifest_sids() { printf 'TESTDB\n'; }
type() { return 1; }
''' + "detect_home_processes() {" + function + "\n}\ndetect_home_processes precheck\n"
        with tempfile.TemporaryDirectory(prefix="opg-precheck-proc.") as tmp:
            home = Path(tmp) / "dbhome"
            run = Path(tmp) / "run"
            (home / "bin").mkdir(parents=True)
            run.mkdir()
            processes = [("oracle", "ora_pmon_TESTDB"), ("tnslsnr", "tnslsnr")]
            if client:
                processes.append(("sqlplus", "sqlplus"))
            with contextlib.ExitStack() as stack:
                for binary, name in processes:
                    executable = home / "bin" / binary
                    shutil.copy2(shutil.which("sleep"), executable)
                    process = stack.enter_context(subprocess.Popen([name, "15"], executable=str(executable)))
                    stack.callback(process.terminate)
                output = subprocess.check_output(["bash", "-c", script, "_", str(home), str(run)])
                evidence = (run / "home_processes.txt").read_text()
                self.assertIn("/bin/oracle|ora_pmon_TESTDB", evidence)
                self.assertIn("/bin/tnslsnr|tnslsnr", evidence)
                return output

    def test_database_and_listener_are_expected(self):
        output = self.find_processes(False)
        self.assertNotIn(b"HOME_CLIENT_ACTIVE", output)
        self.assertNotIn(b"BLOCKED", output)

    def test_sqlplus_is_conditional(self):
        self.assertIn(b"CONDITIONAL|HOME_CLIENT_ACTIVE", self.find_processes(True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
