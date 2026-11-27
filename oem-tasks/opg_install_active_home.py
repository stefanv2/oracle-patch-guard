#!/usr/bin/python3 -IBS
"""Install the opt-in privileged Active Home inspection on one host."""

import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from os import readlink
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile


CONFIG_DIR = Path("/etc/oracle-patch-guard")
LAUNCHER = Path("/usr/local/sbin/opg_active_home_inspect")
SCANNER_DIR = Path("/usr/local/libexec/oracle-patch-guard")
SUDOERS = Path("/etc/sudoers.d/oracle-patch-guard-active-home")
SUDO = Path("/usr/bin/sudo")
VISUDO = Path("/usr/sbin/visudo")
SUDO_CONF = Path("/etc/sudo.conf")
NSSWITCH = Path("/etc/nsswitch.conf")
NAMESPACES = ("pid", "mnt", "user")
INITIAL_NAMESPACES = {"pid": "pid:[4026531836]", "user": "user:[4026531837]"}
MAX_FILE_SIZE = 1024 * 1024
STAGE_PREFIX = ".opg-active-home-"


def directory_fd(path):
    return os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def sync_directory(path):
    fd = directory_fd(path)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def require_directory_chain(path):
    for directory in tuple(reversed(path.parents)) + (path,):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise PermissionError("unsafe directory: {}".format(directory))


def require_file(info, path, modes=None, single_link=True):
    mode = stat.S_IMODE(info.st_mode)
    if (not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid) != (0, 0)
            or (single_link and info.st_nlink != 1)
            or (mode & 0o7022 if modes is None else mode not in modes)):
        raise PermissionError("unsafe file: {}".format(path))


def safe_contents(path, modes=None):
    require_file(path.lstat(), path, modes)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        require_file(os.fstat(source.fileno()), path, modes)
        contents = source.read(MAX_FILE_SIZE + 1)
    if len(contents) > MAX_FILE_SIZE:
        raise ValueError("oversized file: {}".format(path))
    return contents


def policy_for(user, home, deployment_id, scanner_digest):
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user):
        raise ValueError("invalid Oracle runtime username")
    identity = pwd.getpwnam(user)
    if not (0 < identity.pw_uid < 4294967295 and 0 < identity.pw_gid < 4294967295):
        raise ValueError("runtime account requires a non-root UID and primary GID")
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", home) or os.path.realpath(home) != home:
        raise ValueError("Oracle Home must be a canonical directory owned by the runtime account")
    home_info = os.stat(home)
    if not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != identity.pw_uid:
        raise ValueError("Oracle Home must be a canonical directory owned by the runtime account")
    if readlink("/proc/self") != str(os.getpid()):
        raise PermissionError("procfs PID view does not match the caller")
    namespaces = {}
    for name in NAMESPACES:
        ref = readlink("/proc/1/ns/" + name)
        if (not re.fullmatch(name + r":\[[0-9]+\]", ref)
                or INITIAL_NAMESPACES.get(name, ref) != ref or readlink("/proc/self/ns/" + name) != ref):
            raise PermissionError("host namespace cannot be confirmed: {}".format(name))
        namespaces[name] = ref
    data = {"uid": identity.pw_uid, "gid": identity.pw_gid, "oracle_home": home, "namespaces": namespaces,
            "deployment_id": deployment_id, "scanner_sha256": scanner_digest}
    return (json.dumps(data, sort_keys=True, indent=2) + "\n").encode("ascii")


def sudoers_for(template, user):
    account = b"\noracle ALL=(root) NOPASSWD: NOSETENV: NOEXEC: OPG_ACTIVE_HOME_INSPECTION\n"
    if template.count(account) != 1:
        raise ValueError("unexpected Active Home sudoers template")
    return template.replace(account, account.replace(b"oracle", user.encode("ascii"), 1), 1)


def local_sudoers_source():
    for path in (NSSWITCH, SUDO_CONF):
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError:
            if path.is_symlink():
                raise
            continue
        require_directory_chain(resolved.parent)
        contents = safe_contents(resolved).replace(b"\\\r\n", b"").replace(b"\\\n", b"")
        for line in contents.splitlines():
            words = line.partition(b"#")[0].split()
            if not words:
                continue
            if path == NSSWITCH and re.match(br"sudoers\s*:", b" ".join(words), re.I):
                if not re.fullmatch(br"sudoers\s*:\s*files", b" ".join(words), re.I):
                    raise ValueError("external sudoers sources cannot be validated")
            if path == SUDO_CONF and words[0].lower() == b"plugin":
                if (len(words) != 3 or words[1] not in (b"sudoers_policy", b"sudoers_io", b"sudoers_audit")
                        or words[2] != b"sudoers.so"):
                    raise ValueError("custom sudo plugin configuration cannot be validated")
            if path == SUDO_CONF and [word.lower() for word in words[:2]] == [b"path", b"plugin_dir"]:
                raise ValueError("custom sudo plugin directory cannot be validated")


def validation_environment():
    return {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}


