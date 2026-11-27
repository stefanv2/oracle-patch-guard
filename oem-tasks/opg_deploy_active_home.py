#!/usr/bin/python3 -IBS
"""BOOTSTRAP transaction and read-only PREPARE checks for Active Home."""

import contextlib
import fcntl
import grp
import hashlib
import json
import os
from os import readlink
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


MODE = "ACTIVE_HOME_INSPECTION_MODE"
HOME = "ACTIVE_HOME_ORACLE_HOME"
JOURNAL = ".active-home-transaction.json"
RECEIPT = "active-home-deployment.json"
PREFIX = ".opg-ah-"
INITIAL = {"pid": "pid:[4026531836]", "user": "user:[4026531837]"}
NAMESPACES = ("pid", "mnt", "user")
BASELINE = {  # Exact, manually installed b5ce19d bundle eligible for adoption.
    "launcher": "f09798544107d0603fee17f67d1bc78a0029d91c45c231e417cc3d420c0f3f07",
    "scanner": "4afb47bb7913a806dd1fa21cc5f08ffaf7f1f51a027b9455ab5f2a64031038e1",
    "sudoers": "73ad2c9f7f61efdb0f1c50ff34a8e4d59db26ce83eb605e2ce90fa078556fc49",
}
SOURCES = {
    "launcher": "oem-tasks/opg_active_home_inspect.py",
    "scanner": "project/lib/opg_active_home.py",
    "sudoers": "config/examples/oracle-patch-guard-active-home.sudoers",
}
TOOLS = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}
LIMIT = 8 * 1024 * 1024
ROOT_UID, ROOT_GID = 0, 0


def require(condition, message):
    if not condition:
        raise ValueError(message)


def present(path):
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    return True


def canonical(value):
    return (re.fullmatch(r"/[A-Za-z0-9_./-]+", value) is not None
            and all(part not in ("", ".", "..") for part in value[1:].split("/")))


def hostname():
    result = subprocess.run(["hostname", "-f"], env=TOOLS, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode:
        result = subprocess.run(["hostname"], env=TOOLS, check=True, stdout=subprocess.PIPE)
    return result.stdout.decode("ascii").strip()


def directory_chain(path, anchor=Path("/"), create=False):
    chain = [anchor]
    cursor = anchor
    for name in path.relative_to(anchor).parts:
        cursor = cursor / name
        chain.append(cursor)
    for part in chain:
        if create and not present(part):
            part.mkdir(mode=0o755)
            part.chmod(0o755)
            sync(part.parent)
        info = part.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == ROOT_UID and not info.st_mode & 0o022,
                "untrusted directory: {}".format(part))


def metadata(path, mode=None, gid=None, owners=None, links=(1,)):
    info = path.lstat()
    check_file(info, path, mode, gid, owners, links)
    return info


def check_file(info, path, mode, gid, owners, links):
    require(stat.S_ISREG(info.st_mode) and info.st_uid in (owners or (ROOT_UID,)) and info.st_nlink in links
            and (gid is None or info.st_gid == gid)
            and (stat.S_IMODE(info.st_mode) == mode if mode is not None else not info.st_mode & 0o7022),
            "untrusted file: {}".format(path))


def read_file(path, mode=None, gid=None, owners=None, links=(1,)):
    metadata(path, mode, gid, owners, links)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        check_file(os.fstat(fd), path, mode, gid, owners, links)
        data = source.read(LIMIT + 1)
    require(len(data) <= LIMIT, "oversized file: {}".format(path))
    return data


def configured(data, key, default):
    matches = re.findall(rb"(?m)^\s*" + key.encode("ascii") + rb"\s*=([^\r\n]*)", data)
    require(len(matches) <= 1, "duplicate configuration key: " + key)
    if not matches:
        return default
    value = matches[0].strip().decode("ascii")
    if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
        return value[1:-1]
    return value


