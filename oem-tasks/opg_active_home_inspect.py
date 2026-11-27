#!/usr/bin/python3 -IBS
"""Privileged entry point for one root-configured Oracle Home."""

import ctypes
import hashlib
import json
import os
from os import readlink
from pathlib import Path
import re
import signal
import stat
import sys


POLICY = Path("/etc/oracle-patch-guard/active-home-inspect.json")
SCANNER_DIR = Path("/usr/local/libexec/oracle-patch-guard")
DEPLOYMENT_ID = None  # Replaced by the host installer in the deployed launcher.
SCANNER_SHA256 = None  # Replaced by the host installer in the deployed launcher.
NAMESPACES = ("pid", "mnt", "user")
# Reserved initial namespace inodes from Linux include/linux/proc_ns.h.
INITIAL_NAMESPACES = {"pid": "pid:[4026531836]", "user": "user:[4026531837]"}
MAX_POLICY_SIZE = 4096
MAX_SCANNER_SIZE = 1024 * 1024
PROTOCOL_VERSION = 1

# Linux capability and prctl ABI. No exec is needed after reducing privileges.
CAP_SYS_PTRACE = 1 << 19
CAP_VERSION_3 = 0x20080522
PR_SET_DUMPABLE = 4
PR_SET_KEEPCAPS = 8
PR_CAPBSET_DROP = 24
PR_SET_NO_NEW_PRIVS = 38
PR_CAP_AMBIENT = 47
PR_CAP_AMBIENT_CLEAR_ALL = 4


class CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class CapData(ctypes.Structure):
    _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32),
                ("inheritable", ctypes.c_uint32)]


class InspectionTimeout(Exception):
    pass


def require_trusted_file(path, mode):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or (metadata.st_uid, metadata.st_gid, metadata.st_nlink) != (0, 0, 1)
            or stat.S_IMODE(metadata.st_mode) != mode):
        raise PermissionError("untrusted file: {}".format(path))
    for parent in path.parents:
        metadata = parent.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise PermissionError("untrusted parent: {}".format(parent))


def unique_fields(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("duplicate policy field")
    return fields


def load_policy():
    require_trusted_file(POLICY, 0o400)
    with POLICY.open("rb") as source:
        raw = source.read(MAX_POLICY_SIZE + 1)
    if len(raw) > MAX_POLICY_SIZE:
        raise ValueError("oversized policy")
    policy = json.loads(raw.decode("ascii"), object_pairs_hook=unique_fields)
    if not isinstance(policy, dict) or policy.keys() != {
            "uid", "gid", "oracle_home", "namespaces", "deployment_id", "scanner_sha256"}:
        raise ValueError("invalid policy fields")
    for name in ("deployment_id", "scanner_sha256"):
        if not isinstance(policy[name], str) or not re.fullmatch(r"[a-f0-9]{64}", policy[name]):
            raise ValueError("invalid " + name)
    if (policy["deployment_id"], policy["scanner_sha256"]) != (DEPLOYMENT_ID, SCANNER_SHA256):
        raise ValueError("launcher and policy belong to different deployments")
    for key in ("uid", "gid"):
        value = policy[key]
        if type(value) is not int or not 0 < value < 4294967295:
            raise ValueError("invalid {} in policy".format(key))
    home = policy["oracle_home"]
    if (not isinstance(home, str) or not re.fullmatch(r"/[A-Za-z0-9_./-]+", home)
            or any(part in ("", ".", "..") for part in home[1:].split("/"))):
        raise ValueError("invalid Oracle Home policy path")
    namespaces = policy["namespaces"]
    if not isinstance(namespaces, dict) or namespaces.keys() != set(NAMESPACES):
        raise ValueError("invalid namespace policy")
    for name, identity in namespaces.items():
        if not isinstance(identity, str) or not re.fullmatch(re.escape(name) + r":\[[0-9]+\]", identity):
            raise ValueError("invalid namespace identity")
    return policy


def host_namespaces():
    if readlink("/proc/self") != str(os.getpid()):
        raise PermissionError("procfs PID view does not match the caller")
    namespaces = {}
    for name in NAMESPACES:
        identity = readlink("/proc/1/ns/" + name)
        if (not re.fullmatch(name + r":\[[0-9]+\]", identity)
                or INITIAL_NAMESPACES.get(name, identity) != identity
                or readlink("/proc/self/ns/" + name) != identity):
            raise PermissionError("host namespace cannot be proven: " + name)
        namespaces[name] = identity
    return namespaces


def require_host_namespaces(namespaces):
    if host_namespaces() != namespaces:
        raise PermissionError("host namespace binding changed")


def verified_scanner(digest):
    path = SCANNER_DIR / ("opg_active_home-" + digest + ".py")
    require_trusted_file(path, 0o644)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or (info.st_uid, info.st_gid, info.st_nlink) != (0, 0, 1)
                or stat.S_IMODE(info.st_mode) != 0o644):
            raise PermissionError("untrusted open scanner: {}".format(path))
        data = source.read(MAX_SCANNER_SIZE + 1)
    if len(data) > MAX_SCANNER_SIZE or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("scanner SHA-256 differs from policy")
    scope = {"__name__": "opg_active_home", "__file__": str(path)}
    exec(compile(data, str(path), "exec"), scope)
    return scope["inspect_proc"]


