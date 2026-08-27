#!/usr/bin/python3 -I
"""Offline DBA tool: build and sign a Pilot07 cycle artifact manifest."""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def regular_zip(value):
    raw = Path(value)
    if raw.is_symlink():
        raise argparse.ArgumentTypeError("artifact-symlinks zijn niet toegestaan")
    path = raw.resolve(strict=True)
    if not path.is_file() or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}\.zip", path.name):
        raise argparse.ArgumentTypeError("artifact moet een reguliere ZIP met veilige bestandsnaam zijn")
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return {"filename": path.name, "size": path.stat().st_size, "sha256": h.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cycle", required=True)
    parser.add_argument("--db-patch-id", required=True)
    parser.add_argument("--db-zip", required=True, type=regular_zip)
    parser.add_argument("--ojvm-patch-id", required=True)
    parser.add_argument("--ojvm-zip", required=True, type=regular_zip)
    parser.add_argument("--opatch-version", required=True)
    parser.add_argument("--opatch-zip", required=True, type=regular_zip)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9][A-Z0-9_-]{0,63}", args.cycle): raise SystemExit("ongeldige cycle")
    if not re.fullmatch(r"[0-9]{6,12}", args.db_patch_id) or not re.fullmatch(r"[0-9]{6,12}", args.ojvm_patch_id): raise SystemExit("ongeldig patch-ID")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3,5}", args.opatch_version): raise SystemExit("ongeldige OPatch-versie")
    if args.private_key.is_symlink(): raise SystemExit("private-key-symlink is geweigerd")
    key = args.private_key.resolve(strict=True)
    if not key.is_file(): raise SystemExit("private key ontbreekt of is onveilig")
    output = args.output_dir.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.is_symlink(): raise SystemExit("outputdirectory is een symlink")
    db = digest(args.db_zip); db["patch_id"] = args.db_patch_id
    ojvm = digest(args.ojvm_zip); ojvm["patch_id"] = args.ojvm_patch_id
    opatch = digest(args.opatch_zip); opatch["version"] = args.opatch_version
    data = {
        "schema_version": 1,
        "patch_cycle": args.cycle,
        "created_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "tree_hash_format": "OPG_TREE_HASH_V2",
        "artifacts": {"db_ru": db, "ojvm": ojvm, "opatch": opatch},
    }
    manifest = output / "artifact_manifest.json"
    signature = output / "artifact_manifest.sig"
    if manifest.exists() or signature.exists(): raise SystemExit("output bestaat al; overschrijven is geweigerd")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(manifest, flags, 0o440)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        handle.write("\n")
    result = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(key),
                             "-out", str(signature), str(manifest)], check=False)
    if result.returncode != 0:
        manifest.unlink()
        raise SystemExit("ondertekening is mislukt")
    os.chmod(signature, 0o440)
    print(f"ARTIFACT_MANIFEST|path={manifest}|sha256={digest(manifest)['sha256']}|signature={signature}")


if __name__ == "__main__":
    main()
