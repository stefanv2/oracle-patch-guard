#!/usr/bin/env python3
"""Offline contract tests; never contact an OEM Agent."""
import importlib.util
import pathlib
import tempfile
import unittest
import json
import time
import subprocess
import sys
from unittest.mock import patch

FOREIGN = '''Blackoutname = automatic_patching_OPG
Targets = (SYSBACKGROUND_10:oracle_dbservice,LISTENER_sv2210620.frd.shsdir.nl:oracle_listener,d001pcdb_d000001p:oracle_pdb,OraDB19Home1_1_sv2210620.frd.shsdir.nl_7:oracle_home,d000001p:oracle_dbservice,d001pcdb.frd.shsdir.nl:oracle_dbservice,d001pcdb:oracle_database,SYSUSERS_10:oracle_dbservice,d001pcdbXDB:oracle_dbservice,d001pcdb_CDBROOT:oracle_pdb,)
Time = ({2026-08-31|11:09:47,|} )
Expired = False
'''
OWN = '''Blackoutname = OPG_TEST_d001pcdb_20260911
Targets = (d001pcdb:oracle_database,)
Time = ({2026-09-11|15:08:01|5 Min,|} )
Expired = False
'''

MODULE = pathlib.Path(__file__).resolve().parents[2] / 'oem-tasks/opg_blackout.py'
spec = importlib.util.spec_from_file_location('blackout', MODULE)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class Contracts(unittest.TestCase):
    def test_actual_134_during_after(self):
        during = b.blackouts(FOREIGN + '\n' + OWN)
        self.assertEqual(len(during), 2)
        self.assertEqual(len(b.blackouts(FOREIGN)), 1)
        self.assertEqual(during[1]['targets'], ['d001pcdb:oracle_database'])

    def test_disabled_default(self):
        self.assertEqual(b.mode({}), 'disabled')
        self.assertEqual(b.mode({'OEM_BLACKOUT_MODE':'required'}), 'required')
        with self.assertRaises(b.Failure): b.mode({'OEM_BLACKOUT_MODE':'yes'})

    def test_agent_binary_checks(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'bin' / 'emctl'
            p.parent.mkdir()
            with self.assertRaises(b.Failure): b.Agent(str(p), 'host', '/db')
            p.write_text('dummy')
            p.chmod(0o600)
            with self.assertRaises(b.Failure): b.Agent(str(p), 'host', '/db')
            p.chmod(0o700)
            agent = b.Agent(str(p), 'host', '/db')
            for args in [('status','agent'),('config','agent','listtargets')]:
                with patch.object(b.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'error')):
                    with self.assertRaises(b.Failure): agent.call(*args)
            with patch.object(b.subprocess, 'run', side_effect=subprocess.TimeoutExpired('emctl',45)):
                with self.assertRaises(b.Failure): agent.call('status','agent')

    def test_group_writable_parent_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'bin' / 'emctl'
            p.parent.mkdir(mode=0o775)
            p.parent.chmod(0o775)
            p.write_text('dummy')
            p.chmod(0o700)
            self.assertEqual(b.Agent(str(p), 'h', '/db').path, str(p))

    def test_agent_home_mismatch(self):
        agent = object.__new__(b.Agent)
        agent.path = '/agent/bin/emctl'
        with patch.object(agent, 'call', return_value='Agent is Running and Ready\nAgent Home : /other\n'):
            with self.assertRaises(b.Failure): agent.healthy()

    def test_inventory(self):
        self.assertEqual(b.resolve('[db, oracle_database]\n[p, oracle_pdb]', 'db', 'h'), 'db')
        for text, reason in [('[p, oracle_pdb]', 'TARGET_NOT_FOUND'),
                             ('[db, oracle_database]\n[db, oracle_database]', 'TARGET_NOT_UNIQUE'),
                             ('[db oracle_database]', 'AGENT_TARGET_LIST_INVALID')]:
            with self.assertRaises(b.Failure) as e:
                b.resolve(text, 'db', 'h')
            self.assertEqual(e.exception.reason, reason)

    def test_duration(self):
        self.assertEqual(b.duration('00:05'), 300)
        for value in ['0', '-1:00', '03:60', '99:00', '$(id)']:
            with self.assertRaises(b.Failure): b.duration(value)

    def test_json(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'state.json'
            p.write_text('{"run_id":"a","run_id":"b"}')
            with self.assertRaises(b.Failure): b.read_json(p)
            p.write_text('{')
            with self.assertRaises(b.Failure): b.read_json(p)
            p.unlink()
            p.symlink_to(pathlib.Path(d) / 'other')
            with self.assertRaises(b.Failure): b.read_json(p)

    def test_atomic(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'state.json'
            b.write_json(p, {'status':'PREPARED'})
            self.assertEqual(b.read_json(p)['status'], 'PREPARED')
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_unconfirmed_status(self):
        # No permissive grep for a target/name or success exit code.
        for text in ['', 'db OPG_run active', 'Expired = False', 'error']:
            with self.assertRaises(b.Failure): b.blackouts(text)


class FakeAgent:
    def __init__(self, path, binding):
        self.path, self.binding = path, binding
        self.records, self.calls = [], []
        self.timeout = False
        self.unavailable = False

    def status(self, target):
        if self.unavailable: raise b.Failure('AGENT_UNAVAILABLE', 30)
        return self.records

    def call(self, *args):
        self.calls.append(args)
        state = b.read_json(self.path)
        if args[0] == 'start':
            assert state['status'] == 'PREPARED', 'external START before durable intent'
            self.records = [dict(name=self.binding['blackout_name'], targets=['db:oracle_database'], expired=False,
                                 started=state['requested_at'], seconds=b.duration(state['requested_duration']))]
        else:
            assert state['status'] == 'STOPPING'
            self.records = [r for r in self.records if r['name'] != args[2]]
        if self.timeout: raise b.Failure('AGENT_UNAVAILABLE', 30)


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = pathlib.Path(self.tmp.name) / 'run' / 'blackout_state.json'
        self.path.parent.mkdir(mode=0o700)
        self.binding = dict(run_id='run', host='h', sid='db', oracle_home='/db',
                            agent_emctl='/agent/bin/emctl', target='db',
                            target_type='oracle_database', blackout_name='OPG_run')
        self.agent = FakeAgent(self.path, self.binding)

    def op(self, action):
        return b.operate(action, self.path, self.binding, self.agent, '03:00', 60)

    def test_start_retry_guard_stop_retry(self):
        self.assertEqual(self.op('start'), 'STARTED')
        self.assertEqual(self.op('start'), 'ALREADY_STARTED')
        self.assertEqual(self.op('guard'), 'READY')
        self.assertEqual(self.op('stop'), 'STOPPED')
        self.assertEqual(self.op('stop'), 'ALREADY_STOPPED')
        self.assertEqual([c[0] for c in self.agent.calls], ['start','stop'])

    def test_timeout_reconciled(self):
        self.agent.timeout = True
        self.assertEqual(self.op('start'), 'STARTED')
        self.assertEqual(self.op('stop'), 'STOPPED')

    def test_missing_guard(self):
        with self.assertRaises(b.Failure): self.op('guard')
        self.assertFalse(self.agent.calls)

    def test_binding_mismatch(self):
        self.op('start')
        self.binding['run_id'] = 'different'
        for action in ('guard', 'start', 'stop'):
            with self.assertRaises(b.Failure): self.op(action)
        self.assertEqual(len(self.agent.calls), 1)

    def test_expired_guard(self):
        self.op('start')
        self.agent.records[0]['expired'] = True
        with self.assertRaises(b.Failure): self.op('guard')
        self.assertEqual(self.op('stop'), 'EXPIRED')

    def test_insufficient_duration(self):
        self.op('start')
        state = b.read_json(self.path)
        state['requested_at'] = int(time.time()) - 10790
        self.agent.records[0]['started'] = state['requested_at']
        b.write_json(self.path, state)
        with self.assertRaises(b.Failure) as error: self.op('guard')
        self.assertEqual(error.exception.reason, 'BLACKOUT_DURATION_INSUFFICIENT')
        self.assertEqual(error.exception.code, 20)

    def test_five_minutes_rejected_before_start_and_state(self):
        with self.assertRaises(b.Failure) as error:
            b.operate('start', self.path, self.binding, self.agent, '00:05', 300)
        self.assertEqual((error.exception.reason, error.exception.code),
                         ('BLACKOUT_DURATION_INSUFFICIENT', 20))
        self.assertFalse(self.path.exists())
        self.assertFalse(self.agent.calls)
        self.assertFalse(self.agent.records)

    def test_five_minutes_with_sixty_second_minimum(self):
        self.assertEqual(b.operate('start', self.path, self.binding, self.agent, '00:05', 60), 'STARTED')

    def test_foreign_not_adopted(self):
        self.agent.records = [dict(name='someone_else', targets=['db:oracle_database'], expired=False)]
        with self.assertRaises(b.Failure): self.op('start')
        self.assertFalse(self.agent.calls)

    def test_stop_preserves_foreign(self):
        self.op('start')
        self.agent.records.append(dict(name='someone_else', targets=['db:oracle_database'], expired=False))
        self.op('stop')
        self.assertEqual(self.agent.records[0]['name'], 'someone_else')

    def test_unknown_own_name_not_adopted(self):
        self.agent.records = [dict(name='OPG_run', targets=['db:oracle_database'], expired=False, started=int(time.time()), seconds=10800)]
        with self.assertRaises(b.Failure): self.op('start')
        self.assertFalse(self.path.exists())

    def test_crash_after_external_start(self):
        original = b.write_json
        def crash(path, data):
            if data['status'] == 'STARTED': raise b.Failure('BLACKOUT_STATE_WRITE_FAILED', 30)
            original(path, data)
        with patch.object(b, 'write_json', crash):
            with self.assertRaises(b.Failure): self.op('start')
        self.assertEqual(b.read_json(self.path)['status'], 'PREPARED')
        self.assertEqual(self.op('start'), 'ALREADY_STARTED')
        self.assertEqual(len(self.agent.calls), 1)

    def test_agent_unavailable(self):
        self.op('start')
        self.agent.unavailable = True
        for action in ('guard','stop'):
            with self.assertRaises(b.Failure): self.op(action)

    def test_stop_main_ignores_start_settings(self):
        for key in ('OEM_BLACKOUT_MODE', 'OEM_BLACKOUT_DURATION', 'OEM_BLACKOUT_MIN_REMAINING_SECONDS'):
            with self.subTest(key=key):
                if self.path.exists(): self.path.unlink()
                self.agent.records = []
                self.op('start')
                cfg = {'OEM_AGENT_EMCTL': '/agent/bin/emctl', key: 'INVALID'}
                args = ['blackout', 'stop', '--config', '/fixture', '--run-root', self.tmp.name, '--run-id', 'run']
                with patch.object(b, 'config', return_value=cfg), patch.object(b, 'Agent', return_value=self.agent), \
                     patch.object(self.agent, 'healthy', create=True), patch.object(b.socket, 'getfqdn', return_value='h'), \
                     patch.object(sys, 'argv', args):
                    b.main()
                self.assertEqual(b.read_json(self.path)['status'], 'STOPPED')

    def test_cleanup_config_ignores_duplicate_start_settings(self):
        p = pathlib.Path(self.tmp.name) / 'config'
        p.write_text('OEM_AGENT_EMCTL=/agent/bin/emctl\nOEM_BLACKOUT_MODE=INVALID\nOEM_BLACKOUT_MODE=OTHER\n'
                     'OEM_BLACKOUT_DURATION=INVALID\nOEM_BLACKOUT_MIN_REMAINING_SECONDS=INVALID\n')
        # Model trusted root ownership independently of the test runner's UID.
        real_stat = pathlib.Path.stat
        def owned(path, *args, **kwargs):
            info = real_stat(path, *args, **kwargs)
            if path == p:
                values = list(info); values[4] = 0
                return b.os.stat_result(values)
            return info
        with patch.object(pathlib.Path, 'stat', owned):
            self.assertEqual(b.config(p, cleanup=True), {'OEM_AGENT_EMCTL':'/agent/bin/emctl'})

    def test_stop_independent_of_apply_database_state(self):
        for value in ('12_COMPLETE','FAILED','MANUAL_INTERVENTION_REQUIRED','PMON_DOWN'):
            with self.subTest(value=value):
                if self.path.exists(): self.path.unlink()
                self.agent.records = []
                self.op('start')
                (self.path.parent / 'execution_state.json').write_text(json.dumps({'state':value}))
                self.assertEqual(self.op('stop'), 'STOPPED')

    def test_no_retarget_after_corrupt_state(self):
        self.op('start')
        self.path.write_text('{')
        with self.assertRaises(b.Failure): self.op('stop')
        self.assertEqual(len(self.agent.calls), 1)

if __name__ == '__main__': unittest.main()
