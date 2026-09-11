#!/usr/bin/env python3
"""Local OEM orchestration only. No database operations, shell evaluation or sudo.

Status adapter is deliberately strict: unknown Agent output fails closed.
Deployment must qualify the adapter with its actual Agent status fixtures.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import tempfile
import time

# Two bounded Agent commands (START and confirmation), plus scheduling margin.
START_CONFIRMATION_MARGIN_SECONDS = 120


class Failure(Exception):
    def __init__(self, reason, code=20):
        self.reason, self.code = reason, code


def require(ok, reason, code=20):
    if not ok:
        raise Failure(reason, code)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'DUPLICATE_JSON_KEY')
        result[key] = value
    return result


def read_json(path):
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode), 'UNSAFE_STATE')
            require(info.st_uid == os.geteuid() and not info.st_mode & 0o022, 'UNSAFE_STATE')
            result = json.load(stream, object_pairs_hook=pairs)
        require(isinstance(result, dict), 'INVALID_STATE')
        return result
    except (OSError, ValueError):
        raise Failure('BLACKOUT_STATE_INVALID')


def write_json(path, data):
    tmp = None
    try:
        require(not path.is_symlink(), 'UNSAFE_STATE')
        fd, tmp = tempfile.mkstemp(prefix='.blackout.', dir=str(path.parent))
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(data, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        tmp = None
        fd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        raise Failure('BLACKOUT_STATE_WRITE_FAILED', 30)
    finally:
        if tmp is not None:
            os.unlink(tmp)


def duration(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-2][0-9]:[0-5][0-9]', value), 'INVALID_DURATION')
    hours, minutes = map(int, value.split(':'))
    require(hours < 24 and hours * 60 + minutes > 0, 'INVALID_DURATION')
    return (hours * 60 + minutes) * 60


def body(text):
    # Known banner lines only; no silent dropping of errors/warnings.
    return [line.strip() for line in text.splitlines() if line.strip()
            and not line.startswith('Oracle Enterprise Manager ')
            and not line.startswith('Copyright (c) ')]


def inventory(text):
    result = []
    for line in body(text):
        m = re.fullmatch(r'\[([^\[\],\r\n]+), ([A-Za-z0-9_]+)\]', line)
        require(m is not None, 'AGENT_TARGET_LIST_INVALID', 30)
        result.append(m.groups())
    require(bool(result), 'AGENT_TARGET_LIST_INVALID', 30)
    return result


def resolve(text, sid, host):
    matches = [name for name, kind in inventory(text) if kind == 'oracle_database' and name == sid]
    require(len(matches) != 0, 'TARGET_NOT_FOUND')
    require(len(matches) == 1, 'TARGET_NOT_UNIQUE')
    return matches[0]


def blackouts(text):
    lines = body(text)
    if lines == ['No Blackout registered.']:
        return []
    require(bool(lines) and len(lines) % 4 == 0, 'BLACKOUT_STATUS_UNCONFIRMED', 30)
    result = []
    for i in range(0, len(lines), 4):
        name = re.fullmatch(r'Blackoutname = ([A-Za-z0-9][A-Za-z0-9._-]{0,127})', lines[i])
        targets = re.fullmatch(r'Targets = \(([^()]+)\)', lines[i+1])
        timing = re.fullmatch(r'Time = \(\{(\d{4}-\d{2}-\d{2})\|(\d{2}:\d{2}:\d{2})(?:\|(\d+) Min)?,\|\} \)', lines[i+2])
        expired = re.fullmatch(r'Expired = (True|False)', lines[i+3])
        require(all((name, targets, timing, expired)), 'BLACKOUT_STATUS_UNCONFIRMED', 30)
        members = targets[1].rstrip(',').split(',')
        require(all(re.fullmatch(r'[^\s,|]+:[A-Za-z0-9_]+', x) for x in members), 'BLACKOUT_STATUS_UNCONFIRMED', 30)
        try:
            started = int(time.mktime(time.strptime(timing[1] + ' ' + timing[2], '%Y-%m-%d %H:%M:%S')))
        except (ValueError, OverflowError):
            raise Failure('BLACKOUT_STATUS_UNCONFIRMED', 30)
        result.append({'name': name[1], 'targets': members, 'expired': expired[1] == 'True',
                       'started': started, 'seconds': int(timing[3]) * 60 if timing[3] else None})
    require(len({x['name'] for x in result}) == len(result), 'BLACKOUT_STATUS_UNCONFIRMED', 30)
    return result


def config(path, cleanup=False):
    require(path.is_absolute() and not path.is_symlink(), 'UNSAFE_CONFIG')
    require(path.resolve() == path, 'UNSAFE_CONFIG')
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022, 'UNSAFE_CONFIG')
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = map(str.strip, line.split('=', 1))
        if key.startswith('OEM_') and (not cleanup or key == 'OEM_AGENT_EMCTL'):
            require(key not in result, 'DUPLICATE_CONFIG_KEY')
            result[key] = value
    return result


def mode(cfg):
    value = cfg.get('OEM_BLACKOUT_MODE', 'disabled')
    require(value in ('disabled', 'required'), 'INVALID_BLACKOUT_MODE')
    return value


class Agent:
    def __init__(self, path, host, home):
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+/bin/emctl', path or '') is not None, 'INVALID_AGENT_PATH')
        p = Path(path)
        require(str(p) == path and '..' not in p.parts and p.resolve() == p, 'INVALID_AGENT_PATH')
        require(p.is_file() and os.access(path, os.X_OK), 'AGENT_UNAVAILABLE')
        require(p.stat().st_uid == os.geteuid(), 'AGENT_OWNER_MISMATCH')
        require(not p.stat().st_mode & 0o022, 'UNSAFE_AGENT_BINARY')
        require(not home or not str(p).startswith(home.rstrip('/') + '/'), 'DATABASE_HOME_AGENT_REJECTED')
        self.path, self.host = path, host

    def call(self, *args):
        try:
            result = subprocess.run([self.path] + list(args), stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, universal_newlines=True,
                                    timeout=45, env=dict(os.environ, LC_ALL='C', LANG='C'))
        except (OSError, subprocess.TimeoutExpired):
            raise Failure('AGENT_UNAVAILABLE', 30)
        require(result.returncode == 0, 'AGENT_COMMAND_FAILED', 30)
        return result.stdout

    def healthy(self):
        text = self.call('status', 'agent')
        require('Agent is Running and Ready' in text.splitlines(), 'AGENT_UNAVAILABLE', 30)
        homes = re.findall(r'^Agent Home\s*:\s*(\S+)\s*$', text, re.M)
        require(homes == [str(Path(self.path).parent.parent)], 'AGENT_HOME_MISMATCH')
        users = re.findall(r'^Started by user\s*:\s*(\S+)\s*$', text, re.M)
        import pwd
        require(users == [pwd.getpwuid(os.geteuid()).pw_name], 'AGENT_OWNER_MISMATCH')

    def status(self, target):
        return blackouts(self.call('status', 'blackout', target + ':oracle_database'))


def own(records, state):
    found = [r for r in records if r['name'] == state['blackout_name']]
    if not found:
        return None
    require(found[0]['targets'] == [state['target'] + ':oracle_database'], 'BLACKOUT_BINDING_MISMATCH')
    require(found[0]['seconds'] == duration(state['requested_duration']), 'BLACKOUT_DURATION_MISMATCH')
    require(abs(found[0]['started'] - state['requested_at']) <= 120, 'BLACKOUT_TIME_MISMATCH')
    return found[0]


def validate_state(state, binding):
    for key, value in binding.items():
        require(state.get(key) == value, 'BLACKOUT_STATE_MISMATCH')
    require(state.get('schema_version') == 1, 'BLACKOUT_STATE_INVALID')
    require(state.get('status') in ('PREPARED','STARTED','STOPPING','STOPPED','UNKNOWN','EXPIRED'), 'BLACKOUT_STATE_INVALID')
    require(type(state.get('requested_at')) is int, 'BLACKOUT_STATE_INVALID')
    require(0 < state['requested_at'] <= time.time() + 1, 'BLACKOUT_CLOCK_OR_STATE_INVALID')
    duration(state.get('requested_duration'))


def operate(action, path, binding, agent, requested, minimum):
    existing = path.exists() or path.is_symlink()
    if existing:
        state = read_json(path)
        validate_state(state, binding)
    else:
        require(action == 'start', 'BLACKOUT_STATE_MISSING')
        state = dict(binding, schema_version=1, requested_duration=requested,
                     requested_at=int(time.time()), confirmed_at=None, status='PREPARED')
    records = agent.status(state['target'])
    record = own(records, state)
    active = record is not None and not record['expired']
    remaining = min(state['requested_at'], record['started'] if record else state['requested_at']) + duration(state['requested_duration']) - time.time()
    if action in ('guard', 'start'):
        require(not any(not r['expired'] and r['name'] != state['blackout_name'] for r in records), 'BLACKOUT_ALREADY_EXISTS')
        if existing:
            require(state['status'] in ('PREPARED','STARTED','UNKNOWN'), 'BLACKOUT_STATE_MISMATCH')
            require(active, 'BLACKOUT_STATUS_UNCONFIRMED', 30)
            require(remaining >= minimum, 'BLACKOUT_DURATION_INSUFFICIENT')
            if action == 'guard':
                require(state['status'] == 'STARTED', 'BLACKOUT_NOT_STARTED')
                return 'READY'
            state.update(status='STARTED', confirmed_at=int(time.time()))
            write_json(path, state)
            return 'ALREADY_STARTED'
        require(record is None, 'BLACKOUT_ALREADY_EXISTS')
        require(duration(requested) >= minimum + START_CONFIRMATION_MARGIN_SECONDS,
                'BLACKOUT_DURATION_INSUFFICIENT')
        # Discovery/status preflight time is not part of the external START budget.
        state['requested_at'] = int(time.time())
        write_json(path, state)
        error = None
        try:
            agent.call('start', 'blackout', state['blackout_name'], state['target'] + ':oracle_database', '-d', requested)
        except Failure as exc:
            error = exc
        # A timeout/error can still have started the blackout. Reconcile first.
        try:
            record = own(agent.status(state['target']), state)
            require(record is not None and not record['expired'], 'BLACKOUT_STATUS_UNCONFIRMED', 30)
        except Failure:
            state['status'] = 'UNKNOWN'
            write_json(path, state)
            raise Failure('BLACKOUT_STATUS_UNCONFIRMED', 30) from error
        state.update(status='STARTED', confirmed_at=int(time.time()))
        require(state['requested_at'] + duration(requested) - time.time() >= minimum,
                'BLACKOUT_DURATION_INSUFFICIENT')
        write_json(path, state)
        return 'STARTED'
    require(action == 'stop', 'INVALID_ACTION')
    if not active:
        state['status'] = 'EXPIRED' if record is not None else 'STOPPED'
        write_json(path, state)
        return 'EXPIRED' if record is not None else 'ALREADY_STOPPED'
    require(state['status'] not in ('STOPPED','EXPIRED'), 'BLACKOUT_STATE_MISMATCH')
    state['status'] = 'STOPPING'
    write_json(path, state)
    try:
        agent.call('stop', 'blackout', state['blackout_name'])
    except Failure:
        pass  # Reconcile an uncertain stop, never mask an active blackout.
    record = own(agent.status(state['target']), state)
    require(record is None or record['expired'], 'BLACKOUT_STOP_UNCONFIRMED', 30)
    state['status'] = 'STOPPED'
    write_json(path, state)
    return 'STOPPED'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['mode','start','guard','stop'])
    parser.add_argument('--config', required=True)
    parser.add_argument('--run-id')
    parser.add_argument('--run-root', default='/var/log/oracle-patch-guard')
    parser.add_argument('--host')
    parser.add_argument('--sid')
    parser.add_argument('--home')
    parser.add_argument('--duration')
    args = parser.parse_args()
    cfg = config(Path(args.config), cleanup=args.action == 'stop')
    selected_mode = mode(cfg) if args.action != 'stop' else None
    if args.action == 'mode':
        print(selected_mode)
        return
    run = args.run_id or ''
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', run), 'INVALID_RUN_ID')
    # Conservative OPG limit (84 characters), not a claimed Oracle maximum.
    name = 'OPG_' + run
    host = socket.getfqdn()
    root = Path(args.run_root)
    directory = root / run
    require(root.is_absolute() and directory.resolve() == directory, 'UNSAFE_RUN_DIRECTORY')
    info = directory.stat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == 0o700, 'UNSAFE_RUN_DIRECTORY')
    path = directory / 'blackout_state.json'
    fd = os.open(str(directory / '.blackout.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        lockinfo = os.fstat(fd)
        require(stat.S_ISREG(lockinfo.st_mode) and lockinfo.st_uid == os.geteuid()
                and not lockinfo.st_mode & 0o077, 'UNSAFE_LOCK')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure('BLACKOUT_BUSY')
        emctl = cfg.get('OEM_AGENT_EMCTL', '')
        if args.action == 'stop':
            state = read_json(path)
            require(state.get('agent_emctl') == emctl and state.get('host') == host, 'BLACKOUT_STATE_MISMATCH')
            sid, home = state.get('sid'), state.get('oracle_home')
        else:
            require(args.host == host, 'HOST_MISMATCH')
            sid, home = args.sid, args.home
        require(isinstance(sid, str) and re.fullmatch(r'[A-Za-z0-9_$#]+', sid), 'INVALID_SID')
        require(isinstance(home, str) and re.fullmatch(r'/[A-Za-z0-9_./-]+', home), 'INVALID_HOME')
        binding = dict(run_id=run, host=host, sid=sid, oracle_home=home,
                       agent_emctl=emctl, target=sid, target_type='oracle_database', blackout_name=name)
        agent = Agent(emctl, host, home)
        agent.healthy()
        if args.action != 'stop':
            listing = agent.call('config', 'agent', 'listtargets')
            require(inventory(listing).count((host, 'host')) == 1, 'AGENT_HOST_MISMATCH')
            resolve(listing, sid, host)
        requested = args.duration or cfg.get('OEM_BLACKOUT_DURATION', '')
        # No invented production runtime: activation requires an explicit duration.
        if args.action == 'start': duration(requested)
        minimum_text = cfg.get('OEM_BLACKOUT_MIN_REMAINING_SECONDS', '300') if args.action != 'stop' else '1'
        require(re.fullmatch(r'[0-9]+', minimum_text), 'INVALID_MIN_REMAINING')
        minimum = int(minimum_text)
        require(1 <= minimum <= 86399, 'INVALID_MIN_REMAINING')
        result = operate(args.action, path, binding, agent, requested, minimum)
        print('OPG_BLACKOUT_RESULT|status={}|run_id={}|target={}|blackout={}|exit_code=0'.format(result, run, sid, name))
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except Failure as exc:
        print('OPG_BLACKOUT_RESULT|status={}|reason={}|exit_code={}'.format(
            'UNKNOWN' if exc.code == 30 else 'BLOCKED', exc.reason, exc.code))
        raise SystemExit(exc.code)
    except (OSError, ValueError, TypeError, KeyError):
        print('OPG_BLACKOUT_RESULT|status=UNKNOWN|reason=LOCAL_STATE_OR_CONFIG_ERROR|exit_code=30')
        raise SystemExit(30)