def host_policy(root, node, anchor):
    directory = root / "config" / "hosts"
    if not present(directory):
        return None
    require(re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", node) is not None
            and all(part and len(part) <= 63 and not part.startswith("-") and not part.endswith("-")
                    for part in node.split(".")), "invalid host name for Active Home policy")
    directory_chain(directory, anchor)
    directory = directory / node
    if not present(directory):
        return None
    directory_chain(directory, anchor)
    fragment = directory / "active-home.conf"
    if not present(fragment):
        return None
    data = read_file(fragment, gid=ROOT_GID)
    require(len(data) <= 4096, "oversized Active Home host fragment")
    values = {}
    for line in data.decode("ascii").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        require(separator and key in (MODE, HOME) and key not in values,
                "unknown, invalid or duplicate host fragment key")
        values[key] = value
    home = values.get(HOME, "")
    require(values.get(MODE) == "privileged" and canonical(home),
            "host fragment requires privileged mode and one literal canonical Oracle Home")
    return home


def effective_config(data, home):
    require(configured(data, MODE, "local") == "local", "central base must use local Active Home mode")
    if home is None:
        return data
    data = re.sub(rb"(?m)^[ \t]*" + MODE.encode("ascii") + rb"[ \t]*=[^\r\n]*(?:\r?\n|$)", b"", data)
    return data.rstrip(b"\r\n") + ("\n{}=privileged\n".format(MODE)).encode("ascii")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(data):
    return (json.dumps(data, sort_keys=True, indent=2) + "\n").encode("ascii")


def decoded(data):
    def unique(pairs):
        fields = dict(pairs)
        require(len(fields) == len(pairs), "duplicate deployment field")
        return fields

    return json.loads(data.decode("ascii"), object_pairs_hook=unique)


def stamp(path):
    info = path.lstat()
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns]