def sudoers_entries():
    return sorted(path for path in SUDOERS.parent.iterdir() if not path.name.startswith(STAGE_PREFIX))


def validate_sudoers(candidate, labels):
    local_sudoers_source()
    env = validation_environment()
    subprocess.run([str(VISUDO), "-c"], env=env, check=True)
    # A private mount retains absolute and relative include paths and uses the host's own parser.
    entries = sudoers_entries()
    identities = {path: path.lstat() for path in entries}
    with tempfile.TemporaryDirectory(prefix=STAGE_PREFIX, dir=str(SUDOERS.parent)) as directory:
        snapshot = Path(directory)
        os.chmod(directory, stat.S_IMODE(SUDOERS.parent.stat().st_mode))
        labels.verify(SUDOERS.parent, SUDOERS.parent, stat.S_IFDIR)
        labels.prepare(snapshot, SUDOERS.parent, stat.S_IFDIR)
        for path in entries:
            if path != SUDOERS:
                require_file(identities[path], path, single_link=False)
                os.link(str(path), str(snapshot / path.name), follow_symlinks=False)
        os.link(str(candidate), str(snapshot / SUDOERS.name), follow_symlinks=False)
        result = subprocess.run([
            "/usr/bin/unshare", "--mount", "/bin/sh", "-ec",
            'mount --make-rprivate /; mount --bind "$1" "$2"; exec "$3" -c',
            "opg-sudoers-check", directory, str(SUDOERS.parent), str(VISUDO),
        ], env=env, check=True, stdout=subprocess.PIPE)
        expected = os.fsencode(str(SUDOERS)) + b": parsed OK"
        if expected not in result.stdout.splitlines():
            raise ValueError("candidate fragment is not included in the effective sudoers policy")
        if entries != sudoers_entries() or any(
                (info.st_ino, info.st_dev, info.st_mtime_ns, info.st_mode, info.st_size) !=
                (current.st_ino, current.st_dev, current.st_mtime_ns, current.st_mode, current.st_size)
                for path, info in identities.items() for current in (path.lstat(),)):
            raise ValueError("sudoers directory changed during validation")


class SELinuxLabels:
    def __init__(self):
        self.lib = ctypes.CDLL("libselinux.so.1", use_errno=True)
        status = self.lib.is_selinux_enabled()
        if status not in (0, 1) or (status == 1 and self.lib.security_getenforce() != 1):
            raise PermissionError("SELinux status is unconfirmed or permissive")
        self.enabled = status == 1

    def context(self, path, mode=None):
        value = ctypes.c_char_p()
        if mode is None:
            result = self.lib.getfilecon_raw(os.fsencode(str(path)), ctypes.byref(value))
        else:
            result = self.lib.matchpathcon_raw(os.fsencode(str(path)), mode, ctypes.byref(value))
        if result < 0 or not value.value:
            raise OSError(ctypes.get_errno(), "cannot determine SELinux context", str(path))
        try:
            return value.value
        finally:
            self.lib.freecon(value)

    def prepare(self, candidate, destination, file_type):
        if not self.enabled:
            return
        expected = self.context(destination, file_type)
        if self.context(candidate) != expected:
            if self.lib.setfilecon_raw(os.fsencode(str(candidate)), expected) != 0:
                raise OSError(ctypes.get_errno(), "cannot set SELinux context", str(destination))
        self.verify(candidate, destination, file_type)

    def verify(self, path, destination, file_type):
        if self.enabled and self.context(path) != self.context(destination, file_type):
            raise PermissionError("unexpected SELinux context: {}".format(path))


@contextlib.contextmanager
def staged_file(path, data, mode, labels, retained=None):
    fd, name = tempfile.mkstemp(prefix=STAGE_PREFIX, dir=str(path.parent))
    candidate = Path(name)
    try:
        with os.fdopen(fd, "wb") as target:
            os.fchown(target.fileno(), 0, 0)
            os.fchmod(target.fileno(), mode)
            target.write(data)
            target.flush()
            labels.prepare(candidate, path, stat.S_IFREG)
            os.fsync(target.fileno())
        yield candidate
    finally:
        if retained is None or candidate not in retained:
            try:
                candidate.unlink()
            except FileNotFoundError:
                pass


def publish_sudoers(candidate, previous, labels):
    retained = set()
    with contextlib.ExitStack() as stack:
        backup = None if previous is None else stack.enter_context(
            staged_file(SUDOERS, previous, 0o440, labels, retained))
        sync_directory(SUDOERS.parent)
        candidate_info = candidate.lstat()
        os.replace(str(candidate), str(SUDOERS))
        try:
            sync_directory(SUDOERS.parent)
        except OSError:
            # Restore exactly the previously validated policy if publication cannot be confirmed.
            try:
                active_info = SUDOERS.lstat()
                if (active_info.st_dev, active_info.st_ino) != (candidate_info.st_dev, candidate_info.st_ino):
                    raise OSError("active sudoers fragment changed during publication")
                if backup is None:
                    SUDOERS.unlink()
                else:
                    os.replace(str(backup), str(SUDOERS))
                sync_directory(SUDOERS.parent)
            except OSError as error:
                # Keep the prepared copy if its restoration did not reach the active pathname.
                retained.add(backup)
                raise OSError("sudoers restoration could not be confirmed; previous copy: {}: {}".format(
                    backup if backup and backup.exists() else "check active fragment", error)) from error
            raise


