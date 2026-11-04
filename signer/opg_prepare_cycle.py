#!/usr/bin/python3 -I
"""Signer-only cycle preparation; never sources shell configuration."""
import argparse
import fcntl
import hashlib
import json
import os
import pwd
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


def require(ok, message):
    if not ok:
        raise ValueError(message)


def safe(path, directory=False, private=False, patch_root=None):
    """Validate SIGNER_SECURE, PATCH_MANAGED and PATCH_ANCESTOR paths."""
    path = Path(path)
    require(path.is_absolute(), "absolute path required")
    oracle_uid = None
    patch_context = False
    if patch_root is not None and not private:
        patch_root = Path(patch_root)
        require(patch_root.is_absolute() and '..' not in patch_root.parts,
                "unsafe patch root")
        require('..' not in path.parts, "unsafe patch path")
        # PATCH_SHARE covers this path's complete parent chain, but is never
        # selected for an unrelated path merely because patch_root was supplied.
        if path == patch_root or patch_root in path.parents:
            patch_context = True
            try:
                oracle_uid = pwd.getpwnam('oracle').pw_uid
            except KeyError:
                pass  # No oracle account: retain root/signer-only policy.
    for item in [path] + list(path.parents):
        policy = 'SIGNER_SECURE'
        if patch_context:
            policy = 'PATCH_ANCESTOR' if item in patch_root.parents else 'PATCH_MANAGED'
        s = item.lstat()
        require(not stat.S_ISLNK(s.st_mode), "symlink: " + str(item))
        if item != path or directory:
            require(stat.S_ISDIR(s.st_mode), "not a directory: " + str(item))
        require(s.st_uid in (0, os.geteuid()) or
                (oracle_uid is not None and s.st_uid == oracle_uid),
                "untrusted owner: " + str(item))
        # Root-owned sticky ancestors (e.g. /tmp) cannot replace our owned child.
        sticky_parent = (policy == 'SIGNER_SECURE' and item != path and
                         s.st_uid == 0 and s.st_mode & stat.S_ISVTX)
        require(policy == 'PATCH_ANCESTOR' or not s.st_mode & 0o022 or sticky_parent,
                "writable path: " + str(item))
    s = path.stat()
    require(stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode), "wrong file type")
    require(not private or not s.st_mode & 0o077, "private key permissions")
    return path


def sha(path, patch_root=None):
    h = hashlib.sha256()
    with safe(path, patch_root=patch_root).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, "helper failed: " + Path(argv[0]).name)


def syncdir(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, existing=False, patch_root=None):
    safe(path.parent, directory=True, patch_root=patch_root)
    old = safe(path, patch_root=patch_root).stat() if existing else None
    require(existing or not os.path.lexists(str(path)), "refusing overwrite: " + str(path))
    fd, name = tempfile.mkstemp(prefix='.opg-write-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            if old:
                os.fchown(stream.fileno(), old.st_uid, old.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(old.st_mode) if old else 0o440)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if existing:
            os.replace(name, str(path))
        else:
            os.link(name, str(path))
        syncdir(path.parent)
        require(safe(path, patch_root=patch_root).read_bytes() == data, "write verification failed")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def media(root, cycle, db, ojvm):
    require(re.fullmatch(r'[0-9]{6,12}', db) and re.fullmatch(r'[0-9]{6,12}', ojvm)
            and db != ojvm, 'invalid patch IDs')
    result = {}
    for role, patch, folder in [('db_ru', db, root / cycle), ('ojvm', ojvm, root / cycle),
                                ('opatch', '6880880', root / 'opatch')]:
        path = safe(folder / ('p%s_190000_Linux-x86-64.zip' % patch), patch_root=root)
        with zipfile.ZipFile(str(path)) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)), 'duplicate ZIP entries')
            require(all(not n.startswith('/') and '..' not in n.split('/') and '\\' not in n
                        for n in names), 'unsafe ZIP entry')
            require(archive.testzip() is None, 'corrupt ZIP')
            value = {'filename': path.name, 'size': path.stat().st_size, 'sha256': sha(path, patch_root=root)}
            if role == 'opatch':
                info = archive.getinfo('OPatch/version.txt')
                require(info.file_size <= 4096, 'oversized version.txt')
                version = archive.read(info).decode('ascii').strip()
                match = re.fullmatch(r'(?:OPATCH_VERSION:\s*)?([0-9]+(?:\.[0-9]+){3,5})', version)
                require(match, 'invalid OPatch version')
                value['version'] = match.group(1)
            else:
                require(any(n.startswith(patch + '/') for n in names), 'ZIP patch ID mismatch')
                value['patch_id'] = patch
        result[role] = value
    return result