def sync(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def command(args, capture=False, env=None, timeout=60):
    return subprocess.run([str(arg) for arg in args], env=TOOLS if env is None else env, check=True, timeout=timeout,
                          stdout=subprocess.PIPE if capture else None).stdout


class Labels:
    def __init__(self):
        state = command(["getenforce"], capture=True).strip()
        require(state in (b"Enforcing", b"Disabled"), "SELinux state is unconfirmed or permissive")
        self.enforcing = state == b"Enforcing"

    def prepare(self, candidate, target):
        if self.enforcing:
            context = command(["matchpathcon", "-n", "-m", "file", target], capture=True).strip().decode("ascii")
            require(re.fullmatch(r"[^\s:]+:[^\s:]+:[^\s:]+:[^\s]+", context) is not None,
                    "no SELinux file context for {}".format(target))
            command(["chcon", "--", context, candidate])
            require(command(["stat", "-c", "%C", candidate], capture=True).strip() == context.encode("ascii"),
                    "SELinux label differs for {}".format(candidate))

    def verify(self, path):
        if self.enforcing:
            command(["matchpathcon", "-V", path], capture=True)

    def reference(self, path, source):
        if self.enforcing:
            command(["chcon", "--reference=" + str(source), "--", path])


def namespace_policy(home, uid, gid, proc=Path("/proc")):
    require(readlink(str(proc / "self")) == str(os.getpid()), "procfs PID view does not match caller")
    namespaces = {}
    for name in NAMESPACES:
        ref = readlink(str(proc / "1" / "ns" / name))
        require(re.fullmatch(name + r":\[[0-9]+\]", ref) is not None and INITIAL.get(name, ref) == ref
                and readlink(str(proc / "self" / "ns" / name)) == ref,
                "initial host process coverage cannot be confirmed: " + name)
        namespaces[name] = ref
    status = (proc / "self" / "status").read_text(encoding="ascii")
    caps = re.search(r"(?m)^CapPrm:\s*([0-9a-fA-F]+)$", status)
    require(caps is not None and int(caps.group(1), 16) & (1 << 19), "CAP_SYS_PTRACE is unavailable")
    return {"uid": uid, "gid": gid, "oracle_home": home, "namespaces": namespaces}


def oracle_binding(home, oratab, account):
    require(0 < account.pw_uid < 4294967295 and 0 < account.pw_gid < 4294967295,
            "Oracle account requires a non-root uid and primary gid")
    require(os.path.realpath(home) == home and Path(home).is_dir()
            and Path(home).stat().st_uid == account.pw_uid, "Oracle Home is not canonical or owner differs")
    require(stat.S_ISREG((Path(home) / "bin/oracle").stat().st_mode), "Oracle Home lacks bin/oracle")
    homes = set()
    for line in read_file(oratab, owners=(ROOT_UID, account.pw_uid)).decode("utf-8").splitlines():
        fields = line.strip().split(":")
        sid = re.sub(r"\s", "", fields[0])
        if len(fields) < 2 or sid.startswith(("+ASM", "ASM", "+APX")) or sid == "MGMTDB":
            continue
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_$#]{0,29}", sid):
            candidate = fields[1].rstrip("/")
            require(canonical(candidate), "invalid Oracle Home in oratab")
            homes.add(os.path.realpath(candidate))
    require(homes == {home}, "oratab does not confirm exactly one Oracle Home")
    return namespace_policy(home, account.pw_uid, account.pw_gid)


@contextlib.contextmanager
def patch_lock(root, host, home, uid, gid, anchor):
    require(canonical(str(root)), "invalid LOCK_ROOT")
    # /var/lock is the one OS alias supported by the existing bootstrap.
    alias = anchor / "var/lock"
    if alias in root.parents and alias.is_symlink():
        directory_chain(alias.parent, anchor)
        require(alias.lstat().st_uid == ROOT_UID and alias.resolve() == anchor / "run/lock", "unsafe OS lock alias")
        root = alias.resolve() / root.relative_to(alias)
    directory_chain(root.parent, anchor, create=True)
    if not present(root):
        root.mkdir(mode=0o770)
        os.chown(str(root), ROOT_UID, gid)
        root.chmod(0o2770)
        sync(root.parent)
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (ROOT_UID, gid, 0o2770),
            "untrusted LOCK_ROOT")
    path = root / (sha((host + "|" + home).encode("ascii")) + ".lock")
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(str(path), flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        fd = os.open(str(path), flags)
        created = False
    else:
        created = True
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if created:
            os.fchown(fd, uid, gid)
            sync(root)
        locked = os.fstat(fd)
        check_file(locked, path, None, None, (uid,), (1,))
        require((locked.st_dev, locked.st_ino) == tuple(stamp(path)[:2]), "Oracle Home lock was replaced")
        yield
    finally:
        os.close(fd)


def local_sudoers_sources(etc):
    for name in ("sudo.conf", "nsswitch.conf"):
        path = etc / name
        if not present(path):
            continue
        resolved = path.resolve(strict=True)
        directory_chain(resolved.parent, etc.parent)
        data = read_file(resolved).replace(b"\\\r\n", b"").replace(b"\\\n", b"")
        for line in data.splitlines():
            words = line.partition(b"#")[0].split()
            if name == "nsswitch.conf" and re.match(br"sudoers\s*:", b" ".join(words), re.I):
                require(re.fullmatch(br"sudoers\s*:\s*files", b" ".join(words), re.I) is not None,
                        "external sudoers sources cannot be validated")
            if name == "sudo.conf" and words:
                require([word.lower() for word in words[:2]] != [b"path", b"plugin_dir"],
                        "custom sudo plugin directory cannot be validated")
                if words[0].lower() == b"plugin":
                    require(len(words) == 3 and words[1] in (b"sudoers_policy", b"sudoers_io", b"sudoers_audit")
                            and words[2] == b"sudoers.so", "custom sudo plugin cannot be validated")


def require_sudoers_included(output, paths):
    for target in paths:
        require(os.fsencode(str(target)) + b": parsed OK" in output.splitlines(),
                "fragment absent from effective sudoers: {}".format(target))


def sudo_binary(anchor):
    sudo = anchor / "usr/bin/sudo"
    directory_chain(sudo.parent, anchor)
    mode = stat.S_IMODE(sudo.lstat().st_mode)
    require(mode in (0o4111, 0o4755), "untrusted sudo mode")
    metadata(sudo, mode, ROOT_GID)
    return sudo


def validate_sudoers(paths, candidates, labels):
    dropins = paths["sudoers"].parent
    local_sudoers_sources(dropins.parent)
    command(["/usr/sbin/visudo", "-c"], capture=True)
    # A private bind mount preserves sudo's include paths, ordering and parser.
    with tempfile.TemporaryDirectory(prefix=PREFIX, dir=str(dropins.parent)) as raw:
        snapshot = Path(raw)
        snapshot.chmod(stat.S_IMODE(dropins.stat().st_mode))
        labels.reference(snapshot, dropins)
        for source in dropins.iterdir():
            if source.name.startswith(PREFIX) or source in candidates:
                continue
            copy = snapshot / source.name
            copy.write_bytes(read_file(source, gid=ROOT_GID))
            copy.chmod(stat.S_IMODE(source.stat().st_mode))
            labels.reference(copy, source)
        for target, data in candidates.items():
            copy = snapshot / target.name
            copy.write_bytes(data)
            copy.chmod(0o440)
            labels.prepare(copy, target)
        output = command(["unshare", "--mount", "/bin/sh", "-ec",
                          'mount --make-rprivate /; mount --bind "$1" "$2"; exec /usr/sbin/visudo -c',
                          "opg-visudo", snapshot, dropins], capture=True)
        require_sudoers_included(output, candidates)


class Deployment:
    def __init__(self, config, anchor=Path("/"), config_gid=0, labels=None):
        self.anchor = anchor
        self.config = config
        self.labels = labels
        self.journal = config.parent / JOURNAL
        self.paths = {
            "launcher": anchor / "usr/local/sbin/opg_active_home_inspect",
            "scanner": anchor / "usr/local/libexec/oracle-patch-guard/opg_active_home.py",
            "policy": config.parent / "active-home-inspect.json",
            "sudoers": anchor / "etc/sudoers.d/oracle-patch-guard-active-home",
            "context": anchor / "etc/sudoers.d/oracle-patch-guard-context",
            "config": config,
            "receipt": config.parent / RECEIPT,
        }
        self.modes = dict(launcher=0o755, scanner=0o644, policy=0o400, sudoers=0o440,
                          context=0o440, config=0o640, receipt=0o644)
        self.gids = dict.fromkeys(self.paths, ROOT_GID)
        self.gids["config"] = config_gid

    def read(self, key, links=(1,)):
        return read_file(self.paths[key], self.modes[key], self.gids[key], links=links)

    def require_local(self, old):
        require(configured(old, MODE, "local") == "local" and not present(self.paths["receipt"])
                and not present(self.journal), "existing privileged deployment requires the central host opt-in")

    def recorded(self, bundle, home, policy):
        return {"version": 1, "home": home, "binding": policy, "files": {
            key: {"sha256": sha(data), "stat": stamp(self.paths[key])} for key, data in bundle.items()}}

    def previous(self, home, binding):
        keys = tuple(SOURCES) + ("policy",)
        existing = {key: self.read(key) for key in keys if present(self.paths[key])}
        if not existing and not present(self.paths["receipt"]):
            require(configured(self.read("config") if present(self.config) else b"", MODE, "local") == "local",
                    "active host config has no privileged deployment")
            return
        require(existing.keys() == set(keys), "incomplete or unknown privileged deployment")
        old = decoded(existing["policy"])
        require(old.keys() == binding.keys() and all(old[key] == binding[key] for key in ("uid", "gid", "oracle_home"))
                and old["namespaces"].keys() == set(NAMESPACES)
                and all(re.fullmatch(key + r":\[[0-9]+\]", value) for key, value in old["namespaces"].items())
                and all(old["namespaces"][key] == value for key, value in INITIAL.items()),
                "existing policy has an unknown host/principal binding")
        if present(self.paths["receipt"]):
            prior = decoded(self.read("receipt"))
            require(prior == self.recorded(existing, home, old), "installed Active Home files drift from last deployment")
            self.labels.verify(self.paths["receipt"])
        else:
            require(all(sha(existing[key]) == digest for key, digest in BASELINE.items()),
                    "unrecognized manual Active Home deployment")
        for key in existing:
            self.labels.verify(self.paths[key])

    def stage(self, path, data, mode, gid):
        fd, raw = tempfile.mkstemp(prefix=PREFIX, dir=str(path.parent))
        candidate = Path(raw)
        try:
            with os.fdopen(fd, "wb") as stream:
                os.fchown(stream.fileno(), ROOT_UID, gid)
                os.fchmod(stream.fileno(), mode)
                stream.write(data)
                stream.flush()
                self.labels.prepare(candidate, path)
                os.fsync(stream.fileno())
            return candidate
        except BaseException:
            candidate.unlink()
            raise

    def save_journal(self, record):
        temporary = self.stage(self.journal, encoded(record), 0o600, ROOT_GID)
        try:
            os.replace(str(temporary), str(self.journal))
            sync(self.journal.parent)
        finally:
            if present(temporary):
                temporary.unlink()

    def backup(self, path, record):
        return path.with_name(PREFIX + record["id"] + "-" + path.name)

    def recover(self, record):
        require(re.fullmatch(r"[a-f0-9]{32}", record["id"]) is not None
                and record["before"].keys() <= self.paths.keys(), "invalid recovery journal")
        # Disable the candidate before replacing a single old component.
        policy = self.paths["policy"]
        if "policy" in record["before"] and present(policy) and stamp(policy) != record["before"]["policy"]:
            metadata(policy, self.modes["policy"], ROOT_GID)
            policy.unlink()
            sync(policy.parent)
        # Recover in reverse deployment order, keeping the old policy for last.
        for key in ("receipt", "config", "sudoers", "context", "scanner", "launcher", "policy"):
            if key not in record["before"]:
                continue
            previous = record["before"][key]
            path = self.paths[key]
            backup = self.backup(path, record)
            if previous is None:
                if present(path):
                    metadata(path, self.modes[key], self.gids[key])
                    path.unlink()
            elif present(backup):
                metadata(backup, self.modes[key], self.gids[key], links=(1, 2))
                require(stamp(backup) == previous, "recovery file drift: {}".format(backup))
                if present(path) and stamp(path) == previous:
                    backup.unlink()
                else:
                    os.replace(str(backup), str(path))
            else:
                require(stamp(path) == previous, "previous deployment file unavailable: {}".format(path))
            sync(path.parent)
        self.journal.unlink()
        sync(self.journal.parent)

    def publish(self, key, data):
        path = self.paths[key]
        candidate = self.stage(path, data, self.modes[key], self.gids[key])
        try:
            os.replace(str(candidate), str(path))
            sync(path.parent)
            self.labels.verify(path)
            require(self.read(key) == data, "publication differs: {}".format(path))
        finally:
            if present(candidate):
                candidate.unlink()

    def activate(self, data, bundle, binding):
        home = binding["oracle_home"]
        changes = {key: value for key, value in data.items()
                   if not present(self.paths[key]) or self.read(key) != value}
        if not changes and present(self.paths["receipt"]):
            return
        if changes.keys() & bundle.keys() and "policy" not in changes:
            changes["policy"] = bundle["policy"]  # Prevent reads across helper generations.
        record = {"id": uuid.uuid4().hex, "home": home, "before": {
            key: stamp(self.paths[key]) if present(self.paths[key]) else None
            for key in tuple(changes) + ("receipt",)}}
        removing_journal = False
        try:
            self.save_journal(record)
            for key, previous in record["before"].items():
                if previous is not None:
                    path = self.paths[key]
                    os.link(str(path), str(self.backup(path, record)), follow_symlinks=False)
                    sync(path.parent)
            if "policy" in changes and present(self.paths["policy"]):
                self.paths["policy"].unlink()
                sync(self.paths["policy"].parent)
            for key in ("launcher", "scanner", "context", "sudoers", "policy", "config"):
                if key in changes:
                    self.publish(key, changes[key])
            require_sudoers_included(command(["/usr/sbin/visudo", "-c"], capture=True),
                                     [self.paths["sudoers"], self.paths["context"]])
            self.publish("receipt", encoded(self.recorded(bundle, home, binding)))
            removing_journal = True
            self.journal.unlink()
            sync(self.journal.parent)
        except BaseException:
            # If the journal replacement failed before any mutation there is nothing to recover.
            if present(self.journal):
                self.recover(record)
            elif removing_journal:
                self.save_journal(record)
                self.recover(record)
            raise
        for key in record["before"]:
            backup = self.backup(self.paths[key], record)
            if present(backup):
                try:
                    backup.unlink()
                    sync(backup.parent)
                except OSError as error:
                    print("OPG_ACTIVE_HOME_DEPLOY|committed_backup_retained={}".format(error), file=sys.stderr)

    def check(self, data, release, home):
        require(not present(self.journal), "Active Home deployment transaction is incomplete")
        require(self.read("config") == data, "central and installed effective configurations differ")
        prior = decoded(self.read("receipt"))
        require(prior["version"] == 1 and prior["home"] == home
                and prior["files"].keys() == set(SOURCES) | {"policy"}, "invalid deployment receipt")
        for key, expected in prior["files"].items():
            path = self.paths[key]
            directory_chain(path.parent, self.anchor)
            metadata(path, self.modes[key], self.gids[key])
            require(stamp(path) == expected["stat"], "installed file drift: {}".format(path))
            if key in SOURCES:
                source = read_file(release / SOURCES[key], gid=ROOT_GID)
                require(sha(source) == expected["sha256"], "installed release differs: {}".format(path))
                if key != "sudoers":
                    require(self.read(key) == source, "installed helper bytes differ: {}".format(path))
        sudo = sudo_binary(self.anchor)
        output = command([sudo, "-n", "-u", "root", "--", self.paths["launcher"], "visibility"], capture=True)
        marker = "OPG_ACTIVE_HOME_INSPECTION|version=1|mode=visibility|home={}|exit_code=0".format(home)
        require(output.decode("ascii").splitlines() == ["PROC_COVERAGE_CONFIRMED", marker],
                "privileged visibility was not confirmed")
        require(not present(self.journal) and self.read("receipt") == encoded(prior),
                "Active Home deployment changed during PREPARE")


def install(release, root, staged, config, user, group, anchor):
    require(os.geteuid() == 0 and anchor == Path("/"), "privileged deployment requires host root")
    node = hostname()
    home = host_policy(root, node.lower(), anchor)
    require(home is not None, "explicit privileged host policy disappeared")
    directory_chain(release, anchor)
    require((root / "current").resolve(strict=True) == release, "current changed before BOOTSTRAP")
    base = read_file(staged / "SRC_CONFIG", 0o600, ROOT_GID)
    data = effective_config(base, home)
    lockroot = configured(base, "LOCK_ROOT", "")
    oratab = configured(base, "ORATAB_FILE", "/etc/oratab")
    require(canonical(oratab), "invalid ORATAB_FILE")
    directory_chain(Path(oratab).parent, anchor)
    account = pwd.getpwnam(user)
    gid = grp.getgrnam(group).gr_gid
    binding = oracle_binding(home, Path(oratab), account)
    deployment = Deployment(config, anchor, gid)
    if present(config):
        directory_chain(config.parent, anchor)
        old = deployment.read("config", links=(1, 2))
        require(configured(old, "LOCK_ROOT", "") == lockroot
                and configured(old, "ORATAB_FILE", "/etc/oratab") == oratab,
                "regular bootstrap cannot change the lock root or oratab binding")
    with patch_lock(Path(lockroot), node, home, account.pw_uid, gid, anchor):
        sudo_binary(anchor)
        deployment.labels = Labels()
        for key, path in deployment.paths.items():
            directory_chain(path.parent, anchor, create=key in ("launcher", "scanner", "policy"))
        if present(deployment.journal):
            pending = decoded(read_file(deployment.journal, 0o600, ROOT_GID))
            require(pending["home"] == home, "interrupted deployment belongs to a different Oracle Home")
            deployment.recover(pending)
        deployment.previous(home, binding)
        bundle = {}
        for key, relative in SOURCES.items():
            source = release / relative
            directory_chain(source.parent, anchor)
            bundle[key] = read_file(source, gid=ROOT_GID)
        for key in ("launcher", "scanner"):
            compile(bundle[key], SOURCES[key], "exec")
        require(user == "oracle" and sha(bundle["sudoers"]) == BASELINE["sudoers"],
                "unexpected Active Home sudo grant or runtime account")
        bundle["policy"] = encoded(binding)
        context = read_file(staged / "SRC_SUDOERS", 0o600, ROOT_GID)
        validate_sudoers(deployment.paths, {deployment.paths["sudoers"]: bundle["sudoers"],
                                           deployment.paths["context"]: context}, deployment.labels)
        base_path = str(root / "current")
        command(["/bin/bash", release / "oem-tasks/opg_bootstrap_host.sh", "--privileged-base", staged, base_path],
                env=dict(TOOLS, OPG_BOOTSTRAP_BASE=base_path), timeout=300)
        require((root / "current").resolve(strict=True) == release
                and host_policy(root, node.lower(), anchor) == home
                and read_file(root / "config/patchGD_guard.conf") == base,
                "central release or effective host policy changed during BOOTSTRAP")
        deployment.activate(dict(bundle, context=context, config=data), bundle, binding)
        print("OPG_ACTIVE_HOME_DEPLOY|home={}|labels={}|visibility=UNVERIFIED".format(
            home, "verified" if deployment.labels.enforcing else "disabled"))


def main(args):
    action, *values = args
    require(action in ("mode", "install", "check"), "invalid Active Home deployment action")
    anchor = Path(values.pop() or "/")
    if action == "install":
        release, root, staged, config, user, group = values
        install(Path(release), Path(root), Path(staged), Path(config), user, group, anchor)
        return
    source, config, root = map(Path, values)
    home = host_policy(root, hostname().lower(), anchor) if present(root / "config/hosts") else None
    if home is not None and action == "check":
        directory_chain(source.parent, anchor)
    central = read_file(source) if home is not None else source.read_bytes()
    config_gid = grp.getgrnam("root" if anchor != Path("/") else "oinstall").gr_gid
    deployment = Deployment(config, anchor, config_gid)
    data = effective_config(central, home)
    if home is None:
        old = deployment.read("config") if present(config) else b""
        deployment.require_local(old)
        if action == "check":
            require(old == data, "central and installed local configurations differ")
    elif action == "check":
        deployment.check(data, (root / "current").resolve(strict=True), home)
    if action == "mode":
        print("privileged" if home is not None else "local")


def interrupted(signum, _frame):
    # Do not let a second TERM interrupt repair of the previous deployment.
    signal.signal(signum, signal.SIG_IGN)
    raise InterruptedError("Active Home bootstrap interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, AttributeError, SyntaxError, subprocess.SubprocessError) as error:
        print("OPG_ACTIVE_HOME_DEPLOY|status=BLOCKED|reason={}".format(error), file=sys.stderr)
        sys.exit(30)