def install_files(files, labels):
    # Check every existing target before staging and validate sudoers before publishing any file.
    previous = {}
    for path, data, mode in files:
        try:
            previous[path] = safe_contents(path, (mode,))
        except FileNotFoundError:
            previous[path] = None
        if previous[path] is not None:
            labels.verify(path, path, stat.S_IFREG)
    if previous[files[0][0]] is not None and previous[files[0][0]] != files[0][1]:
        raise PermissionError("installed scanner generation has different contents")
    with contextlib.ExitStack() as stack:
        staged = {path: stack.enter_context(staged_file(path, data, mode, labels))
                  for path, data, mode in files if previous[path] != data}
        validate_sudoers(staged.get(SUDOERS, SUDOERS), labels)
        for path, data, mode in files:
            if path == SUDOERS:
                continue
            if path in staged:
                os.replace(str(staged[path]), str(path))
            sync_directory(path.parent)
            if safe_contents(path, (mode,)) != data:
                raise OSError("published content differs: {}".format(path))
            labels.verify(path, path, stat.S_IFREG)
        # Check again just before the final activation, after all other files are durable.
        validate_sudoers(staged.get(SUDOERS, SUDOERS), labels)
        if SUDOERS in staged:
            try:
                active_policy = safe_contents(SUDOERS, (0o440,))
            except FileNotFoundError:
                active_policy = None
            if active_policy != previous[SUDOERS]:
                raise OSError("active sudoers fragment changed during installation")
            publish_sudoers(staged[SUDOERS], previous[SUDOERS], labels)
        else:
            sync_directory(SUDOERS.parent)
        for path, _, _ in files:
            print("OPG_ACTIVE_HOME_INSTALL|{}|{}".format("INSTALLED" if path in staged else "UNCHANGED", path))


def deploy(release, user, home):
    for directory in (release / "oem-tasks", release / "project/lib", release / "config/examples",
                      CONFIG_DIR, LAUNCHER.parent, SUDOERS.parent, SUDO.parent, VISUDO.parent):
        require_directory_chain(directory)
    require_file(SUDO.lstat(), SUDO, (0o4111, 0o4755), single_link=False)
    require_file(VISUDO.lstat(), VISUDO)
    launcher = safe_contents(release / "oem-tasks/opg_active_home_inspect.py")
    scanner = safe_contents(release / "project/lib/opg_active_home.py")
    scanner_digest = hashlib.sha256(scanner).hexdigest()
    deployment_id = hashlib.sha256(launcher + bytes.fromhex(scanner_digest)).hexdigest()
    for name, value in ((b"DEPLOYMENT_ID", deployment_id), (b"SCANNER_SHA256", scanner_digest)):
        marker = b"\n" + name + b" = None "
        if launcher.count(marker) != 1:
            raise ValueError("launcher deployment marker is missing or ambiguous")
        launcher = launcher.replace(marker, b"\n" + name + b' = "' + value.encode("ascii") + b'" ', 1)
    scanner_path = SCANNER_DIR / ("opg_active_home-" + scanner_digest + ".py")
    policy = policy_for(user, home, deployment_id, scanner_digest)
    sudoers = sudoers_for(safe_contents(release / "config/examples/oracle-patch-guard-active-home.sudoers"), user)
    compile(launcher, str(LAUNCHER), "exec")
    compile(scanner, str(scanner_path), "exec")
    lock = directory_fd(CONFIG_DIR)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        labels = SELinuxLabels()
        for directory in (SCANNER_DIR.parent, SCANNER_DIR):
            require_directory_chain(directory.parent)
            try:
                directory.mkdir(mode=0o755)
            except FileExistsError:
                pass
            else:
                labels.prepare(directory, directory, stat.S_IFDIR)
            require_directory_chain(directory)
            labels.verify(directory, directory, stat.S_IFDIR)
            sync_directory(directory.parent)
        install_files(((scanner_path, scanner, 0o644), (CONFIG_DIR / "active-home-inspect.json", policy, 0o400),
                       (LAUNCHER, launcher, 0o755), (SUDOERS, sudoers, 0o440)), labels)
    finally:
        os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle-user", required=True)
    parser.add_argument("--oracle-home", required=True)
    args = parser.parse_args()
    try:
        if os.getuid() != 0 or os.geteuid() != 0:
            raise PermissionError("run as a host administrator")
        os.umask(0o022)
        deploy(Path(__file__).absolute().parent.parent, args.oracle_user, args.oracle_home)
    except (OSError, ValueError, KeyError, SyntaxError, subprocess.CalledProcessError) as error:
        print("OPG_ACTIVE_HOME_INSTALL|UNKNOWN|{}".format(error), file=sys.stderr)
        return 30
    print("OPG_ACTIVE_HOME_INSTALL|FILES_VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
