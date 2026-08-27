#!/usr/bin/python3 -I
"""Strictly bounded Pilot07 local-media publisher and verifier."""

import hashlib
import errno
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath

EXIT_BLOCKED = 20
EXIT_UNKNOWN = 30
SAFE_CYCLE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{0,63}$")
SAFE_PATCH = re.compile(r"^[0-9]{6,12}$")
SAFE_ZIP = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}\.zip$")
SAFE_HASH = re.compile(r"^[0-9a-f]{64}$")
SAFE_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){3,5}$")
FORMAT = "OPG_TREE_HASH_V2"
TRUSTED_STAGE_ANCHOR = Path("/u01/stage")


def die(code, message):
    print(f"OPG_MEDIA_ERROR|exit_code={code}|message={message}", file=sys.stderr)
    raise SystemExit(code)


def sha256_file(path):
    h = hashlib.sha256()
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        die(EXIT_BLOCKED, f"geen veilig regulier bestand: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            die(EXIT_BLOCKED, f"bestand verwisseld tijdens open: {path}")
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            h.update(block)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, f) != getattr(after, f) for f in fields):
        die(EXIT_BLOCKED, f"bestand wijzigde tijdens hashing: {path}")
    return h.hexdigest(), before.st_size


def read_stable_bytes(path, maximum):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or path.is_symlink() or before.st_size > maximum:
        die(EXIT_BLOCKED, f"onveilig of te groot metadata-artifact: {path}")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        data = b""
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block: break
            data += block
            if len(data) > maximum: die(EXIT_BLOCKED, f"metadata-artifact overschrijdt limiet: {path}")
        after = os.fstat(fd)
    finally:
        os.close(fd)
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, f) != getattr(after, f) for f in fields):
        die(EXIT_BLOCKED, f"metadata-artifact wijzigde tijdens lezen: {path}")
    return data


def copy_once_and_hash(source, target):
    before = source.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or source.is_symlink():
        die(EXIT_BLOCKED, f"onveilige transportbron: {source}")
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    target_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o440)
    h = hashlib.sha256(); total = 0
    try:
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            die(EXIT_BLOCKED, f"transportbron verwisseld tijdens open: {source}")
        while True:
            block = os.read(source_fd, 1024 * 1024)
            if not block: break
            h.update(block); total += len(block)
            view = memoryview(block)
            while view:
                written = os.write(target_fd, view)
                view = view[written:]
        os.fsync(target_fd)
        after = os.fstat(source_fd)
    finally:
        os.close(source_fd); os.close(target_fd)
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, f) != getattr(after, f) for f in fields) or total != before.st_size:
        die(EXIT_BLOCKED, f"transportbron wijzigde tijdens copy: {source}")
    return h.hexdigest(), total


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        die(EXIT_BLOCKED, f"ongeldige tree-root: {root}")
    result = {}
    for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
        base_path = Path(base)
        for name in list(dirs):
            path = base_path / name
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode) or path.is_symlink():
                die(EXIT_BLOCKED, f"symlink/speciaal object in tree: {path}")
        for name in files:
            path = base_path / name
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or path.is_symlink():
                die(EXIT_BLOCKED, f"symlink/hardlink/speciaal object in tree: {path}")
            rel = os.fsencode(os.path.relpath(path, root))
            if rel.startswith(b"/") or b"\x00" in rel or any(p in (b"", b".", b"..") for p in rel.split(b"/")):
                die(EXIT_BLOCKED, f"ongeldig relatief pad in tree: {path}")
            result[rel] = (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
                           info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    return result


def tree_hash_v2(root):
    first = inventory(root)
    combined = hashlib.sha256(b"OPG_TREE_HASH_V2\x00")
    for rel in sorted(first):
        file_path = root / os.fsdecode(rel)
        digest, size = sha256_file(file_path)
        record = (b"F\x00" + str(size).encode("ascii") + b"\x00" + digest.encode("ascii") +
                  b"\x00" + str(len(rel)).encode("ascii") + b"\x00" + rel)
        combined.update(record)
    second = inventory(root)
    if first != second:
        die(EXIT_BLOCKED, f"tree wijzigde tijdens hashing: {root}")
    return combined.hexdigest()


def read_single_line(path):
    if path.is_symlink() or not path.is_file():
        die(EXIT_BLOCKED, f"ontbrekend/onveilig bestand: {path}")
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) != 1:
        die(EXIT_BLOCKED, f"bestand moet exact één waarde bevatten: {path}")
    return lines[0]