def config(cycle, artifacts):
    db, oj, op = (artifacts[x] for x in ('db_ru', 'ojvm', 'opatch'))
    rows = [('PATCH_CYCLE', cycle), ('DB_RU_PATCH_ID', db['patch_id']),
            ('OJVM_PATCH_ID', oj['patch_id']), ('OPATCH_VERSION', op['version'])]
    for label, item in [('OPATCH', op), ('DB_RU', db), ('OJVM', oj)]:
        rows.extend([(label + '_ZIP', item['filename']), (label + '_ZIP_SHA256', item['sha256'])])
    rows.extend([('ARTIFACT_MANIFEST', 'artifact_manifest.json'),
                 ('ARTIFACT_MANIFEST_SIG', 'artifact_manifest.sig')])
    return ''.join(k + '=' + v + '\n' for k, v in rows).encode('ascii')


def validate(args, folder, ready=True):
    manifest = safe(folder / 'artifact_manifest.json', patch_root=args.patch_root)
    signature = safe(folder / 'artifact_manifest.sig', patch_root=args.patch_root)
    run(['/usr/bin/openssl', 'dgst', '-sha256', '-verify', str(safe(args.public_key)),
         '-signature', str(signature), str(manifest)])
    data = json.loads(manifest.read_text())
    require(set(data) == {'schema_version', 'patch_cycle', 'created_at', 'tree_hash_format', 'artifacts'},
            'manifest fields mismatch')
    require(data['schema_version'] == 1 and data['patch_cycle'] == args.cycle and
            data['tree_hash_format'] == 'OPG_TREE_HASH_V2', 'manifest identity mismatch')
    artifacts = media(args.patch_root, args.cycle, data['artifacts']['db_ru']['patch_id'],
                      data['artifacts']['ojvm']['patch_id'])
    require(data['artifacts'] == artifacts, 'manifest/media mismatch')
    require(safe(folder / 'opg_cycle.conf', patch_root=args.patch_root).read_bytes() == config(args.cycle, artifacts),
            'cycle config mismatch')
    if ready:
        require(safe(folder / '.opg-prepared', patch_root=args.patch_root).read_text() == sha(manifest, patch_root=args.patch_root) + '\n', 'preparation missing')
    return artifacts


