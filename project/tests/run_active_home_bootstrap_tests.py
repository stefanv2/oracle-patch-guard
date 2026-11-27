#!/usr/bin/env python3
"""Unprivileged regression tests for the Active Home deployment transaction."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("deploy", str(ROOT / "oem-tasks/opg_deploy_active_home.py"))
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opg-ah-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.addCleanup(patch.stopall)
        patch.multiple(DEPLOY, ROOT_UID=os.getuid(), ROOT_GID=os.getgid()).start()
        self.home = str(self.root / "home")
        self.policy = {"uid": 1000, "gid": 1001, "oracle_home": self.home,
                       "namespaces": dict(DEPLOY.INITIAL, mnt="mnt:[52]")}
        self.labels = SimpleNamespace(prepare=lambda *args: None, verify=lambda *args: None,
                                      reference=lambda *args: None)
        self.deploy = DEPLOY.Deployment(self.root / "etc/opg/patchGD_guard.conf", self.root, os.getgid(), self.labels)
        for path in self.deploy.paths.values():
            path.parent.mkdir(parents=True, exist_ok=True)
        self.bundle = {key: (ROOT / path).read_bytes() for key, path in DEPLOY.SOURCES.items()}
        self.bundle["policy"] = DEPLOY.encoded(self.policy)
        self.data = dict(self.bundle, context=b"bootstrap context\n",
                         config=b"ACTIVE_HOME_INSPECTION_MODE=privileged\n")
        self.visudo = b"\n".join(os.fsencode(str(self.deploy.paths[key])) + b": parsed OK"
                                 for key in ("sudoers", "context"))

    def publish_initial(self):
        with patch.object(DEPLOY, "command", return_value=self.visudo):
            self.deploy.activate(self.data, self.bundle, self.policy)

    def snapshot(self):
        return {key: (self.deploy.read(key), DEPLOY.stamp(path))
                for key, path in self.deploy.paths.items() if path.exists()}

    def candidate(self):
        binding = dict(self.policy, namespaces=dict(self.policy["namespaces"], mnt="mnt:[53]"))
        bundle = {key: data + b"\n" for key, data in self.bundle.items()}
        bundle["policy"] = DEPLOY.encoded(binding)
        return dict(bundle, context=b"new context\n", config=self.data["config"] + b"\n"), bundle, binding

    def test_policy_local_without_fragment(self):
        local = b"# Site config\nACTIVE_HOME_INSPECTION_MODE=local\n"
        self.assertIsNone(DEPLOY.host_policy(self.root, "server.example", self.root))
        self.assertEqual(DEPLOY.effective_config(local, None), local)
        self.deploy.require_local(local)
        self.assertFalse(any(path.exists() for path in self.deploy.paths.values()))
        with self.assertRaisesRegex(ValueError, "central host opt-in"):
            self.deploy.require_local(local.replace(b"local", b"privileged"))

    def test_policy_literal_unique_canonical_and_host_scoped(self):
        target = self.root / "config/hosts/server.example/active-home.conf"
        target.parent.mkdir(parents=True)
        valid = "# example\n{}=privileged\n{}={}\n".format(DEPLOY.MODE, DEPLOY.HOME, self.home)
        target.write_text(valid)
        self.assertEqual(DEPLOY.host_policy(self.root, "server.example", self.root), self.home)
        self.assertIsNone(DEPLOY.host_policy(self.root, "other.example", self.root))
        with self.assertRaisesRegex(ValueError, "invalid host name"):
            DEPLOY.host_policy(self.root, "../server.example", self.root)
        self.assertEqual(DEPLOY.effective_config(b"X=1\n", self.home),
                         b"X=1\nACTIVE_HOME_INSPECTION_MODE=privileged\n")
        with self.assertRaisesRegex(ValueError, "central base"):
            DEPLOY.effective_config(self.data["config"], None)
        for text in (valid + "{}=/other\n".format(DEPLOY.HOME), valid + "export X=1\n",
                     valid.replace(self.home, "$(touch /tmp/should-not-run)"), valid.replace(self.home, "/a/../b"),
                     valid.replace("privileged", "local")):
            with self.subTest(text=text):
                target.write_text(text)
                with self.assertRaises(ValueError):
                    DEPLOY.host_policy(self.root, "server.example", self.root)
        target.unlink()
        target.symlink_to("/missing")
        with self.assertRaisesRegex(ValueError, "untrusted file"):
            DEPLOY.host_policy(self.root, "server.example", self.root)
        with patch.object(Path, "lstat", side_effect=PermissionError("host policy cannot be read")):
            with self.assertRaises(PermissionError):
                DEPLOY.host_policy(self.root, "server.example", self.root)

    def test_known_manual_adoption_and_repeat(self):
        for key, data in self.bundle.items():
            self.deploy.paths[key].write_bytes(data)
            self.deploy.paths[key].chmod(self.deploy.modes[key])
        self.deploy.previous(self.home, self.policy)
        self.publish_initial()
        before = self.snapshot()
        self.deploy.previous(self.home, self.policy)
        self.publish_initial()
        self.assertEqual(self.snapshot(), before)
        with self.assertRaisesRegex(ValueError, "central host opt-in"):
            self.deploy.require_local(b"")

    def test_receipt_allows_upgrade_and_reboot_but_rejects_drift(self):
        self.publish_initial()
        data, bundle, binding = self.candidate()
        self.deploy.previous(self.home, binding)
        with patch.object(DEPLOY, "command", return_value=self.visudo):
            self.deploy.activate(data, bundle, binding)
        self.deploy.previous(self.home, binding)
        self.assertEqual(json.loads(self.deploy.read("policy")), binding)
        with self.assertRaisesRegex(ValueError, "unknown host/principal"):
            self.deploy.previous(self.home, dict(binding, gid=1010))
        self.deploy.paths["scanner"].write_bytes(b"unknown scanner")
        with self.assertRaisesRegex(ValueError, "drift"):
            self.deploy.previous(self.home, binding)

    def test_unknown_partial_installation_and_file_trust(self):
        launcher = self.deploy.paths["launcher"]
        launcher.write_bytes(self.bundle["launcher"])
        launcher.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "incomplete or unknown"):
            self.deploy.previous(self.home, self.policy)
        launcher.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "untrusted file"):
            self.deploy.read("launcher")
        launcher.chmod(0o755)
        with patch.object(DEPLOY, "ROOT_UID", os.getuid() + 1):
            with self.assertRaisesRegex(ValueError, "untrusted file"):
                self.deploy.read("launcher")
        launcher.unlink()
        launcher.symlink_to(self.deploy.config)
        with self.assertRaisesRegex(ValueError, "untrusted file"):
            self.deploy.read("launcher")
        launcher.parent.chmod(0o777)
        with self.assertRaisesRegex(ValueError, "untrusted directory"):
            DEPLOY.directory_chain(launcher.parent, self.root)

    def test_publication_fault_for_every_destination_fresh_and_upgrade(self):
        replace = os.replace
        for existing in (False, True):
            if existing:
                self.publish_initial()
            before = self.snapshot()
            for key, target in self.deploy.paths.items():
                for after in (False, True):
                    with self.subTest(existing=existing, destination=key, after=after):
                        failed = []

                        def fault(src, dst):
                            if Path(dst) == target and not failed:
                                failed.append(key)
                                if after:
                                    replace(src, dst)
                                raise OSError("injected publication failure")
                            return replace(src, dst)

                        with patch.object(DEPLOY, "command", return_value=self.visudo), patch.object(os, "replace", fault):
                            with self.assertRaisesRegex(OSError, "injected publication failure"):
                                self.deploy.activate(*self.candidate())
                        self.assertFalse(self.deploy.journal.exists())
                        self.assertEqual(self.snapshot(), before)

    def test_fsync_failure_after_commit_unlink_restores_old(self):
        self.publish_initial()
        before = self.snapshot()
        sync = DEPLOY.sync
        failed = []

        def fault(path):
            if path == self.deploy.journal.parent and not self.deploy.journal.exists() and not failed:
                failed.append(path)
                raise OSError("injected commit fsync failure")
            return sync(path)

        with patch.object(DEPLOY, "command", return_value=self.visudo), patch.object(DEPLOY, "sync", fault):
            with self.assertRaisesRegex(OSError, "commit fsync"):
                self.deploy.activate(*self.candidate())
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.deploy.journal.exists())

    def test_interrupted_rollback_is_recoverable(self):
        self.publish_initial()
        before = self.snapshot()
        with patch.object(self.deploy, "recover", side_effect=OSError("storage unavailable")), \
                patch.object(DEPLOY, "command", return_value=b"candidate failed effective sudoers"):
            with self.assertRaisesRegex(OSError, "storage unavailable"):
                self.deploy.activate(*self.candidate())
        journal = json.loads(self.deploy.journal.read_text())
        self.assertEqual(journal["home"], self.home)
        self.deploy.recover(journal)
        self.assertEqual(self.snapshot(), before)
        self.deploy.previous(self.home, self.policy)

    def test_prepare_modes_visibility_and_no_writes(self):
        self.publish_initial()
        binary = self.root / "usr/bin/sudo"
        binary.parent.mkdir(parents=True)
        binary.touch()
        before = self.snapshot()
        for mode in (0o4111, 0o4755):
            binary.chmod(mode)
            base = "PROC_COVERAGE_CONFIRMED\nOPG_ACTIVE_HOME_INSPECTION|version=1|mode=visibility|home={}"
            output = (base.format(self.home) + "|exit_code=0\n").encode("ascii")
            with patch.object(DEPLOY, "command", return_value=output) as called:
                self.deploy.check(self.data["config"], ROOT, self.home)
                called.assert_called_once_with([binary, "-n", "-u", "root", "--", self.deploy.paths["launcher"],
                                                "visibility"], capture=True)
            for invalid in (output.replace(b"PROC_COVERAGE_CONFIRMED", b"PROC_COVERAGE_UNKNOWN"),
                            output.replace(os.fsencode(self.home), b"/different-home")):
                with patch.object(DEPLOY, "command", return_value=invalid):
                    with self.assertRaisesRegex(ValueError, "visibility"):
                        self.deploy.check(self.data["config"], ROOT, self.home)
            with patch.object(DEPLOY, "command", side_effect=subprocess.CalledProcessError(30, [str(binary)])):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.deploy.check(self.data["config"], ROOT, self.home)
        self.assertEqual(self.snapshot(), before)
        binary.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "sudo mode"):
            self.deploy.check(self.data["config"], ROOT, self.home)
        protected = self.deploy.paths["sudoers"]
        protected.unlink()
        protected.write_bytes(self.bundle["sudoers"])
        protected.chmod(0o440)
        with self.assertRaisesRegex(ValueError, "file drift"):
            self.deploy.check(self.data["config"], ROOT, self.home)

    def test_initial_namespace_and_required_capability(self):
        proc = self.root / "proc"
        current = proc / str(os.getpid())
        peers = (proc / "1", current)
        with patch.object(os, "getpid", return_value=os.getpid()):
            for peer in peers:
                (peer / "ns").mkdir(parents=True, exist_ok=True)
                for name, link in self.policy["namespaces"].items():
                    (peer / "ns" / name).symlink_to(link)
            (proc / "self").symlink_to(current.name)
            (current / "status").write_text("CapPrm:\t0000000000080000\n")
            self.assertEqual(DEPLOY.namespace_policy(self.home, 1000, 1001, proc), self.policy)
            (current / "status").write_text("CapPrm:\t0000000000000000\n")
            with self.assertRaisesRegex(ValueError, "CAP_SYS_PTRACE"):
                DEPLOY.namespace_policy(self.home, 1000, 1001, proc)
            for peer in peers:
                (peer / "ns/pid").unlink()
                (peer / "ns/pid").symlink_to("pid:[511]")
            with self.assertRaisesRegex(ValueError, "host process coverage.*pid"):
                DEPLOY.namespace_policy(self.home, 1000, 1001, proc)

    def test_single_oracle_home_and_numeric_principal(self):
        home = Path(self.home)
        (home / "bin").mkdir(parents=True)
        (home / "bin/oracle").touch()
        oratab = self.root / "etc/oratab"
        oratab.write_text("SID:{}:N\nSID2:{}/:Y\n".format(home, home))
        account = SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
        with patch.object(DEPLOY, "namespace_policy", return_value=self.policy) as ns:
            self.assertEqual(DEPLOY.oracle_binding(self.home, oratab, account), self.policy)
            ns.assert_called_once_with(self.home, account.pw_uid, account.pw_gid)
        with oratab.open("a") as stream:
            stream.write("SID3:/other/home:N\n")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            DEPLOY.oracle_binding(self.home, oratab, account)
        with self.assertRaisesRegex(ValueError, "owner differs"):
            DEPLOY.oracle_binding(self.home, oratab, SimpleNamespace(pw_uid=os.getuid() + 1, pw_gid=os.getgid()))

    def test_existing_patch_lock_is_shared_without_writing_evidence(self):
        lock_root = self.root / "var/lock/opg"
        host = "server.example"
        with DEPLOY.patch_lock(lock_root, host, self.home, os.getuid(), os.getgid(), self.root):
            path = lock_root / (DEPLOY.sha((host + "|" + self.home).encode("ascii")) + ".lock")
            with path.open("r") as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path.write_bytes(b"synthetic run metadata\n")
        with path.open("a") as existing:
            fcntl.flock(existing, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                with DEPLOY.patch_lock(lock_root, host, self.home, os.getuid(), os.getgid(), self.root):
                    self.fail("active patch lock must not be acquired")
            self.assertEqual(path.read_bytes(), b"synthetic run metadata\n")
        self.assertEqual(path.read_bytes(), b"synthetic run metadata\n")

    def test_shared_bootstrap_gate_rejects_busy_and_stale_start(self):
        config = self.deploy.config
        config.parent.chmod(0o755)
        config.write_bytes(b"site config")
        snapshot = subprocess.check_output(["stat", "-c", "%d:%i:%s:%y:%z", str(config)]).strip()
        shell = '''
source "$1"
# Simulate the root ownership check while keeping the actual flock and stat.
stat() { if [[ $2 == '%u:%g:%a' ]]; then printf '0:0:755\\n'; else command stat "$@"; fi; }
opg_lock_current_config "$2" "$3"
'''
        args = ["bash", "-c", shell, "test", str(ROOT / "project/lib/opg_core.sh"), str(config),
                snapshot.decode("ascii")]
        fd = os.open(str(config.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(subprocess.call(args), 60)
        finally:
            os.close(fd)
        subprocess.check_call(args)
        config.write_bytes(b"new config")
        self.assertEqual(subprocess.call(args), 20)

    def test_sudoers_full_parser_validation_and_local_source_contract(self):
        visudo = shutil.which("visudo", path=DEPLOY.TOOLS["PATH"])
        if visudo is None:
            self.skipTest("visudo not installed")
        fixture = self.root / "etc/sudoers"
        admin = self.root / "etc/admin"
        candidate = self.deploy.paths["sudoers"]
        candidate.write_bytes(self.bundle["sudoers"])
        admin.write_text("Cmnd_Alias LOCAL_ADMIN = /bin/false\n")
        fixture.write_text("#include {}\n#include {}\n".format(admin, candidate))
        args = [visudo, "-cf", str(fixture)]
        valid = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        DEPLOY.require_sudoers_included(valid.stdout, [admin, candidate])
        admin.write_text("Cmnd_Alias OPG_ACTIVE_HOME_INSPECTION = /bin/false\n")
        conflicting = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(conflicting.returncode, 0)
        self.assertIn(b"OPG_ACTIVE_HOME_INSPECTION", conflicting.stderr)
        with self.assertRaisesRegex(ValueError, "fragment absent"):
            DEPLOY.require_sudoers_included(b"/etc/sudoers: parsed OK\n", [candidate])
        (self.root / "etc/nsswitch.conf").write_text("sudoers: files sss\n")
        with self.assertRaisesRegex(ValueError, "external sudoers"):
            DEPLOY.local_sudoers_sources(self.root / "etc")

    def test_sudoers_snapshot_substitutes_both_candidates_before_acting(self):
        sudoers = self.deploy.paths["sudoers"]
        context = self.deploy.paths["context"]
        other = sudoers.parent / "site"
        for path in (sudoers, context, other):
            path.write_bytes(b"existing effective policy\n")
        candidates = {sudoers: self.bundle["sudoers"], context: b"candidate context\n"}
        calls = []

        def validator(args, capture=False):
            calls.append(args[0])
            if args[0] == "unshare":
                self.assertTrue(capture)
                snapshot, target = args[-2:]
                self.assertEqual(target, sudoers.parent)
                self.assertEqual((snapshot / "site").read_bytes(), other.read_bytes())
                for path, data in candidates.items():
                    self.assertEqual((snapshot / path.name).read_bytes(), data)
                    self.assertEqual(path.read_bytes(), b"existing effective policy\n")
                raise subprocess.CalledProcessError(1, args)

        with patch.object(DEPLOY, "command", side_effect=validator):
            with self.assertRaises(subprocess.CalledProcessError):
                DEPLOY.validate_sudoers(self.deploy.paths, candidates, self.labels)
        self.assertEqual(calls, ["/usr/sbin/visudo", "unshare"])
        self.assertEqual(sudoers.read_bytes(), b"existing effective policy\n")
        self.assertEqual(context.read_bytes(), b"existing effective policy\n")

    def test_selinux_commands_and_label_failure_preserve_previous(self):
        context = b"system_u:object_r:etc_t:s0\n"
        with patch.object(DEPLOY, "command", side_effect=[b"Enforcing\n", context, None, context]) as cmd:
            DEPLOY.Labels().prepare("/synthetic-candidate", "/synthetic-target")
            cmd.assert_any_call(["matchpathcon", "-n", "-m", "file", "/synthetic-target"], capture=True)
            cmd.assert_any_call(["chcon", "--", context.decode("ascii").strip(), "/synthetic-candidate"])
        with patch.object(DEPLOY, "command", return_value=b"Permissive\n"):
            with self.assertRaisesRegex(ValueError, "permissive"):
                DEPLOY.Labels()
        self.publish_initial()
        before = self.snapshot()
        self.labels.prepare = lambda candidate, target: None
        with patch.object(self.labels, "verify", side_effect=OSError("label mismatch")):
            with self.assertRaisesRegex(OSError, "label mismatch"):
                self.deploy.activate(*self.candidate())
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