def read_kv(path, allowed, required):
    if path.is_symlink() or not path.is_file():
        die(EXIT_BLOCKED, f"ontbrekende/onveilige configuratie: {path}")
    values = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            die(EXIT_BLOCKED, f"ongeldige configuratieregel {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in allowed or key in values or not value:
            die(EXIT_BLOCKED, f"onbekende/dubbele/lege configuratiesleutel: {key}")
        values[key] = value
    missing = required - values.keys()
    if missing:
        die(EXIT_BLOCKED, f"verplichte configuratiesleutels ontbreken: {','.join(sorted(missing))}")
    return values


def validate_manifest(data, cycle, conf):
    if not isinstance(data, dict) or set(data) != {"schema_version", "patch_cycle", "created_at", "tree_hash_format", "artifacts"}:
        die(EXIT_BLOCKED, "artifact-manifest heeft onbekende of ontbrekende velden")
    if data["schema_version"] != 1 or data["patch_cycle"] != cycle or data["tree_hash_format"] != FORMAT:
        die(EXIT_BLOCKED, "artifact-manifest schema/cycle/hashformaat klopt niet")
    if not isinstance(data["created_at"], str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", data["created_at"]):
        die(EXIT_BLOCKED, "artifact-manifest created_at is niet canonical UTC")
    artifacts = data["artifacts"]
    if not isinstance(artifacts, dict) or set(artifacts) != {"db_ru", "ojvm", "opatch"}:
        die(EXIT_BLOCKED, "artifact-sectie is ongeldig")
    mapping = (("db_ru", "DB_RU_PATCH_ID", "DB_RU_ZIP", "DB_RU_ZIP_SHA256"),
               ("ojvm", "OJVM_PATCH_ID", "OJVM_ZIP", "OJVM_ZIP_SHA256"))
    for name, id_key, zip_key, hash_key in mapping:
        item = artifacts[name]
        if not isinstance(item, dict) or set(item) != {"patch_id", "filename", "size", "sha256"}:
            die(EXIT_BLOCKED, f"ongeldig {name}-artifact")
        if not SAFE_PATCH.fullmatch(str(item["patch_id"])) or item["patch_id"] != conf[id_key]:
            die(EXIT_BLOCKED, f"{name} patch-ID mismatch")
        validate_zip_item(item, conf[zip_key], conf[hash_key])
    item = artifacts["opatch"]
    if not isinstance(item, dict) or set(item) != {"version", "filename", "size", "sha256"}:
        die(EXIT_BLOCKED, "ongeldig OPatch-artifact")
    if not SAFE_VERSION.fullmatch(str(item["version"])) or item["version"] != conf["OPATCH_VERSION"]:
        die(EXIT_BLOCKED, "OPatch-versie mismatch")
    validate_zip_item(item, conf["OPATCH_ZIP"], conf["OPATCH_ZIP_SHA256"])
    return artifacts


def validate_zip_item(item, filename, expected_hash):
    if not SAFE_ZIP.fullmatch(str(item["filename"])) or item["filename"] != filename:
        die(EXIT_BLOCKED, "ZIP-bestandsnaam mismatch")
    if not isinstance(item["size"], int) or isinstance(item["size"], bool) or item["size"] < 1:
        die(EXIT_BLOCKED, "ongeldige ZIP-grootte")
    if not SAFE_HASH.fullmatch(str(item["sha256"])) or item["sha256"] != expected_hash:
        die(EXIT_BLOCKED, "ZIP-checksum mismatch in metadata")


def verify_signature_bytes(public_key, signature_bytes, manifest_bytes):
    with tempfile.TemporaryDirectory(prefix="opg-artifact-signature.") as temporary:
        work = Path(temporary); signature = work / "manifest.sig"; manifest = work / "manifest.json"
        signature.write_bytes(signature_bytes); manifest.write_bytes(manifest_bytes)
        os.chmod(signature, 0o400); os.chmod(manifest, 0o400)
        result = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-verify", str(public_key),
                                 "-signature", str(signature), str(manifest)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if result.returncode != 0:
            die(EXIT_BLOCKED, "artifact-manifest signature is ongeldig")


def validate_public_key(public_key):
    if public_key.is_symlink() or not public_key.is_file():
        die(EXIT_BLOCKED, "artifact public key ontbreekt of is onveilig")
    info = public_key.lstat()
    expected_owner = os.getuid() if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else 0
    if info.st_uid != expected_owner or stat.S_IMODE(info.st_mode) & 0o022:
        die(EXIT_BLOCKED, "artifact public key heeft onveilige owner/mode")
    if os.environ.get("OPG_MEDIA_TEST_MODE") != "1":
        parent = public_key.parent
        while True:
            pinfo = parent.lstat()
            if not stat.S_ISDIR(pinfo.st_mode) or parent.is_symlink() or pinfo.st_uid != 0 or stat.S_IMODE(pinfo.st_mode) & 0o022:
                die(EXIT_BLOCKED, f"artifact-key-parent is onveilig: {parent}")
            if parent == Path("/"): break
            parent = parent.parent


def inspect_zip(zip_path, expected_top, allow_patch_search=False):
    seen = set(); total = 0; count = 0
    with zipfile.ZipFile(zip_path) as archive:
        for entry in archive.infolist():
            if entry.flag_bits & 1:
                die(EXIT_BLOCKED, f"encrypted ZIP-entry geweigerd: {entry.filename}")
            pure = PurePosixPath(entry.filename)
            if not entry.filename or pure.is_absolute() or ".." in pure.parts or "." in pure.parts:
                die(EXIT_BLOCKED, f"onveilig/onverwacht ZIP-pad: {entry.filename}")
            is_patch_search = allow_patch_search and entry.filename == "PatchSearch.xml"
            if pure.parts[0] != expected_top and not is_patch_search:
                die(EXIT_BLOCKED, f"onverwachte top-level ZIP-entry: {entry.filename}")
            canonical = pure.as_posix().rstrip("/")
            if canonical in seen:
                die(EXIT_BLOCKED, f"dubbele ZIP-entry geweigerd: {entry.filename}")
            seen.add(canonical)
            unix_mode = (entry.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(unix_mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                die(EXIT_BLOCKED, f"symlink/speciaal ZIP-object geweigerd: {entry.filename}")
            if is_patch_search and (entry.is_dir() or entry.filename.endswith("/") or kind not in (0, stat.S_IFREG)):
                die(EXIT_BLOCKED, "PatchSearch.xml moet exact één regulier rootbestand zijn")
            if not entry.is_dir() and not entry.filename.endswith("/"):
                total += entry.file_size; count += 1
    return count, total


def safe_extract(zip_path, destination, expected_top, allow_patch_search=False):
    inspect_zip(zip_path, expected_top, allow_patch_search)
    destination.mkdir(mode=0o750)
    with zipfile.ZipFile(zip_path) as archive:
        for entry in archive.infolist():
            if allow_patch_search and entry.filename == "PatchSearch.xml":
                continue
            pure = PurePosixPath(entry.filename)
            target = destination.joinpath(*pure.parts)
            if entry.is_dir() or entry.filename.endswith("/"):
                target.mkdir(parents=True, exist_ok=True, mode=0o750)
                continue
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            unix_mode = (entry.external_attr >> 16) & 0xFFFF
            target_mode = 0o750 if unix_mode & 0o111 else 0o640
            fd = os.open(target, flags, target_mode)
            try:
                with archive.open(entry) as source, os.fdopen(fd, "wb", closefd=False) as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
            finally:
                os.close(fd)
    expected = destination / expected_top
    if expected.is_symlink() or not expected.is_dir():
        die(EXIT_BLOCKED, f"verwachte top-level directory ontbreekt: {expected_top}")
    return expected


def validate_opatch_zip(zip_path, expected_version):
    inspect_zip(zip_path, "OPatch")
    try:
        with zipfile.ZipFile(zip_path) as archive:
            info = archive.getinfo("OPatch/version.txt")
            if info.file_size > 1024 * 1024: die(EXIT_BLOCKED, "OPatch version.txt is onredelijk groot")
            text = archive.read(info).decode("utf-8", "strict")
    except (KeyError, UnicodeError, zipfile.BadZipFile):
        die(EXIT_BLOCKED, "OPatch version.txt ontbreekt of is ongeldig")
    match = re.search(r"^[ \t]*(?:OPATCH_VERSION|OPatch Version)[ \t]*:[ \t]*([^ \t\r\n]+)", text, re.MULTILINE)
    if not match or match.group(1) != expected_version:
        die(EXIT_BLOCKED, "OPatch ZIP bevat niet exact de verwachte versie")


def secure_tree(root, gid, execution_owner):
    management_owner = 0 if os.geteuid() == 0 else os.getuid()
    for base, dirs, files in os.walk(root, topdown=False, followlinks=False):
        for name in files:
            path = Path(base) / name
            info = path.lstat()
            if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                die(EXIT_BLOCKED, f"onveilig stagebestand: {path}")
            relative = path.relative_to(root)
            is_execution_media = relative.parts[0] in ("media", "opatch")
            os.chown(path, execution_owner if is_execution_media else management_owner, gid)
            if is_execution_media:
                os.chmod(path, 0o750 if info.st_mode & 0o111 else 0o640)
            else:
                os.chmod(path, 0o440)
        for name in dirs:
            path = Path(base) / name
            if path.is_symlink() or not path.is_dir():
                die(EXIT_BLOCKED, f"onveilige stagedirectory: {path}")
            relative = path.relative_to(root)
            is_execution_media = relative.parts[0] in ("media", "opatch")
            os.chown(path, execution_owner if is_execution_media else management_owner, gid)
            os.chmod(path, 0o750)
    os.chown(root, management_owner, gid)
    os.chmod(root, 0o750)


def secure_directory(path, gid):
    owner = 0 if os.geteuid() == 0 else os.getuid()
    if path.is_symlink() or not path.is_dir():
        die(EXIT_BLOCKED, f"onveilige stagingdirectory: {path}")
    os.chown(path, owner, gid)
    os.chmod(path, 0o750)


def stage_anchor():
    if os.environ.get("OPG_MEDIA_TEST_MODE") == "1":
        return Path(os.environ["OPG_MEDIA_TEST_ROOT"]) / "u01/stage"
    return TRUSTED_STAGE_ANCHOR


def stage_security_ids(gid):
    if os.environ.get("OPG_MEDIA_TEST_MODE") == "1":
        owner = int(os.environ.get("OPG_MEDIA_TEST_EXPECTED_OWNER_UID", os.getuid()))
        oracle_uid = int(os.environ.get("OPG_MEDIA_TEST_ORACLE_UID", "424242"))
        oracle_groups = {gid, int(os.environ.get("OPG_MEDIA_TEST_ORACLE_GID", gid))}
        return owner, oracle_uid, oracle_groups
    import grp
    import pwd
    oracle = pwd.getpwnam("oracle")
    oracle_groups = set(os.getgrouplist(oracle.pw_name, oracle.pw_gid))
    oracle_groups.add(gid)
    return 0, oracle.pw_uid, oracle_groups


def acl_has_forbidden_write(data, oracle_uid, oracle_groups):
    if len(data) < 4 or struct.unpack_from("<I", data)[0] != 2 or (len(data) - 4) % 8:
        die(EXIT_BLOCKED, "ongeldige POSIX ACL-metadata op lokale stage")
    for offset in range(4, len(data), 8):
        tag, permissions, identifier = struct.unpack_from("<HHI", data, offset)
        if permissions & 0o2 and ((tag == 0x02 and identifier == oracle_uid) or
                                 (tag == 0x08 and identifier in oracle_groups)):
            return True
    return False


def validate_stage_acl(path, oracle_uid, oracle_groups):
    no_acl = {getattr(errno, "ENODATA", 61), getattr(errno, "ENOATTR", 93),
              getattr(errno, "ENOTSUP", 95), getattr(errno, "EOPNOTSUPP", 95)}
    for attribute in ("system.posix_acl_access", "system.posix_acl_default"):
        try:
            data = os.getxattr(path, attribute, follow_symlinks=False)
        except OSError as exc:
            if exc.errno in no_acl:
                continue
            die(EXIT_UNKNOWN, f"POSIX ACL kon niet betrouwbaar worden gelezen: {path}")
        if acl_has_forbidden_write(data, oracle_uid, oracle_groups):
            die(EXIT_BLOCKED, f"oracle/oinstall heeft write-ACL op lokale stage: {path}")


def validate_local_parents(local):
    anchor = stage_anchor()
    gid = roots()[4]
    expected_owner, oracle_uid, oracle_groups = stage_security_ids(gid)
    anchor_gid = os.getgid() if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else 0
    if local != anchor / "oracle-patch-guard":
        die(EXIT_BLOCKED, "lokale stage-root ligt niet direct onder de trusted stage anchor")

    # Boven de anchor is ownership bewust geen trust-eis. Het pad moet wel een
    # echte, niet group/world-writable directoryketen zijn.
    current = anchor.parent
    upper_stop = Path(os.environ["OPG_MEDIA_TEST_ROOT"]) / "u01" if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else Path("/")
    while True:
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or current.is_symlink() or stat.S_IMODE(info.st_mode) & 0o022:
            die(EXIT_BLOCKED, f"stagepad boven trusted anchor is onveilig: {current}")
        if current == upper_stop: break
        if current == Path("/"):
            die(EXIT_BLOCKED, "trusted stage anchor ligt buiten de verwachte padgrens")
        current = current.parent

    current = anchor
    while True:
        info = current.lstat()
        expected_mode = 0o755 if current == anchor else 0o750
        expected_gid = anchor_gid if current == anchor else gid
        if (not stat.S_ISDIR(info.st_mode) or current.is_symlink() or info.st_uid != expected_owner or
                info.st_gid != expected_gid or stat.S_IMODE(info.st_mode) != expected_mode):
            die(EXIT_BLOCKED, f"trusted lokale stage-directory heeft onveilige owner/mode/type: {current}")
        validate_stage_acl(current, oracle_uid, oracle_groups)
        if current == local: break
        current = current / "oracle-patch-guard"


def verify_stage_permissions(stage, pointer, gid):
    management_owner = os.getuid() if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else 0
    _, oracle_uid, oracle_groups = stage_security_ids(gid)
    execution_owner = os.getuid() if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else oracle_uid
    if pointer is not None:
        pinfo = pointer.lstat()
        if not stat.S_ISREG(pinfo.st_mode) or pinfo.st_uid != management_owner or pinfo.st_gid != gid or stat.S_IMODE(pinfo.st_mode) != 0o440:
            die(EXIT_BLOCKED, "active-stage pointer heeft onveilige owner/mode/type")
    for base, dirs, files in os.walk(stage, topdown=True, followlinks=False):
        base_path = Path(base); binfo = base_path.lstat(); relative = base_path.relative_to(stage)
        is_execution_media = bool(relative.parts and relative.parts[0] in ("media", "opatch"))
        expected_owner = execution_owner if is_execution_media else management_owner
        if not stat.S_ISDIR(binfo.st_mode) or binfo.st_uid != expected_owner or binfo.st_gid != gid or stat.S_IMODE(binfo.st_mode) != 0o750:
            die(EXIT_BLOCKED, f"stagedirectory heeft onveilige owner/mode/type: {base}")
        if not is_execution_media:
            validate_stage_acl(base_path, oracle_uid, oracle_groups)
        for name in dirs:
            path = Path(base) / name
            if path.is_symlink(): die(EXIT_BLOCKED, f"symlink in stage: {path}")
        for name in files:
            path = Path(base) / name; info = path.lstat()
            expected_modes = (0o640, 0o750) if is_execution_media else (0o440,)
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != expected_owner or
                    info.st_gid != gid or stat.S_IMODE(info.st_mode) not in expected_modes):
                die(EXIT_BLOCKED, f"stagebestand heeft onveilige owner/mode/type: {path}")


def roots():
    if os.environ.get("OPG_MEDIA_TEST_MODE") == "1":
        base = os.environ.get("OPG_MEDIA_TEST_ROOT", "")
        if not re.fullmatch(r"/tmp/opg-media-stage-tests\.[A-Za-z0-9._-]+", base):
            die(70, "ongeldige testroot")
        p = Path(base)
        return (p / "central", p / "central/oracle-patch-guard",
                p / "u01/stage/oracle-patch-guard", p / "public.pem", os.getgid())
    import grp
    return (Path("/mnt/patch-share/oracle-patches"),
            Path("/mnt/patch-share/oracle-patch-guard"),
            Path("/u01/stage/oracle-patch-guard"),
            Path("/etc/oracle-patch-guard/approval_public.pem"),
            grp.getgrnam("oinstall").gr_gid)


REQUIRED = {"PATCH_CYCLE", "DB_RU_PATCH_ID", "OJVM_PATCH_ID", "OPATCH_VERSION",
            "DB_RU_ZIP", "DB_RU_ZIP_SHA256", "OJVM_ZIP", "OJVM_ZIP_SHA256",
            "OPATCH_ZIP", "OPATCH_ZIP_SHA256", "ARTIFACT_MANIFEST", "ARTIFACT_MANIFEST_SIG"}


def load_inputs():
    central, opg_root, local, public_key, gid = roots()
    cycle = read_single_line(opg_root / "config/active_cycle")
    if not SAFE_CYCLE.fullmatch(cycle):
        die(EXIT_BLOCKED, "ongeldige actieve cycle")
    cycle_dir = central / cycle
    conf = read_kv(cycle_dir / "opg_cycle.conf", REQUIRED, REQUIRED)
    if conf["PATCH_CYCLE"] != cycle:
        die(EXIT_BLOCKED, "active_cycle en cycle-config verschillen")
    for key in ("DB_RU_PATCH_ID", "OJVM_PATCH_ID"):
        if not SAFE_PATCH.fullmatch(conf[key]): die(EXIT_BLOCKED, f"ongeldige {key}")
    for key in ("DB_RU_ZIP_SHA256", "OJVM_ZIP_SHA256", "OPATCH_ZIP_SHA256"):
        if not SAFE_HASH.fullmatch(conf[key]): die(EXIT_BLOCKED, f"ongeldige {key}")
    for key in ("DB_RU_ZIP", "OJVM_ZIP", "OPATCH_ZIP"):
        if not SAFE_ZIP.fullmatch(conf[key]): die(EXIT_BLOCKED, f"ongeldige {key}")
    for key in ("ARTIFACT_MANIFEST", "ARTIFACT_MANIFEST_SIG"):
        if "/" in conf[key] or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}", conf[key]):
            die(EXIT_BLOCKED, f"ongeldige {key}")
    manifest = cycle_dir / conf["ARTIFACT_MANIFEST"]
    signature = cycle_dir / conf["ARTIFACT_MANIFEST_SIG"]
    validate_public_key(public_key)
    manifest_bytes = read_stable_bytes(manifest, 1024 * 1024)
    signature_bytes = read_stable_bytes(signature, 1024 * 1024)
    verify_signature_bytes(public_key, signature_bytes, manifest_bytes)
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    try:
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError(f"duplicate JSON key: {key}")
                result[key] = value
            return result
        data = json.loads(manifest_bytes.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
        die(EXIT_BLOCKED, f"artifact-manifest is geen geldige JSON: {exc}")
    artifacts = validate_manifest(data, cycle, conf)
    return central, local, public_key, gid, cycle, cycle_dir, conf, manifest_bytes, signature_bytes, manifest_hash, artifacts


def verify_identity(cycle, local, identity, gid, pointer=None):
    stage = local / "ready" / cycle / identity
    verify_stage_permissions(stage, pointer, gid)
    fields = read_kv(stage / "stage_manifest.psv",
                     {"schema_version", "cycle", "identity", "tree_hash_format", "artifact_manifest_sha256",
                      "artifact_signing_key_sha256", "db_patch_id", "ojvm_patch_id", "opatch_zip",
                      "db_tree_sha256", "ojvm_tree_sha256", "opatch_zip_sha256", "published_at"},
                     {"schema_version", "cycle", "identity", "tree_hash_format", "artifact_manifest_sha256",
                      "artifact_signing_key_sha256", "db_patch_id", "ojvm_patch_id", "opatch_zip",
                      "db_tree_sha256", "ojvm_tree_sha256", "opatch_zip_sha256"})
    if fields["schema_version"] != "1" or fields["cycle"] != cycle or fields["identity"] != identity or fields["artifact_manifest_sha256"] != identity or fields["tree_hash_format"] != FORMAT:
        die(EXIT_BLOCKED, "stage-manifest identiteit/schema klopt niet")
    if (not SAFE_PATCH.fullmatch(fields["db_patch_id"]) or not SAFE_PATCH.fullmatch(fields["ojvm_patch_id"]) or
            not SAFE_ZIP.fullmatch(fields["opatch_zip"]) or
            any(not SAFE_HASH.fullmatch(fields[key]) for key in ("artifact_signing_key_sha256", "db_tree_sha256", "ojvm_tree_sha256", "opatch_zip_sha256"))):
        die(EXIT_BLOCKED, "stage-manifest bevat onveilige identifiers/hashes")
    public_key = roots()[3]
    validate_public_key(public_key)
    local_manifest = read_stable_bytes(stage / "artifact_manifest.json", 1024 * 1024)
    local_signature = read_stable_bytes(stage / "artifact_manifest.sig", 1024 * 1024)
    if hashlib.sha256(local_manifest).hexdigest() != identity:
        die(EXIT_BLOCKED, "lokale artifact-manifest SHA wijkt af van stage-identiteit")
    verify_signature_bytes(public_key, local_signature, local_manifest)
    current_key_hash, _ = sha256_file(public_key)
    if current_key_hash != fields["artifact_signing_key_sha256"]:
        die(EXIT_BLOCKED, "lokale artifact trust-anchor wijkt af van stagebinding")
    db_root = stage / "media" / cycle / fields["db_patch_id"]
    ojvm_root = stage / "media" / cycle / fields["ojvm_patch_id"]
    opatch = stage / "opatch" / fields["opatch_zip"]
    db_hash = tree_hash_v2(db_root)
    ojvm_hash = tree_hash_v2(ojvm_root)
    zip_hash, _ = sha256_file(opatch)
    if (db_hash != fields["db_tree_sha256"] or ojvm_hash != fields["ojvm_tree_sha256"] or
            zip_hash != fields["opatch_zip_sha256"]):
        die(EXIT_BLOCKED, "gepubliceerde stage-integriteit wijkt af")
    return "|".join(("READY", cycle, identity, str(stage / "media"), str(stage / "opatch"),
                     identity, fields["artifact_signing_key_sha256"], FORMAT, db_hash, ojvm_hash, zip_hash))


def verify_published(cycle, local, expected_identity=None, gid=None):
    validate_local_parents(local)
    pointer = local / "ready" / cycle / "active_stage"
    identity = read_single_line(pointer)
    if not SAFE_HASH.fullmatch(identity) or (expected_identity and identity != expected_identity):
        die(EXIT_BLOCKED, "active-stage identiteit is ongeldig of gewijzigd")
    if gid is None: gid = roots()[4]
    print(verify_identity(cycle, local, identity, gid, pointer))


def stage_active_cycle():
    if os.geteuid() != 0 and os.environ.get("OPG_MEDIA_TEST_MODE") != "1":
        die(EXIT_UNKNOWN, "stage-active-cycle vereist root via sudo")
    central, local, public_key, gid, cycle, cycle_dir, conf, manifest_bytes, signature_bytes, identity, artifacts = load_inputs()
    ready_cycle = local / "ready" / cycle
    final = ready_cycle / identity
    anchor = stage_anchor()
    if anchor.is_symlink() or not anchor.is_dir():
        die(EXIT_BLOCKED, f"trusted stage anchor ontbreekt of is een symlink: {anchor}")
    local.mkdir(exist_ok=True, mode=0o750)
    validate_local_parents(local)
    (local / "incoming").mkdir(mode=0o750, exist_ok=True)
    ready_cycle.mkdir(parents=True, exist_ok=True, mode=0o750)
    for controlled in (local, local / "incoming", local / "ready", ready_cycle): secure_directory(controlled, gid)
    if final.exists():
        verify_identity(cycle, local, identity, gid)
        pointer_tmp = ready_cycle / f".active_stage.{os.getpid()}"
        pointer_tmp.write_text(identity + "\n", encoding="ascii")
        os.chown(pointer_tmp, 0 if os.geteuid() == 0 else os.getuid(), gid); os.chmod(pointer_tmp, 0o440)
        os.replace(pointer_tmp, ready_cycle / "active_stage")
        verify_published(cycle, local, identity, gid)
        return
    required_bytes = sum(item["size"] for item in artifacts.values())
    required_inodes = 1024
    for name in ("db_ru", "ojvm", "opatch"):
        source = (cycle_dir if name != "opatch" else central / "opatch") / artifacts[name]["filename"]
        try:
            count, unpacked = inspect_zip(
                source,
                conf["DB_RU_PATCH_ID"] if name == "db_ru" else conf["OJVM_PATCH_ID"] if name == "ojvm" else "OPatch",
                name in ("db_ru", "ojvm"))
            required_inodes += count
            if name != "opatch": required_bytes += unpacked
        except (OSError, zipfile.BadZipFile):
            die(EXIT_BLOCKED, f"corrupte/onleesbare transport-ZIP voor {name}")
    required_bytes = required_bytes + required_bytes // 10 + 64 * 1024 * 1024
    available_bytes = shutil.disk_usage(local).free
    available_inodes = os.statvfs(local).f_favail
    if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" and "OPG_MEDIA_TEST_FREE_BYTES" in os.environ:
        available_bytes = int(os.environ["OPG_MEDIA_TEST_FREE_BYTES"])
    if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" and "OPG_MEDIA_TEST_FREE_INODES" in os.environ:
        available_inodes = int(os.environ["OPG_MEDIA_TEST_FREE_INODES"])
    if available_bytes < required_bytes:
        die(EXIT_BLOCKED, "onvoldoende lokale vrije ruimte voor copy en extractie")
    if available_inodes < required_inodes:
        die(EXIT_BLOCKED, "onvoldoende lokale vrije inodes voor extractie")
    incoming = Path(tempfile.mkdtemp(prefix=f"{cycle}.{identity}.", dir=local / "incoming"))
    started = time.monotonic()
    try:
        (incoming / "media" / cycle).mkdir(parents=True)
        (incoming / "opatch").mkdir()
        (incoming / "artifact_manifest.json").write_bytes(manifest_bytes)
        (incoming / "artifact_manifest.sig").write_bytes(signature_bytes)
        sources = {
            "db_ru": cycle_dir / artifacts["db_ru"]["filename"],
            "ojvm": cycle_dir / artifacts["ojvm"]["filename"],
            "opatch": central / "opatch" / artifacts["opatch"]["filename"],
        }
        copies = {}
        copy_start = time.monotonic()
        for name, source in sources.items():
            expected = artifacts[name]
            target = incoming / ("opatch" if name == "opatch" else "") / source.name
            if name != "opatch": target = incoming / source.name
            digest, size = copy_once_and_hash(source, target)
            if digest != expected["sha256"] or size != expected["size"]:
                die(EXIT_BLOCKED, f"bron-ZIP wijkt af voor {name}")
            digest, size = sha256_file(target)
            if digest != expected["sha256"] or size != expected["size"]:
                die(EXIT_BLOCKED, f"lokale ZIP-copy wijkt af voor {name}")
            copies[name] = target
        copy_seconds = int(time.monotonic() - copy_start)
        extract_start = time.monotonic()
        validate_opatch_zip(copies["opatch"], conf["OPATCH_VERSION"])
        db_extracted = safe_extract(copies["db_ru"], incoming / ".db_extract", conf["DB_RU_PATCH_ID"], True)
        ojvm_extracted = safe_extract(copies["ojvm"], incoming / ".ojvm_extract", conf["OJVM_PATCH_ID"], True)
        os.rename(db_extracted, incoming / "media" / cycle / conf["DB_RU_PATCH_ID"])
        os.rename(ojvm_extracted, incoming / "media" / cycle / conf["OJVM_PATCH_ID"])
        os.rmdir(incoming / ".db_extract"); os.rmdir(incoming / ".ojvm_extract")
        copies["db_ru"].unlink(); copies["ojvm"].unlink()
        extract_seconds = int(time.monotonic() - extract_start)
        hash_start = time.monotonic()
        db_hash = tree_hash_v2(incoming / "media" / cycle / conf["DB_RU_PATCH_ID"])
        ojvm_hash = tree_hash_v2(incoming / "media" / cycle / conf["OJVM_PATCH_ID"])
        opatch_hash, _ = sha256_file(copies["opatch"])
        key_hash, _ = sha256_file(public_key)
        hash_seconds = int(time.monotonic() - hash_start)
        stage_manifest = incoming / "stage_manifest.psv"
        stage_manifest.write_text(
            f"schema_version=1\ncycle={cycle}\nidentity={identity}\ntree_hash_format={FORMAT}\n"
            f"artifact_manifest_sha256={identity}\nartifact_signing_key_sha256={key_hash}\n"
            f"db_patch_id={conf['DB_RU_PATCH_ID']}\nojvm_patch_id={conf['OJVM_PATCH_ID']}\n"
            f"opatch_zip={conf['OPATCH_ZIP']}\ndb_tree_sha256={db_hash}\nojvm_tree_sha256={ojvm_hash}\n"
            f"opatch_zip_sha256={opatch_hash}\npublished_at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n",
            encoding="ascii")
        evidence = incoming / "evidence"; evidence.mkdir()
        (evidence / "timings.psv").write_text(
            f"copy_seconds={copy_seconds}\nextract_seconds={extract_seconds}\nhash_seconds={hash_seconds}\n"
            f"total_seconds={int(time.monotonic()-started)}\n", encoding="ascii")
        _, oracle_uid, _ = stage_security_ids(gid)
        execution_owner = os.getuid() if os.environ.get("OPG_MEDIA_TEST_MODE") == "1" else oracle_uid
        secure_tree(incoming, gid, execution_owner)
        try:
            os.rename(incoming, final)
        except OSError as exc:
            if exc.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                raise
            # Een gelijktijdige identieke publisher won de race. Accepteer die
            # uitsluitend na volledige inhouds- en permissionverificatie.
            verify_identity(cycle, local, identity, gid)
        pointer_tmp = ready_cycle / f".active_stage.{os.getpid()}"
        pointer_tmp.write_text(identity + "\n", encoding="ascii")
        os.chown(pointer_tmp, 0 if os.geteuid() == 0 else os.getuid(), gid); os.chmod(pointer_tmp, 0o440)
        os.replace(pointer_tmp, ready_cycle / "active_stage")
        verify_published(cycle, local, identity, gid)
    except BaseException:
        # Bewust geen destructieve automatische cleanup; incoming is recovery-evidence.
        raise


def main():
    if len(sys.argv) not in (2, 3):
        die(70, "gebruik: opg_media_stage_root.sh {stage-active-cycle|verify-active-stage CYCLE}")
    action = sys.argv[1]
    if action == "stage-active-cycle" and len(sys.argv) == 2:
        stage_active_cycle()
    elif action == "verify-active-stage" and len(sys.argv) == 3 and SAFE_CYCLE.fullmatch(sys.argv[2]):
        _, _, local, _, _ = roots()
        verify_published(sys.argv[2], local)
    else:
        die(70, "onbekende of onveilige actie/argumenten")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except (ValueError, zipfile.BadZipFile) as exc:
        die(EXIT_BLOCKED, f"ongeldige media-inhoud: {exc}")
    except OSError as exc:
        die(EXIT_UNKNOWN, f"onbetrouwbare filesystem/I/O-fout: {exc}")
