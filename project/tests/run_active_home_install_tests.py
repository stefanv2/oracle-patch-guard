#!/usr/bin/env python3
"""Unprivileged tests for the opt-in Active Home installer."""

import contextlib
import hashlib
from importlib import util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "oem-tasks/opg_install_active_home.py"
SPEC = util.spec_from_file_location("installer", ENTRY)
installer = util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(installer)
TEMPLATE = (ROOT / "config/examples/oracle-patch-guard-active-home.sudoers").read_bytes()


def root_metadata(info):
    fields = list(info)
    fields[4:6] = [0, 0]
    return os.stat_result(fields)


def namespace_link(path):
    if path == "/proc/self":
        return str(os.getpid())
    name = path.rsplit("/", 1)[1]
    return installer.INITIAL_NAMESPACES.get(name, "mnt:[123]")


@unittest.skipIf(os.getuid() == 0, "installer fixtures are intended to run unprivileged")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        self.base = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="opg-active-home-install.")))
        self.config = self.base / "config"
        self.config.mkdir()
        self.launcher = self.base / "launcher"
        self.scanner_dir = self.base / "libexec/guard"
        scanner = (ROOT / "project/lib/opg_active_home.py").read_bytes()
        self.digest = hashlib.sha256(scanner).hexdigest()
        self.scanner = self.scanner_dir / ("opg_active_home-" + self.digest + ".py")
        sudoers_dir = self.base / "sudoers.d"
        sudoers_dir.mkdir()
        self.sudoers = sudoers_dir / "oracle-patch-guard-active-home"
        self.policy = self.config / "active-home-inspect.json"
        self.sudo = self.base / "sudo"
        self.sudo.touch(mode=0o700)
        self.sudo.chmod(0o4111)
        self.visudo = self.base / "visudo"
        self.visudo.touch(mode=0o700)
        self.home = self.base / "dbhome"
        self.home.mkdir()
        stack.enter_context(patch.multiple(installer, CONFIG_DIR=self.config, LAUNCHER=self.launcher,
                                          SCANNER_DIR=self.scanner_dir, SUDOERS=self.sudoers, SUDO=self.sudo,
                                          VISUDO=self.visudo))
        stack.enter_context(patch.object(installer, "require_directory_chain"))
        require_file = installer.require_file
        stack.enter_context(patch.object(installer, "require_file", side_effect=lambda info, *args, **kwargs:
                                          require_file(root_metadata(info), *args, **kwargs)))
        stack.enter_context(patch.object(installer.os, "fchown"))
        self.labels = Mock()
        stack.enter_context(patch.object(installer, "SELinuxLabels", return_value=self.labels))
        account = SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid() or 1000)
        stack.enter_context(patch.object(installer.pwd, "getpwnam", return_value=account))
        stack.enter_context(patch.object(installer, "readlink", side_effect=namespace_link))

    def install(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            installer.deploy(ROOT, "oracle_test", str(self.home))
        return output.getvalue()

    def test_install_is_idempotent_and_uses_only_the_bounded_sudoers_rule(self):
        published = (self.scanner, self.launcher, self.policy, self.sudoers)

        def check_candidate(candidate, labels):
            self.assertIs(labels, self.labels)
            self.assertEqual(stat.S_IMODE(candidate.stat().st_mode), 0o440)
            self.assertEqual(candidate.read_bytes(), TEMPLATE.replace(b"\noracle ALL=", b"\noracle_test ALL="))

        with patch.object(installer, "validate_sudoers", side_effect=check_candidate) as validate:
            self.assertEqual(self.install().count("|INSTALLED|"), 4)
            inodes = [path.stat().st_ino for path in published]
            self.assertEqual(self.install().count("|UNCHANGED|"), 4)
        self.assertEqual(validate.call_count, 4)
        self.assertEqual([path.stat().st_ino for path in published], inodes)
        self.assertEqual([stat.S_IMODE(path.stat().st_mode) for path in published], [0o644, 0o755, 0o400, 0o440])
        self.assertEqual(self.scanner.read_bytes(), (ROOT / "project/lib/opg_active_home.py").read_bytes())
        policy = json.loads(self.policy.read_text())
        self.assertEqual(policy["scanner_sha256"], self.digest)
        self.assertIn('DEPLOYMENT_ID = "{}"'.format(policy["deployment_id"]), self.launcher.read_text())
        self.assertIn('SCANNER_SHA256 = "{}"'.format(self.digest), self.launcher.read_text())
        self.assertEqual(policy["oracle_home"], str(self.home))
        self.assertEqual(policy["uid"], os.getuid())
        self.assertEqual(policy["gid"], os.getgid() or 1000)
        self.assertEqual(policy["namespaces"], {name: namespace_link("/proc/1/ns/" + name) for name in installer.NAMESPACES})

    def test_refuses_unsafe_existing_permissions_before_publication(self):
        for path in (self.launcher, self.policy, self.sudoers):
            with self.subTest(path=path):
                path.write_text("fixture\n")
                path.chmod(0o666)
                with patch.object(installer, "validate_sudoers") as validate, self.assertRaises(PermissionError):
                    self.install()
                validate.assert_not_called()
                self.assertEqual(path.read_text(), "fixture\n")
                self.assertFalse(self.scanner.exists())
                path.unlink()

    def test_refuses_symlink_even_if_its_target_is_absent(self):
        self.sudoers.symlink_to(self.base / "absent")
        with patch.object(installer, "validate_sudoers") as validate, self.assertRaises(PermissionError):
            self.install()
        validate.assert_not_called()
        self.assertTrue(self.sudoers.is_symlink())
        self.assertFalse(self.scanner.exists())

    def test_invalid_sudoers_candidate_prevents_publication(self):
        with patch.object(installer, "validate_sudoers", side_effect=subprocess.CalledProcessError(1, "visudo")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.install()
        self.assertTrue(all(not path.exists() for path in (self.launcher, self.policy, self.scanner, self.sudoers)))
        self.assertFalse(list(self.base.rglob(".opg-active-home-*")))

    def test_accepts_both_packaged_sudo_modes_only(self):
        with patch.object(installer, "validate_sudoers"):
            self.sudo.chmod(0o4755)
            self.assertEqual(self.install().count("|INSTALLED|"), 4)
            self.sudo.chmod(0o755)
            with self.assertRaises(PermissionError):
                self.install()

    def test_refuses_untrusted_namespace_and_wrong_home_owner(self):
        with patch.object(installer, "readlink", side_effect=lambda path:
                          "pid:[999]" if path.endswith("/ns/pid") else namespace_link(path)):
            with self.assertRaises(PermissionError):
                self.install()
        with patch.object(installer.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=424242, pw_gid=1)):
            with self.assertRaises(ValueError):
                self.install()
        self.assertFalse(self.policy.exists())

    def test_refuses_username_with_sudoers_syntax(self):
        with self.assertRaises(ValueError):
            installer.policy_for("oracle,ALL", str(self.home), "a" * 64, self.digest)

    def test_interrupted_install_reflushes_unchanged_scanner_and_preserves_legacy(self):
        self.scanner_dir.mkdir(parents=True)
        legacy = self.scanner_dir / "opg_active_home.py"
        legacy.write_bytes(b"previous scanner")
        real_sync = installer.sync_directory

        def fail_after_scanner(path):
            if path == self.scanner_dir and self.scanner.exists():
                raise OSError("fixture flush error")
            real_sync(path)

        with patch.object(installer, "validate_sudoers"), patch.object(installer, "sync_directory", side_effect=fail_after_scanner):
            with self.assertRaises(OSError):
                self.install()
        self.assertTrue(self.scanner.exists())
        self.assertFalse(self.sudoers.exists())
        with patch.object(installer, "validate_sudoers"), patch.object(installer, "sync_directory", wraps=real_sync) as sync:
            self.assertIn("|UNCHANGED|" + str(self.scanner), self.install())
        sync.assert_any_call(self.scanner_dir)
        self.assertEqual(legacy.read_bytes(), b"previous scanner")

    def test_second_full_policy_validation_failure_keeps_previous_policy(self):
        self.sudoers.write_bytes(b"previous policy\n")
        self.sudoers.chmod(0o440)
        with patch.object(installer, "validate_sudoers", side_effect=[None, ValueError("duplicate alias")]):
            with self.assertRaises(ValueError):
                self.install()
        self.assertEqual(self.sudoers.read_bytes(), b"previous policy\n")
        self.assertTrue(self.launcher.exists())

    def test_failed_sudoers_commit_flush_restores_active_policy(self):
        self.sudoers.write_bytes(b"previous policy\n")
        self.sudoers.chmod(0o440)
        with patch.object(installer, "validate_sudoers"), patch.object(installer, "sync_directory") as sync:
            def fail_when_activated(path):
                if path == self.sudoers.parent and self.sudoers.read_bytes() != b"previous policy\n":
                    raise OSError("fixture commit flush error")
            sync.side_effect = fail_when_activated
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(self.sudoers.read_bytes(), b"previous policy\n")

    def test_failed_sudoers_restore_retains_the_previous_bytes_for_recovery(self):
        self.sudoers.write_bytes(b"previous policy\n")
        self.sudoers.chmod(0o440)
        real_replace = os.replace
        def fail_restore(source, destination):
            if Path(destination) == self.sudoers and Path(source).read_bytes() == b"previous policy\n":
                raise OSError("fixture restore error")
            real_replace(source, destination)
        def fail_commit(path):
            if path == self.sudoers.parent and self.sudoers.read_bytes() != b"previous policy\n":
                raise OSError("fixture commit flush error")
        with patch.object(installer, "validate_sudoers"), patch.object(installer, "sync_directory", side_effect=fail_commit), \
                patch.object(installer.os, "replace", side_effect=fail_restore):
            with self.assertRaisesRegex(OSError, "restoration could not be confirmed"):
                self.install()
        backups = list(self.sudoers.parent.glob(".opg-active-home-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b"previous policy\n")
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o440)

    def test_failed_selinux_staging_prevents_publication(self):
        self.labels.prepare.side_effect = PermissionError("fixture label denied")
        with patch.object(installer, "validate_sudoers") as validate, self.assertRaises(PermissionError):
            self.install()
        validate.assert_not_called()
        self.assertFalse(self.launcher.exists())
        self.assertFalse(self.sudoers.exists())

    def test_each_published_inode_was_labelled_while_staged(self):
        labelled = {}
        def label(candidate, destination, file_type):
            if file_type == stat.S_IFREG:
                labelled.setdefault(destination, set()).add(candidate.stat().st_ino)
        self.labels.prepare.side_effect = label
        real_replace = os.replace
        def publish(candidate, destination):
            self.assertIn(Path(candidate).stat().st_ino, labelled[Path(destination)])
            real_replace(candidate, destination)
        with patch.object(installer, "validate_sudoers"), patch.object(installer.os, "replace", side_effect=publish):
            self.assertEqual(self.install().count("|INSTALLED|"), 4)

    def test_refuses_external_sudoers_source_and_custom_plugin_path(self):
        nss = self.base / "nsswitch.conf"
        sudo_conf = self.base / "sudo.conf"
        with patch.multiple(installer, NSSWITCH=nss, SUDO_CONF=sudo_conf):
            nss.write_bytes(b"sudoers: files sss\n")
            with self.assertRaisesRegex(ValueError, "external sudoers"):
                installer.local_sudoers_source()
            nss.write_bytes(b"sudoers: files\n")
            sudo_conf.write_bytes(b"Path plugin_dir /site/custom\n")
            with self.assertRaisesRegex(ValueError, "plugin directory"):
                installer.local_sudoers_source()
            sudo_conf.write_bytes(b"Plugin sudoers_policy sudoers.so\n")
            installer.local_sudoers_source()

    @unittest.skipUnless(Path("/usr/sbin/visudo").is_file(), "visudo needed for synthetic policy parser test")
    def test_full_policy_parser_rejects_alias_collision_and_requires_inclusion(self):
        previous = self.sudoers.parent / "other-site-policy"
        candidate = self.sudoers.parent / ".opg-active-home-candidate"
        previous.write_bytes(TEMPLATE)
        previous.chmod(0o440)
        candidate.write_bytes(TEMPLATE)
        candidate.chmod(0o440)
        main_policy = self.base / "sudoers-main"
        real_run = subprocess.run

        def parse_fixture(args, **kwargs):
            if args[0] != "/usr/bin/unshare":
                return None  # The real host policy is never read by this test.
            self.assertEqual(args[1:4], ["--mount", "/bin/sh", "-ec"])
            self.assertTrue(args[4].startswith("mount --make-rprivate /;"))
            snapshot = Path(args[6])
            self.assertEqual((snapshot / self.sudoers.name).read_bytes(), TEMPLATE)
            # Unprivileged visudo skips includedir directories that are not root-owned.
            main_policy.write_text("".join("#include {}\n".format(path) for path in sorted(snapshot.iterdir())))
            real_run(["/usr/sbin/visudo", "-cf", str(main_policy)], check=True,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return subprocess.CompletedProcess(args, 0, b"")  # Missing candidate proof after syntax validation.

        with patch.object(installer, "local_sudoers_source"), patch.object(installer.subprocess, "run", side_effect=parse_fixture):
            with self.assertRaises(subprocess.CalledProcessError):
                installer.validate_sudoers(candidate, self.labels)
            previous.unlink()
            with self.assertRaisesRegex(ValueError, "not included"):
                installer.validate_sudoers(candidate, self.labels)
        self.assertFalse(self.sudoers.exists())


class MetadataTests(unittest.TestCase):
    def test_file_owner_group_mode_and_link_count_are_required(self):
        path = Path("/fixture/policy")
        for uid, gid, mode, links in ((1000, 0, 0o400, 1), (0, 1000, 0o400, 1),
                                       (0, 0, 0o440, 1), (0, 0, 0o400, 2)):
            with self.subTest(uid=uid, gid=gid, mode=mode, links=links), self.assertRaises(PermissionError):
                installer.require_file(SimpleNamespace(st_uid=uid, st_gid=gid, st_nlink=links,
                                                        st_mode=stat.S_IFREG | mode), path, (0o400,))

    def test_group_writable_and_symlink_directories_are_rejected(self):
        safe = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        for unsafe in (stat.S_IFDIR | 0o775, stat.S_IFLNK | 0o755):
            with self.subTest(unsafe=unsafe), patch.object(Path, "lstat", side_effect=[safe, SimpleNamespace(st_uid=0, st_mode=unsafe)]):
                with self.assertRaises(PermissionError):
                    installer.require_directory_chain(Path("/fixture"))

    @unittest.skipUnless(os.getuid() != 0, "requires an unprivileged test process")
    def test_cli_refuses_unprivileged_entry_before_accessing_host_paths(self):
        result = subprocess.run([sys.executable, "-IBS", str(ENTRY), "--oracle-user", "oracle",
                                 "--oracle-home", "/fixture/dbhome"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 30)
        self.assertIn(b"run as a host administrator", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
