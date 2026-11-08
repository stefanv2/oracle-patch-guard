#!/usr/bin/env python3
"""Synthetic, unprivileged tests; no Oracle or operational evidence."""
import contextlib
import errno
import hashlib
import io
import json
import subprocess
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    'media_engine', str(Path(__file__).resolve().parents[2] /
                        'oem-tasks/opg_media_stage_root.py'))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class SafePurgeTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() == 0:
            raise RuntimeError('Run without root privileges')
        self.temp = tempfile.TemporaryDirectory(prefix='opg-media-stage-tests.')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.env = mock.patch.dict(os.environ, {
            'OPG_MEDIA_TEST_MODE': '1', 'OPG_MEDIA_TEST_ROOT': str(self.base)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.local = self.base / 'u01/stage/oracle-patch-guard'
        self.local.mkdir(parents=True)
        (self.base / 'u01/stage').chmod(0o755)
        self.local.chmod(0o750)
        engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())
        self.quarantine = self.local / 'purging/JUL2026/fixture'
        self.child = self.quarantine / 'child'
        self.child.mkdir(parents=True)
        (self.child / 'sentinel').write_text('inside')
        self.outside = self.base / 'outside'
        self.outside.mkdir()
        (self.outside / 'sentinel').write_text('outside')

    def make_lifecycle(self):
        run = 'SYNTHETIC'
        identity = 'a' * 64
        stage = self.local / 'ready/JUL2026' / identity
        stage.parent.mkdir(parents=True)
        stage.parent.chmod(0o750)
        self.quarantine.rename(stage)
        (stage.parent / 'active_stage').write_text(identity + '\n')
        lock = self.local / '.locks'
        lock.mkdir(mode=0o750)
        lock.chmod(0o750)
        (lock / 'media-stage.lock').touch(mode=0o640)
        (lock / 'media-stage.lock').chmod(0o640)
        (self.base / 'context').mkdir(mode=0o750)
        run_dir = self.base / 'runs' / run
        approval_dir = self.base / 'approvals' / run
        for directory in (run_dir, approval_dir):
            directory.mkdir(parents=True)
            directory.parent.chmod(0o750)
            directory.chmod(0o750)
        private = self.base / 'synthetic-private.pem'
        public = self.base / 'public.pem'
        subprocess.check_call(['openssl', 'genpkey', '-algorithm', 'RSA',
                               '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(private)],
                              stderr=subprocess.DEVNULL)
        subprocess.check_call(['openssl', 'pkey', '-in', str(private),
                               '-pubout', '-out', str(public)], stderr=subprocess.DEVNULL)
        public.chmod(0o440)
        manifest = dict(run_id=run, hostname='fake.example.test',
                        target_oracle_home=str(self.base / 'fake-home'), month='JUL2026',
                        media_mode='LOCAL_IMMUTABLE_V2', local_stage_root=str(self.local),
                        local_media_identity=identity, artifact_manifest_sha256=identity,
                        approval_public_key_sha256=hashlib.sha256(public.read_bytes()).hexdigest())

        def write_json(path, data):
            raw = (json.dumps(data, sort_keys=True) + '\n').encode()
            path.write_bytes(raw)
            path.chmod(0o440)
            return hashlib.sha256(raw).hexdigest()

        manifest_hash = write_json(approval_dir / 'patch_manifest.json', manifest)
        write_json(run_dir / 'patch_manifest.json', manifest)
        approval = dict(approved=True, manifest_sha256=manifest_hash,
                        hostname=manifest['hostname'], target_oracle_home=manifest['target_oracle_home'],
                        expires_epoch=2000000000, manifest_signature_file='patch_manifest.sig',
                        approval_signature_file='approval.sig')
        approval_hash = write_json(approval_dir / 'approval.json', approval)
        state = dict(run_id=run, hostname=manifest['hostname'],
                     target_oracle_home=manifest['target_oracle_home'], state='12_COMPLETE',
                     phase='COMPLETE', exit_code=0, timestamp='2030-01-01T00:00:00Z')
        write_json(run_dir / 'execution_state.json', state)
        completion = dict(approval_sha256=approval_hash, completed_at=state['timestamp'],
                          completion_epoch=1893456000, exit_code=0, hostname=manifest['hostname'],
                          manifest_sha256=manifest_hash, patch_cycle='JUL2026', phase='COMPLETE',
                          run_id=run, schema_version=1, sid='FAKEDB', state='12_COMPLETE',
                          target_oracle_home=manifest['target_oracle_home'])
        write_json(approval_dir / 'completion.json', completion)
        (approval_dir / 'findings.psv').write_text('READY|SYNTHETIC|ok|fake\n')
        (approval_dir / 'findings.psv').chmod(0o440)
        for name in ('patch_manifest', 'approval'):
            signature = approval_dir / (name + '.sig')
            subprocess.check_call(['openssl', 'dgst', '-sha256', '-sign', str(private),
                                   '-out', str(signature), str(approval_dir / (name + '.json'))])
            signature.chmod(0o440)
        return run, stage, run_dir

    def test_lifecycle_partial_removal_and_resume(self):
        run, stage, run_dir = self.make_lifecycle()
        state_path = run_dir / 'execution_state.json'
        before = state_path.read_bytes()
        audit = self.base / 'context/stage-cleanup' / (run + '.json')
        intent = audit.parent / ('.' + run + '.intent.json')
        original_unlink = os.unlink
        removed = []

        def interrupt(path, *args, **kwargs):
            result = original_unlink(path, *args, **kwargs)
            if path == 'sentinel' and not removed:
                removed.append(True)
                raise OSError(errno.EIO, 'synthetic I/O failure', 'sentinel')
            return result

        # The fixture has synthetic signed completion; only artifact-stage
        # verification is stubbed because its payload is not Oracle media.
        with mock.patch.object(engine, 'verify_identity'), \
                mock.patch.object(os, 'unlink', interrupt), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as stopped:
                engine.purge_run(run)
        self.assertEqual(stopped.exception.code, engine.EXIT_UNKNOWN)
        self.assertIn('status=FAILED_RETAINED', output.getvalue())
        self.assertIn('errno=5', output.getvalue())
        self.assertIn('path=' + str(self.local / 'purging/JUL2026'), output.getvalue())
        self.assertIn('synthetic I/O failure', output.getvalue())
        self.assertTrue(removed)
        self.assertTrue(intent.exists())
        self.assertFalse(audit.exists())
        self.assertFalse((run_dir / 'stage_cleanup.json').exists())
        self.assertEqual(state_path.read_bytes(), before)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.purge_run(run)
        self.assertIn('status=PURGED', output.getvalue())
        record = json.loads(audit.read_text())
        binding = engine.validate_completion_for_run(run)
        for key in ('completion_sha256', 'manifest_sha256'):
            self.assertEqual(record[key], binding[key])
        self.assertEqual(record['cleanup_status'], 'PURGED')
        self.assertEqual(record, json.loads((run_dir / 'stage_cleanup.json').read_text()))
        self.assertFalse(intent.exists())
        self.assertFalse(stage.exists())
        self.assertEqual(state_path.read_bytes(), before)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            engine.purge_run(run)
        self.assertIn('status=ALREADY_PURGED', output.getvalue())
        self.assertEqual((self.outside / 'sentinel').read_text(), 'outside')

    def test_lifecycle_unsafe_parent_preserves_blocked(self):
        run, stage, run_dir = self.make_lifecycle()
        parent = self.local / 'purging'
        parent.chmod(0o770)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as stopped:
                engine.purge_run(run)
        self.assertEqual(stopped.exception.code, engine.EXIT_BLOCKED)
        self.assertIn('status=FAILED_RETAINED', output.getvalue())
        self.assertTrue(stage.exists())
        self.assertTrue((stage.parent / 'active_stage').exists())
        self.assertFalse((self.base / 'context/stage-cleanup').exists())

    def test_oracle_owned_u01_layout_is_accepted(self):
        ancestor = self.base / 'u01'
        ancestor.chmod(0o775)
        original = Path.lstat

        def oracle_owned(path):
            info = original(path)
            if path == ancestor:
                values = list(info)
                values[4] = 424242
                return os.stat_result(values)
            return info

        with mock.patch.object(Path, 'lstat', oracle_owned):
            engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())
        self.assertEqual(ancestor.stat().st_mode & 0o777, 0o775)

    def test_root_is_rejected_during_setup(self):
        case = SafePurgeTests('test_oracle_owned_u01_layout_is_accepted')
        with mock.patch.object(os, 'geteuid', return_value=0):
            with self.assertRaises(RuntimeError):
                case.setUp()
        self.assertFalse(hasattr(case, 'temp'))

    def test_setup_failure_restores_environment(self):
        before = dict(os.environ)
        case = SafePurgeTests('test_oracle_owned_u01_layout_is_accepted')
        with mock.patch.object(engine, 'prepare_purge_parents', side_effect=OSError('setup failure')):
            try:
                with self.assertRaises(OSError):
                    case.setUp()
            finally:
                case.doCleanups()
        self.assertEqual(dict(os.environ), before)
        self.assertFalse(case.base.exists())

    def test_acl_fixture_only_skips_proven_environment_limits(self):
        source = (Path(__file__).parent / 'run_pilot07_tests.sh').read_text()
        start = source.index("import errno, os, struct, sys", source.index('add_default_oracle_write_acl'))
        fixture = source[start:source.index('\nPY\n', start)]
        cases = [
            ('unmapped uid', '1000 0 1\n', None, None, 77),
            ('unsupported ACL', '0 0 4294967295\n', errno.ENOTSUP, None, 77),
            ('invalid ACL', '0 0 4294967295\n', errno.EINVAL, None, 1),
            ('permission failure', '0 0 4294967295\n', errno.EACCES, None, 1),
            ('readback failure', '0 0 4294967295\n', None, errno.ENOTSUP, 1),
        ]
        for name, mapping, write_errno, read_errno, expected in cases:
            with self.subTest(name=name), \
                    mock.patch('builtins.open', return_value=io.StringIO(mapping)), \
                    mock.patch.object(os, 'setxattr') as setter, \
                    mock.patch.object(os, 'getxattr') as getter, \
                    mock.patch('sys.argv', ['fixture', str(self.base / 'synthetic-acl')]), \
                    contextlib.redirect_stderr(io.StringIO()) as diagnostic:
                if write_errno is not None:
                    setter.side_effect = OSError(write_errno, name)
                if read_errno is not None:
                    getter.side_effect = OSError(read_errno, name)
                with self.assertRaises(SystemExit) as stopped:
                    exec(compile(fixture, '<synthetic ACL fixture>', 'exec'), {})
                self.assertEqual(stopped.exception.code, expected)
                self.assertTrue(diagnostic.getvalue())
                if name == 'unmapped uid':
                    setter.assert_not_called()
                    getter.assert_not_called()

    def test_acl_harness_skip_failure_and_success_are_distinct(self):
        source = (Path(__file__).parent / 'run_pilot07_tests.sh').read_text()
        start = source.index('check_oracle_acl() {')
        function = source[start:source.index('\n}\n', start) + 3]
        for fixture_rc, expected in ((77, '0 0 1'), (1, '0 1 0'), (0, '1 0 0')):
            script = """
PASS=0 FAIL=0 SKIP=0
add_default_oracle_write_acl() { return %d; }
verify() { return 20; }
record() { if [[ $2 == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }
%s
check_oracle_acl unused synthetic
printf 'COUNTS %%s %%s %%s\\n' "$PASS" "$FAIL" "$SKIP"
""" % (fixture_rc, function)
            result = subprocess.check_output(['bash', '-c', script]).decode()
            self.assertIn('COUNTS ' + expected, result)
            self.assertEqual('skip -' in result, fixture_rc == 77)

    def test_directory_swap_between_stat_and_open(self):
        original_open = os.open
        swapped = []

        def racing_open(path, flags, *args, **kwargs):
            if path == 'child' and kwargs.get('dir_fd') is not None and not swapped:
                self.child.rename(self.quarantine / 'saved')
                self.child.symlink_to(self.outside, target_is_directory=True)
                swapped.append(True)
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(os, 'open', racing_open):
            with self.assertRaises(OSError):
                engine.measured_safe_purge(self.quarantine)
        self.assertTrue(swapped)
        self.assertEqual((self.outside / 'sentinel').read_text(), 'outside')
        self.assertEqual((self.quarantine / 'saved/sentinel').read_text(), 'inside')

    def test_swap_after_open_keeps_descriptor_binding(self):
        original_open = os.open
        swapped = []

        def racing_open(path, flags, *args, **kwargs):
            fd = original_open(path, flags, *args, **kwargs)
            if path == 'child' and kwargs.get('dir_fd') is not None and not swapped:
                self.child.rename(self.quarantine / 'saved')
                self.child.symlink_to(self.outside, target_is_directory=True)
                swapped.append(True)
            return fd

        with mock.patch.object(os, 'open', racing_open):
            with self.assertRaises(OSError):
                engine.measured_safe_purge(self.quarantine)
        self.assertTrue(swapped)
        self.assertEqual((self.outside / 'sentinel').read_text(), 'outside')
        self.assertFalse((self.quarantine / 'saved/sentinel').exists())

    def test_missing_capability_attribute_is_rejected(self):
        with mock.patch.object(engine.shutil, 'rmtree', object()):
            with self.assertRaises(SystemExit) as stopped:
                engine.require_safe_rmtree()
            self.assertEqual(stopped.exception.code, engine.EXIT_UNKNOWN)

    def test_wrong_parent_owner_is_rejected(self):
        with mock.patch.object(engine, 'stage_security_ids',
                               return_value=(os.getuid() + 1, 424242, {os.getgid()})):
            with self.assertRaises(SystemExit):
                engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())

    def test_write_acl_is_rejected_without_repair(self):
        import struct
        acl = struct.pack('<IHHI', 2, 0x02, 2, 424242)
        with mock.patch.object(engine.os, 'getxattr', return_value=acl):
            with self.assertRaises(SystemExit):
                engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())

    def test_partial_removal_can_resume(self):
        original_unlink = os.unlink
        removed = []

        def interrupt(path, *args, **kwargs):
            result = original_unlink(path, *args, **kwargs)
            if path == 'sentinel' and not removed:
                removed.append(True)
                raise OSError('synthetic interruption after deletion')
            return result

        with mock.patch.object(os, 'unlink', interrupt):
            with self.assertRaises(OSError):
                engine.measured_safe_purge(self.quarantine)
        self.assertTrue(removed)
        engine.measured_safe_purge(self.quarantine)
        self.assertFalse(self.quarantine.exists())
        self.assertEqual((self.outside / 'sentinel').read_text(), 'outside')

    def test_missing_capability_precedes_lifecycle_changes(self):
        binding = {'stage': self.quarantine, 'cycle': 'JUL2026', 'identity': 'a' * 64}
        with mock.patch.object(shutil.rmtree, 'avoids_symlink_attacks', False), \
                mock.patch.object(engine, 'media_lock') as lock, \
                mock.patch.object(engine, 'lifecycle_roots', return_value=(self.base, self.base, self.base)), \
                mock.patch.object(engine, 'validate_completion_for_run', return_value=binding), \
                mock.patch.object(engine, 'other_run_needs_identity', return_value=None), \
                mock.patch.object(engine, 'write_audit') as audit, \
                mock.patch.object(engine, 'unlink_if_present') as unlink, \
                mock.patch.object(engine.os, 'rename') as rename:
            lock.return_value.__enter__.return_value = None
            with self.assertRaises(SystemExit) as stopped:
                engine.purge_run('SYNTHETIC')
            self.assertEqual(stopped.exception.code, engine.EXIT_UNKNOWN)
            audit.assert_not_called()
            unlink.assert_not_called()
            rename.assert_not_called()
        self.assertTrue(self.quarantine.exists())

    def test_unsafe_parent_is_not_repaired(self):
        parent = self.local / 'purging'
        parent.chmod(0o770)
        with self.assertRaises(SystemExit):
            engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())
        self.assertEqual(parent.stat().st_mode & 0o777, 0o770)

    def test_symlink_parent_is_rejected(self):
        parent = self.local / 'purging/JUL2026'
        parent.rename(self.local / 'purging/saved')
        parent.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(SystemExit):
            engine.prepare_purge_parents(self.local, 'JUL2026', os.getgid())
        self.assertEqual((self.outside / 'sentinel').read_text(), 'outside')


if __name__ == '__main__':
    unittest.main(verbosity=2)
