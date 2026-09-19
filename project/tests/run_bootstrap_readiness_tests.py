#!/usr/bin/env python3
"""Use bootstrap-installed artifacts for real staging and Oracle-mocked PRECHECK.

Only filesystem roots/user identity are adapted for isolation. Media hashes,
signatures, stage permissions and the PRECHECK lifecycle boundary remain real.
Called by run_bootstrap_tests.sh after fresh bootstrap, before PREPARE.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import zipfile

base, repository = map(Path, sys.argv[1:])
config = base / "etc/oracle-patch-guard/patchGD_guard.conf"
values = dict(line.split("=", 1) for line in config.read_text().splitlines()
              if line and not line.startswith("#"))
central = Path(values["PATCH_ROOT"])
cycle = central / "JUL2026"
cycle.mkdir(parents=True)
opatch = Path(values["OPATCH_ROOT"])
opatch.mkdir(parents=True)
db_zip = cycle / "p39472050_190000_Linux-x86-64.zip"
ojvm_zip = cycle / "p39222882_190000_Linux-x86-64.zip"
opatch_zip = opatch / "p6880880_190000_Linux-x86-64.zip"
for path, top in ((db_zip, "39472050"), (ojvm_zip, "39222882"), (opatch_zip, "OPatch")):
    with zipfile.ZipFile(str(path), "w") as archive:
        if top == "OPatch":
            archive.writestr(top + "/version.txt", "OPATCH_VERSION: 12.2.0.1.52\n")
            archive.writestr(top + "/opatch", "#!/bin/sh\nexit 0\n")
        else:
            archive.writestr(top + "/README.txt", "Fixture patch\n")
            archive.writestr(top + "/files/payload", "Fixture payload\n")

subprocess.run([sys.executable, str(repository / "oem-tasks/opg_build_artifact_manifest.py"),
                "--cycle", "JUL2026", "--db-patch-id", "39472050", "--ojvm-patch-id", "39222882",
                "--db-zip", str(db_zip), "--ojvm-zip", str(ojvm_zip),
                "--opatch-version", "12.2.0.1.52", "--opatch-zip", str(opatch_zip),
                "--private-key", str(base / "private.pem"), "--output-dir", str(cycle)], check=True)
fields = {"PATCH_CYCLE": "JUL2026", "DB_RU_PATCH_ID": "39472050", "OJVM_PATCH_ID": "39222882",
          "OPATCH_VERSION": "12.2.0.1.52", "ARTIFACT_MANIFEST": "artifact_manifest.json",
          "ARTIFACT_MANIFEST_SIG": "artifact_manifest.sig"}
for name, path in (("DB_RU_ZIP", db_zip), ("OJVM_ZIP", ojvm_zip), ("OPATCH_ZIP", opatch_zip)):
    fields[name] = path.name
    fields[name + "_SHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
(cycle / "opg_cycle.conf").write_text("".join(k + "=" + v + "\n" for k, v in fields.items()))
(base / "base/config/active_cycle").write_text("JUL2026\n")

# Adapter loads the installed engine; it does not fabricate READY output.
adapter = base / "media-test-adapter"
adapter.write_text("""#!/usr/bin/python3
import importlib.util, os, pathlib, sys
os.environ['OPG_MEDIA_TEST_MODE'] = '1'
os.environ['OPG_MEDIA_TEST_ROOT'] = {base!r}
spec = importlib.util.spec_from_file_location('engine', {engine!r})
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
engine.roots = lambda: (pathlib.Path({central!r}), pathlib.Path({opg!r}),
    pathlib.Path({stage!r}), pathlib.Path({key!r}), os.getgid())
engine.main()
""".format(base=str(base), engine=str(base / "usr/local/libexec/opg_media_stage_root.py"),
           central=str(central), opg=values["OPG_ROOT"], stage=values["LOCAL_STAGE_ROOT"],
           key=values["APPROVAL_PUBLIC_KEY"]))
adapter.chmod(0o755)
subprocess.run([str(adapter), "stage-active-cycle"], check=True)
subprocess.run([str(adapter), "verify-active-stage", "JUL2026"], check=True)

home = base / "oracle-home"
for name in ("bin/sqlplus", "OPatch/opatch"):
    path = home / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 99\n")
    path.chmod(0o755)
inventory = base / "inventory"
for path in (home / "inventory/ContentsXML/oraclehomeproperties.xml", inventory / "ContentsXML/inventory.xml"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("<INVENTORY/>\n")
oratab = base / "oratab"
oratab.write_text("DB1:" + str(home) + ":Y\n")
fixture = base / "oracle-fixture"
fixture.mkdir()
(fixture / "database_inventory.csv").write_text(
    (repository / "project/fixtures/healthy_single/database_inventory.csv").read_text().replace("__TARGET_HOME__", str(home)))
fixture_env = base / "oracle-fixture.env"
fixture_env.write_text("""MOCK_OPATCH_VERSION=12.2.0.1.52
MOCK_CHECK_BACKUP=VERIFIED
MOCK_CHECK_ORACLE_HOME_RECOVERY=VERIFIED
MOCK_CHECK_DATAGUARD=HEALTHY
MOCK_CHECK_MAINTENANCE_WINDOW=OK
""")
# Production config remains byte-identical; test mode is enabled only in a copy.
before = config.read_bytes()
test_config = base / "precheck-test.conf"
test_config.write_bytes(before + ("\nALLOW_TEST_MODE=true\nORATAB_FILE=" + str(oratab) +
    "\nMOCK_CENTRAL_INVENTORY=" + str(inventory) +
    "\nMIN_HOME_FREE_MB=0\nMIN_INVENTORY_FREE_MB=0\nMIN_STAGE_FREE_MB=0\nMIN_TMP_FREE_MB=0\n").encode())
environment = dict(os.environ, OPG_TEST_MODE="1", OPG_FIXTURE_FILE=str(fixture_env),
                   OPG_FIXTURE_DIR=str(fixture), OPG_TEST_MEDIA_STAGE_HELPER=str(adapter),
                   OPG_TEST_LOCAL_STAGE_ROOT=values["LOCAL_STAGE_ROOT"])
context = base / "var/lib/oracle-patch-guard/current_run.json"
assert not context.exists()
result = subprocess.run(["bash", str(repository / "project/patchGD_guard.sh"), "precheck",
                         "--config", str(test_config), "--target-oracle-home", str(home),
                         "--run-id", "PRECHECK-FRESH", "39472050", "39222882", "JUL2026",
                         "12.2.0.1.52", opatch_zip.name], env=environment,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
assert result.returncode in (0, 10), result.stdout
run = Path(values["RUN_ROOT"]) / "PRECHECK-FRESH"
assert "OPG_PRECHECK_RESULT|" in result.stdout
assert not context.exists()
assert not (run / "execution_state.json").exists()
assert not (run / "patch_manifest.json").exists()
assert config.read_bytes() == before
print("Fresh bootstrap -> signed STAGE_MEDIA -> lifecycle-neutral PRECHECK passed")
