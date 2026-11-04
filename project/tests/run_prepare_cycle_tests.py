#!/usr/bin/env python3
"""Linux integration tests: real ZIPs, builder and OpenSSL signatures."""
import importlib.util
import os
from pathlib import Path
import shutil
import stat
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare', str(ROOT / 'signer/opg_prepare_cycle.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class OwnerTests(unittest.TestCase):
    root = Path('/mnt/datadomain/software/patches/Linux')

    def check(self, owner, mode=0o755, path=None, share=True, chain=None):
        path = path or self.root / 'OKT2026'
        def metadata(item):
            uid = owner if item == path or item == self.root else 0
            bits = mode if item == path else 0o750
            if chain and item in chain:
                uid, bits = chain[item]
            return SimpleNamespace(st_uid=uid, st_mode=bits if stat.S_IFMT(bits) else stat.S_IFDIR | bits)
        with mock.patch.object(m.os, 'geteuid', return_value=1234), \
                mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=5678)), \
                mock.patch.object(Path, 'lstat', metadata), mock.patch.object(Path, 'stat', metadata):
            return m.safe(path, directory=True, patch_root=self.root if share else None)

    def test_root_owner(self):
        self.check(0)

    def test_signer_owner(self):
        self.check(1234)

    def test_oracle_share_and_cycle(self):
        self.check(5678)
        self.check(5678, mode=0o750, path=self.root)

    def test_other_owner_blocked(self):
        with self.assertRaisesRegex(ValueError, 'untrusted owner'):
            self.check(9999)

    def test_oracle_writable_blocked(self):
        for mode in [0o775, 0o757]:
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'writable path'):
                self.check(5678, mode=mode)

    def test_symlink_blocked(self):
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.check(5678, mode=stat.S_IFLNK | 0o755)

    def test_secure_owner_stays_strict(self):
        for path in ['/secure/oracle-patch-guard', '/secure/oracle-patch-guard/approval_private.pem',
                     '/secure/oracle-patch-guard/approval_public.pem', '/secure/oracle-patch-guard/bin']:
            for share in [False, True]:
                with self.subTest(path=path, share=share), self.assertRaisesRegex(ValueError, 'untrusted owner'):
                    self.check(5678, path=Path(path), share=share)

    def test_oracle_parent_chain_allowed(self):
        self.check(5678, chain={self.root.parent: (5678, 0o750)})
        self.check(5678, mode=0o750, path=self.root,
                   chain={self.root.parent: (5678, 0o750)})

    def test_unsafe_patch_chain_blocked(self):
        for item in [self.root, self.root / 'OKT2026']:
            for uid, mode, reason in [(5678, 0o770, 'writable path'),
                                      (5678, 0o752, 'writable path'),
                                      (9999, 0o750, 'untrusted owner'),
                                      (5678, stat.S_IFLNK | 0o750, 'symlink')]:
                with self.subTest(item=item, uid=uid, mode=mode), self.assertRaisesRegex(ValueError, reason):
                    self.check(5678, chain={item: (uid, mode)})

    def test_trusted_writable_patch_ancestors_allowed(self):
        for uid in [0, 1234, 5678]:
            for mode in [0o770, 0o777]:
                with self.subTest(uid=uid, mode=mode):
                    self.check(5678, chain={p: (uid, mode) for p in self.root.parents})

    def test_unsafe_patch_ancestors_blocked(self):
        for item in self.root.parents:
            for uid, mode, reason in [(9999, 0o777, 'untrusted owner'),
                                      (5678, stat.S_IFLNK | 0o777, 'symlink'),
                                      (5678, stat.S_IFREG | 0o750, 'not a directory')]:
                with self.subTest(item=item, uid=uid, mode=mode), self.assertRaisesRegex(ValueError, reason):
                    self.check(5678, chain={item: (uid, mode)})

    def test_secure_writable_chain_blocked(self):
        path = Path('/secure/oracle-patch-guard/bin')
        for item in [path, path.parent, Path('/secure')]:
            for share in [False, True]:
                with self.subTest(item=item, share=share), self.assertRaisesRegex(ValueError, 'writable path'):
                    self.check(0, path=path, share=share, chain={item: (0, 0o777)})

    def test_patch_path_escape_blocked(self):
        with self.assertRaisesRegex(ValueError, 'unsafe patch path'):
            self.check(5678, path=self.root / '../elsewhere')

    def test_secure_root_signer_allowed(self):
        for uid in [0, 1234]:
            with self.subTest(uid=uid):
                self.check(uid, path=Path('/secure/oracle-patch-guard/bin'), share=False)

    def test_oracle_outside_share_blocked(self):
        with self.assertRaisesRegex(ValueError, 'untrusted owner'):
            self.check(5678, path=self.root.parent)


class CycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cycle = self.root / 'OKT2026'
        self.cycle.mkdir()
        (self.root / 'opatch').mkdir()
        self.conf = self.root / 'config'
        self.conf.mkdir()
        (self.conf / 'active_cycle').write_text('JUL2026\n')
        (self.conf / 'patchGD_guard.conf').write_text('OTHER=value\nOPATCH_ZIP_SHA256=' + '0' * 64 + '\n')
        self.key = self.root / 'private.pem'
        self.pub = self.root / 'public.pem'
        m.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(self.key)])
        m.run(['/usr/bin/openssl', 'pkey', '-in', str(self.key), '-pubout', '-out', str(self.pub)])
        self.builder = self.root / 'builder.py'
        shutil.copyfile(str(ROOT / 'oem-tasks/opg_build_artifact_manifest.py'), str(self.builder))
        self.db = self.cycle / 'p12345678_190000_Linux-x86-64.zip'
        self.oj = self.cycle / 'p87654321_190000_Linux-x86-64.zip'
        self.op = self.root / 'opatch/p6880880_190000_Linux-x86-64.zip'
        self.zip(self.db, '12345678/etc/config.xml', 'db')
        self.zip(self.oj, '87654321/etc/config.xml', 'ojvm')
        self.zip(self.op, 'OPatch/version.txt', 'OPATCH_VERSION: 12.2.0.1.52\n')
        self.args = m.argparse.Namespace(action='prepare', cycle='OKT2026', db_ru='12345678',
            ojvm='87654321', patch_root=self.root, config_dir=self.conf,
            private_key=self.key, public_key=self.pub, builder=self.builder)

    def zip(self, path, name, data):
        with zipfile.ZipFile(str(path), 'w') as archive:
            archive.writestr(name, data)

    def prepare(self):
        m.execute(self.args)

    def activate(self):
        self.args.action = 'activate'
        self.args.db_ru = self.args.ojvm = None
        m.execute(self.args)

    def test_prepare_activate_repeat(self):
        self.prepare()
        self.assertEqual((self.conf / 'active_cycle').read_text(), 'JUL2026\n')
        self.activate()
        self.activate()
        self.assertEqual((self.conf / 'active_cycle').read_text(), 'OKT2026\n')
        self.assertIn(m.sha(self.op), (self.conf / 'patchGD_guard.conf').read_text())

    def test_repeat_prepare_refused(self):
        self.prepare()
        before = (self.cycle / 'artifact_manifest.json').read_bytes()
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(before, (self.cycle / 'artifact_manifest.json').read_bytes())

    def test_existing_partial(self):
        (self.cycle / 'opg_cycle.conf').write_text('existing')
        with self.assertRaises(ValueError): self.prepare()

    def test_missing_media(self):
        self.db.unlink()
        with self.assertRaises(FileNotFoundError): self.prepare()

    def test_wrong_zip(self):
        self.zip(self.db, '99999999/file', 'wrong')
        with self.assertRaises(ValueError): self.prepare()

    def test_bad_version(self):
        self.zip(self.op, 'OPatch/version.txt', 'bogus')
        with self.assertRaises(ValueError): self.prepare()

    def test_changed_hash(self):
        self.prepare()
        self.zip(self.db, '12345678/file', 'changed')
        with self.assertRaises(ValueError): self.activate()

    def test_changed_version(self):
        self.prepare()
        self.zip(self.op, 'OPatch/version.txt', 'OPATCH_VERSION: 12.2.0.1.51')
        with self.assertRaises(ValueError): self.activate()

    def test_signature(self):
        self.prepare()
        path = self.cycle / 'artifact_manifest.sig'
        path.chmod(0o600)
        path.write_bytes(b'invalid')
        with self.assertRaises(ValueError): self.activate()

    def test_config_mismatch(self):
        self.prepare()
        path = self.cycle / 'opg_cycle.conf'
        path.chmod(0o600)
        path.write_text(path.read_text().replace('12.2.0.1.52', '12.2.0.1.51'))
        with self.assertRaises(ValueError): self.activate()

    def test_unsafe_mode(self):
        self.db.chmod(0o666)
        with self.assertRaises(ValueError): self.prepare()

    def test_symlink(self):
        self.db.unlink()
        self.db.symlink_to(self.oj)
        with self.assertRaises(ValueError): self.prepare()

    def test_without_preparation(self):
        with self.assertRaises(FileNotFoundError): self.activate()

    def test_missing_receipt(self):
        self.prepare()
        (self.cycle / '.opg-prepared').unlink()
        with self.assertRaises(FileNotFoundError): self.activate()

    def test_partial_write_rollback(self):
        self.prepare()
        active = (self.conf / 'active_cycle').read_bytes()
        runtime = (self.conf / 'patchGD_guard.conf').read_bytes()
        original = m.atomic
        def failing(path, data, existing=False, patch_root=None):
            if path.name == 'active_cycle' and data == b'OKT2026\n':
                raise OSError('injected write failure')
            original(path, data, existing, patch_root=patch_root)
        with mock.patch.object(m, 'atomic', side_effect=failing):
            with self.assertRaises(OSError): self.activate()
        self.assertEqual((self.conf / 'active_cycle').read_bytes(), active)
        self.assertEqual((self.conf / 'patchGD_guard.conf').read_bytes(), runtime)

    def test_preserve_metadata(self):
        self.prepare()
        paths = [self.conf / 'active_cycle', self.conf / 'patchGD_guard.conf']
        for path in paths: path.chmod(0o640)
        before = [(p.stat().st_uid, p.stat().st_gid, p.stat().st_mode) for p in paths]
        self.activate()
        self.assertEqual(before, [(p.stat().st_uid, p.stat().st_gid, p.stat().st_mode) for p in paths])

    def test_prepare_verification_failure_no_publication(self):
        other = self.root / 'other.pem'
        m.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(other)])
        m.run(['/usr/bin/openssl', 'pkey', '-in', str(other), '-pubout', '-out', str(self.pub)])
        with self.assertRaises(ValueError): self.prepare()
        self.assertFalse((self.cycle / 'artifact_manifest.json').exists())
        self.assertFalse((self.cycle / '.opg-prepared').exists())

    def test_invalid_id(self):
        self.args.db_ru = '../12345678'
        with self.assertRaises(ValueError): self.prepare()

    def test_oracle_owned_media_prepare_activate(self):
        original = Path.lstat
        signer = tempfile.TemporaryDirectory()
        self.addCleanup(signer.cleanup)
        for attribute in ['private_key', 'public_key', 'builder']:
            old = getattr(self.args, attribute)
            new = Path(signer.name) / old.name
            shutil.copyfile(str(old), str(new))
            new.chmod(0o600)
            setattr(self.args, attribute, new)
        def oracle_metadata(path):
            info = original(path)
            if path == self.root or self.root in path.parents:
                values = list(info)
                values[4] = 5678
                return os.stat_result(values)
            return info
        with mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=5678)), \
                mock.patch.object(Path, 'lstat', oracle_metadata):
            self.prepare()
            self.activate()
        self.assertEqual((self.conf / 'active_cycle').read_text(), 'OKT2026\n')

    def test_cli_key_defaults_and_overrides(self):
        for action in ['prepare', 'activate']:
            for override in [False, True]:
                with self.subTest(action=action, override=override):
                    argv = ['opg_prepare_cycle.py', action, 'OKT2026']
                    if override:
                        argv.extend(['--private-key', str(self.key), '--public-key', str(self.pub)])
                    with mock.patch.object(m.sys, 'argv', argv), mock.patch.object(m, 'execute') as execute:
                        self.assertEqual(m.main(), 0)
                    args = execute.call_args[0][0]
                    self.assertEqual(args.private_key, self.key if override else
                                     Path('/secure/oracle-patch-guard/approval_private.pem'))
                    self.assertEqual(args.public_key, self.pub if override else
                                     Path('/secure/oracle-patch-guard/approval_public.pem'))

    def test_cli(self):
        for name in ['opg_prepare_cycle.sh', 'opg_prepare_cycle.py']:
            shutil.copyfile(str(ROOT / 'signer' / name), str(self.root / name))
        options = ['--patch-root', str(self.root), '--config-dir', str(self.conf),
                   '--private-key', str(self.key), '--public-key', str(self.pub),
                   '--builder', str(self.builder)]
        command = ['/bin/bash', str(self.root / 'opg_prepare_cycle.sh')]
        prepared = subprocess.run(command + ['prepare', 'OKT2026', '--db-ru', '12345678',
                                  '--ojvm', '87654321'] + options, stdout=subprocess.PIPE)
        self.assertEqual(prepared.returncode, 0)
        self.assertIn(b'status=READY_TO_ACTIVATE', prepared.stdout)
        activated = subprocess.run(command + ['activate', 'OKT2026'] + options, stdout=subprocess.PIPE)
        self.assertEqual(activated.returncode, 0)
        self.assertIn(b'status=ACTIVE', activated.stdout)
        invalid = subprocess.run(command + ['activate', '../BAD'] + options,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(invalid.returncode, 20)
        self.assertIn(b'status=BLOCKED', invalid.stdout)


if __name__ == '__main__':
    unittest.main()