def execute(args):
    safe(args.patch_root, directory=True, patch_root=args.patch_root)
    safe(args.config_dir, directory=True, patch_root=args.patch_root)
    folder = safe(args.patch_root / args.cycle, directory=True, patch_root=args.patch_root)
    lockpath = args.config_dir / '.opg-cycle.lock'
    fd = os.open(str(lockpath), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as lock:
        safe(lockpath, patch_root=args.patch_root)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'prepare':
            require(args.db_ru and args.ojvm, 'prepare requires --db-ru and --ojvm')
            for name in ('artifact_manifest.json', 'artifact_manifest.sig', 'opg_cycle.conf', '.opg-prepared'):
                require(not os.path.lexists(str(folder / name)), 'cycle already exists; refusing overwrite')
            artifacts = media(args.patch_root, args.cycle, args.db_ru, args.ojvm)
            safe(args.private_key, private=True)
            safe(args.builder)
            with tempfile.TemporaryDirectory(prefix='.opg-prepare-', dir=str(folder)) as tmp:
                staged = Path(tmp)
                argv = ['/usr/bin/python3', '-I', str(args.builder), '--cycle', args.cycle,
                        '--db-patch-id', args.db_ru, '--ojvm-patch-id', args.ojvm,
                        '--opatch-version', artifacts['opatch']['version'],
                        '--private-key', str(args.private_key), '--output-dir', tmp]
                for role, option in [('db_ru', 'db'), ('ojvm', 'ojvm'), ('opatch', 'opatch')]:
                    base = args.patch_root / 'opatch' if role == 'opatch' else folder
                    argv.extend(['--' + option + '-zip', str(base / artifacts[role]['filename'])])
                run(argv)
                atomic(staged / 'opg_cycle.conf', config(args.cycle, artifacts), patch_root=args.patch_root)
                require(validate(args, staged, ready=False) == artifacts, 'media changed during prepare')
                for name in ('artifact_manifest.json', 'artifact_manifest.sig', 'opg_cycle.conf'):
                    atomic(folder / name, (staged / name).read_bytes(), patch_root=args.patch_root)
                validate(args, folder, ready=False)
                atomic(folder / '.opg-prepared', (sha(folder / 'artifact_manifest.json', patch_root=args.patch_root) + '\n').encode(), patch_root=args.patch_root)
            status = 'READY_TO_ACTIVATE'
        else:
            require(not args.db_ru and not args.ojvm, 'activate does not accept patch IDs')
            artifacts = validate(args, folder)
            runtime = safe(args.config_dir / 'patchGD_guard.conf', patch_root=args.patch_root)
            active = safe(args.config_dir / 'active_cycle', patch_root=args.patch_root)
            before, oldactive = runtime.read_bytes(), active.read_bytes()
            pattern = rb'(?m)^OPATCH_ZIP_SHA256=[^\r\n]*$'
            require(len(re.findall(pattern, before)) == 1, 'runtime hash assignment missing/duplicate')
            # Reject alternate shell assignments that could override our literal assignment.
            require(len(re.findall(rb'(?m)^[ \t]*(?:export[ \t]+)?OPATCH_ZIP_SHA256[ \t]*=', before)) == 1,
                    'ambiguous runtime hash assignment')
            after = re.sub(pattern, ('OPATCH_ZIP_SHA256=' + artifacts['opatch']['sha256']).encode(), before)
            selected = (args.cycle + '\n').encode()
            if before != after or oldactive != selected:
                try:
                    atomic(runtime, after, existing=True, patch_root=args.patch_root)
                    validate(args, folder)
                    atomic(active, selected, existing=True, patch_root=args.patch_root)
                    require(runtime.read_bytes() == after and active.read_bytes() == selected, 'activation readback')
                except Exception:
                    atomic(active, oldactive, existing=True, patch_root=args.patch_root)
                    atomic(runtime, before, existing=True, patch_root=args.patch_root)
                    raise
            status = 'ACTIVE'
        print('OPG_CYCLE_%s|cycle=%s|status=%s' % (args.action.upper(), args.cycle, status))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'activate'])
    parser.add_argument('cycle')
    parser.add_argument('--db-ru')
    parser.add_argument('--ojvm')
    parser.add_argument('--patch-root', type=Path, default=Path('/mnt/datadomain/software/patches/Linux'))
    parser.add_argument('--config-dir', type=Path)
    parser.add_argument('--private-key', type=Path, default=Path('/secure/oracle-patch-guard/approval_private.pem'))
    parser.add_argument('--public-key', type=Path, default=Path('/secure/oracle-patch-guard/approval_public.pem'))
    parser.add_argument('--builder', type=Path, default=Path('/secure/oracle-patch-guard/bin/opg_build_artifact_manifest.py'))
    args = parser.parse_args()
    try:
        require(re.fullmatch(r'[A-Z0-9][A-Z0-9_-]{0,63}', args.cycle), 'invalid cycle')
        args.config_dir = args.config_dir or args.patch_root / 'oracle-patch-guard/config'
        os.umask(0o077)
        execute(args)
    except Exception as exc:
        print('OPG_CYCLE_%s|status=BLOCKED' % args.action.upper())
        print(str(exc), file=sys.stderr)
        return 20
    return 0


if __name__ == '__main__':
    sys.exit(main())
