#!/usr/bin/env python3
"""Inspect live executables and file mappings on Linux without changing them."""

import errno
import json
import os
from os import readlink
import subprocess
import sys


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
    with open("/proc/self/mountinfo", "rb") as mountinfo:
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
    pids = [entry for entry in os.listdir(b"/proc") if entry.isdigit()]
    if str(os.getpid()).encode("ascii") not in pids:
        raise ValueError("eigen PID ontbreekt in /proc")
    return pids


def scan_proc(home):
    hits = set()
    first_error = None
    limited = 0
    for pid in proc_pids():
        proc = b"/proc/" + pid
        try:
            paths = set()
            with open(proc + b"/maps", "rb") as maps:
                if home is None:
                    maps.read(1)  # Preflight checks access while Oracle is still online.
                else:
                    for line in maps:
                        fields = line.split(None, 5)
                        if len(fields) == 6 and fields[4] != b"0" and in_home(fields[5], home):
                            paths.add(fields[5].rstrip(b"\n"))
            try:
                executable = readlink(proc + b"/exe")
                if home is not None and in_home(executable, home):
                    paths.add(executable)
            except FileNotFoundError:
                # An exited leader can leave live threads behind. A solitary
                # zombie or kernel thread has no remaining user mappings.
                if len(os.listdir(proc + b"/task")) > 1:
                    first_error = first_error or "pid={} executable_unavailable".format(int(pid))
            if paths:
                uid, command = process_identity(proc)
                hits.update((int(pid), uid, command, path) for path in paths)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EPERM):
                uids = process_uids(proc)
                if uids and os.geteuid() not in uids:
                    limited += 1
                    continue
            if not isinstance(error, FileNotFoundError) or os.path.isdir(proc):
                first_error = first_error or "pid={} errno={}".format(int(pid), error.errno)
    if limited:
        print("PROC_COVERAGE_LIMITED|owner_uid={}|outside_uid_denials={}".format(os.geteuid(), limited))
    return hits, first_error


def process_uids(proc):
    try:
        with open(proc + b"/status", "rb") as status:
            uids = next(line.split()[1:] for line in status if line.startswith(b"Uid:"))
        if len(uids) == 4:
            return {int(uid) for uid in uids}
    except (OSError, StopIteration, ValueError):
        pass
    return set()


def process_identity(proc):
    try:
        with open(proc + b"/status", "rb") as status:
            uid = next(line.split()[2] for line in status if line.startswith(b"Uid:"))
        with open(proc + b"/comm", "rb") as comm:
            return int(uid), comm.read().rstrip(b"\n")
    except (OSError, StopIteration):
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