def status_fields():
    with open("/proc/self/status", encoding="ascii") as source:
        return dict(line.rstrip("\n").split(":\t", 1) for line in source if ":\t" in line)


def set_process_option(libc, option, value, third=0):
    if libc.prctl(option, value, third, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl({})".format(option))


def restrict_observer(uid, gid):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = (ctypes.c_int,) + (ctypes.c_ulong,) * 4
    libc.capset.argtypes = (ctypes.POINTER(CapHeader), ctypes.POINTER(CapData))
    status = status_fields()
    if not int(status["CapPrm"], 16) & CAP_SYS_PTRACE:
        raise PermissionError("CAP_SYS_PTRACE unavailable")
    set_process_option(libc, PR_SET_NO_NEW_PRIVS, 1)
    set_process_option(libc, PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL)
    bounding = int(status["CapBnd"], 16)
    for capability in range(bounding.bit_length()):
        if bounding & (1 << capability):
            set_process_option(libc, PR_CAPBSET_DROP, capability)
    set_process_option(libc, PR_SET_KEEPCAPS, 1)
    os.setgroups([])
    os.setresgid(gid, gid, gid)
    os.setresuid(uid, uid, uid)
    data = (CapData * 2)(CapData(CAP_SYS_PTRACE, CAP_SYS_PTRACE, 0), CapData())
    if libc.capset(ctypes.byref(CapHeader(CAP_VERSION_3, 0)), data) != 0:
        raise OSError(ctypes.get_errno(), "capset")
    set_process_option(libc, PR_SET_KEEPCAPS, 0)
    set_process_option(libc, PR_SET_DUMPABLE, 0)
    status = status_fields()
    caps = tuple(int(status[name], 16) for name in ("CapEff", "CapPrm", "CapInh", "CapAmb", "CapBnd"))
    if (os.getresuid() != (uid,) * 3 or os.getresgid() != (gid,) * 3 or os.getgroups()
            or caps != (CAP_SYS_PTRACE, CAP_SYS_PTRACE, 0, 0, 0) or status["NoNewPrivs"] != "1"):
        raise PermissionError("observer privilege reduction could not be confirmed")


def main(args):
    try:
        if args not in (["visibility"], ["scan"]):
            raise ValueError("expected exactly one of visibility or scan")
        if os.getuid() != 0 or os.geteuid() != 0:
            raise PermissionError("sudo root entry required")
        policy = load_policy()
        uid, gid, home = policy["uid"], policy["gid"], policy["oracle_home"]
        if (os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")) != (str(uid), str(gid)):
            raise PermissionError("caller is not authorized for this Oracle Home")
        require_host_namespaces(policy["namespaces"])
        restrict_observer(uid, gid)
        metadata = os.stat(home)
        if os.path.realpath(home) != home or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid:
            raise PermissionError("Oracle Home binding is not canonical or owner does not match")
        inspect = verified_scanner(policy["scanner_sha256"])
        mode = args[0]
        result = inspect(None if mode == "visibility" else os.fsencode(home))
        if result == 0 or (result == 20 and mode == "scan"):
            print("OPG_ACTIVE_HOME_INSPECTION|version={}|mode={}|home={}|exit_code={}".format(
                PROTOCOL_VERSION, mode, home, result))
            return result
    except (OSError, KeyError, ValueError, SyntaxError, InspectionTimeout) as error:
        print("OPG_ACTIVE_HOME_INSPECTION_UNKNOWN|version={}|reason={}".format(
            PROTOCOL_VERSION, json.dumps(str(error))))
    return 30


def timed_out(_signum, _frame):
    raise InspectionTimeout("inspection deadline exceeded")


if __name__ == "__main__":
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(55)
    sys.exit(main(sys.argv[1:]))
