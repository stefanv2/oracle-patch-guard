#!/usr/bin/env python3
"""Inspect live executables and file mappings on Linux without changing them."""

import errno
import json
import os
from os import readlink
import subprocess
import sys


PROC_ROOT = b"/proc"
PROCESS_GONE = (errno.ENOENT, errno.ESRCH)


def in_home(path, home):
    return path.startswith(home + b"/")


def report_hit(pid, uid, command, path):
    print("ACTIVE_HOME_FILE|pid={}|uid={}|process={}|file={}".format(
        pid, uid, json.dumps(os.fsdecode(command)), json.dumps(os.fsdecode(path))))


def parse_lsof(output, home):
    hits = set()
    records = output.split(b"\0\n")
    if records.pop():
        raise ValueError("onvolledige lsof-records")
    pid = None
    for record in records:
        fields = record.split(b"\0")
        values = {field[:1]: field[1:] for field in fields}
        if len(fields) != len(values):
            raise ValueError("dubbel lsof-veld")
        if fields[0].startswith(b"p") and values[b"p"].isdigit() and values.keys() <= {b"p", b"c", b"u"}:
            pid = int(values[b"p"])
            uid = values.get(b"u", b"")
            if uid and not uid.isdigit():
                raise ValueError("ongeldige lsof-UID")
            uid = int(uid) if uid else "UNKNOWN"
            command = values.get(b"c", b"")
        elif (pid is not None and fields[0] in (b"ftxt", b"fmem", b"fDEL")
              and values.keys() <= {b"f", b"t", b"n"} and values.get(b"t") and values.get(b"n")):
            path = values[b"n"]
            if in_home(path, home):
                hits.add((pid, uid, command, path))
        else:
            raise ValueError("onherkenbare lsof-record")
    return hits


def proc_pids():
    # A hidden PID must not be mistaken for an unrelated process or no match.
    with open(PROC_ROOT + b"/self/mountinfo", "rb") as mountinfo:
        mounts = [line.split(b" - ", 1) for line in mountinfo
                  if line.split()[4:5] == [b"/proc"]]
    if len(mounts) != 1:
        raise ValueError("volledige /proc-mount niet aantoonbaar")
    mount, filesystem = (part.split() for part in mounts[0])
    options = mount[5].split(b",") + filesystem[2].split(b",")
    if (filesystem[0] != b"proc" or mount[3] != b"/"
            or any(option.startswith(b"hidepid=") and option not in (b"hidepid=0", b"hidepid=off")
                   for option in options)):
        raise ValueError("/proc kan processen verbergen")
    pids = [entry for entry in os.listdir(PROC_ROOT) if entry.isdigit()]
    if str(os.getpid()).encode("ascii") not in pids:
        raise ValueError("eigen PID ontbreekt in /proc")
    return pids


def proc_file(proc_fd, name):
    return os.fdopen(os.open(name, os.O_RDONLY, dir_fd=proc_fd), "rb")


def process_exited(proc_fd):
    # status is present for a live PID, even when maps or exe is unreadable.
    # Use the same proc directory FD so PID reuse cannot confirm the wrong task.
    try:
        with proc_file(proc_fd, b"status") as status:
            status.read(1)
    except OSError as error:
        return error.errno in PROCESS_GONE
    return False


def scan_proc(home):
    hits = set()
    first_error = None
    incomplete = 0
    for pid in proc_pids():
        proc_fd = None
        entry = "pid"
        paths = set()
        has_mappings = False
        try:
            proc_fd = os.open(PROC_ROOT + b"/" + pid, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            entry = "maps"
            with proc_file(proc_fd, b"maps") as maps:
                if home is None:
                    has_mappings = bool(maps.read(1))
                else:
                    for line in maps:
                        has_mappings = True
                        fields = line.split(None, 5)
                        if len(fields) == 6 and fields[4] != b"0" and in_home(fields[5], home):
                            paths.add(fields[5].rstrip(b"\n"))
            entry = "exe"
            try:
                executable = readlink(b"exe", dir_fd=proc_fd)
                if home is not None and in_home(executable, home):
                    paths.add(executable)
            except FileNotFoundError:
                # Empty maps and a lone thread account for an absent exe
                # (e.g. a zombie or kernel thread). A dead leader may have
                # left live threads with mappings we cannot see here.
                if has_mappings:
                    raise
                entry = "status"
                with proc_file(proc_fd, b"status") as status:
                    if not any(line.split() == [b"Threads:", b"1"] for line in status):
                        entry = "exe"
                        raise
        except OSError as error:
            gone = error.errno in PROCESS_GONE and (proc_fd is None or process_exited(proc_fd))
            if not gone:
                incomplete += 1
                first_error = first_error or "pid={} entry={} errno={}".format(int(pid), entry, error.errno)
        finally:
            if proc_fd is not None:
                if paths:
                    uid, command = process_identity(proc_fd)
                    hits.update((int(pid), uid, command, path) for path in paths)
                os.close(proc_fd)
    if incomplete:
        first_error += "|uninspected_pids={}".format(incomplete)
    return hits, first_error


def process_identity(proc_fd):
    try:
        with proc_file(proc_fd, b"status") as status:
            uid = next(line.split()[2] for line in status if line.startswith(b"Uid:"))
        with proc_file(proc_fd, b"comm") as comm:
            return int(uid), comm.read().rstrip(b"\n")
    except (OSError, StopIteration, IndexError, ValueError):
        return "UNKNOWN", b""


def main(home, advisory=False):
    try:
        if home == "--visibility":
            _, incomplete = scan_proc(None)
            if incomplete:
                print("PROC_COVERAGE_UNKNOWN|" + incomplete)
                return 30
            print("PROC_COVERAGE_CONFIRMED")
            return 0
        home = os.fsencode(home)
        result = subprocess.run(
            ["lsof", "-nP", "-a", "-d", "txt,mem,DEL", "-F0pcuftn"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        print("LSOF_RESULT|exit_code={}".format(result.returncode))
        if result.stderr:
            print("LSOF_DIAGNOSTIC|message={}".format(json.dumps(os.fsdecode(result.stderr))))
            return 30
        if not ((result.returncode == 0 and result.stdout) or
                (result.returncode == 1 and not result.stdout)):
            print("LSOF_OUTPUT_UNKNOWN")
            return 30
        hits = parse_lsof(result.stdout, home)
        if advisory:
            for hit in sorted(hits, key=lambda item: (item[0], item[3])):
                try:
                    executable = readlink("/proc/{}/exe".format(hit[0]))
                except OSError:
                    continue
                if os.fsencode(executable) not in (home + b"/bin/oracle", home + b"/bin/tnslsnr"):
                    report_hit(*hit)
            return 0
        if not hits:
            # lsof can omit mappings silently. Its empty result needs independent
            # corroboration, including cross-UID visibility of live processes.
            hits, incomplete = scan_proc(home)
            if incomplete:
                print("PROC_COVERAGE_UNKNOWN|" + incomplete)
                if not hits:
                    return 30
        for hit in sorted(hits, key=lambda item: (item[0], item[3])):
            report_hit(*hit)
        if hits:
            return 20
        print("ACTIVE_HOME_SCAN_CLEAR")
        return 0
    except (OSError, ValueError) as error:
        print("FILE_INSPECTION_UNKNOWN|reason={}".format(json.dumps(str(error))))
        return 30


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:] == ["--advisory"]))
