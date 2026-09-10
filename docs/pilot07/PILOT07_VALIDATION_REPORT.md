# Pilot07 validation report

Datum: 2026-08-27

## Syntax en compile

Uitgevoerd vanuit de candidate-root:

```bash
while IFS= read -r -d '' file; do bash -n "$file"; done \
  < <(find . -type f -name '*.sh' -print0)
python3 -B -c 'compile(...opg_media_stage_root.py...); compile(...opg_build_artifact_manifest.py...)'
```

Resultaat: alle Bashbestanden syntactisch geldig; beide Pythonbestanden
compileren.

## ShellCheck

Exact uitgevoerde selectie/command (ShellCheck 0.8.0):

```bash
grep -IlZ "^#!/.*bash" project/*.sh project/lib/*.sh project/checks/* \
  project/tests/*.sh oem-tasks/*.sh tools/*.sh signer/*.sh | \
  xargs -0 shellcheck -x
```

Geen nieuwe Pilot07-finding. De output bevat exact dezelfde bestaande meldingen
als dezelfde command tegen de immutable Pilot06c-baseline:

- SC1091 op de dynamische `SCRIPT_DIR`-include van `lib/opg_core.sh`;
- SC2034 voor `LOCK_ROOT`, `COMMAND_TIMEOUT_SECONDS` en `ALLOW_TEST_MODE`, die
  indirect door de ingeladen core/testinterface worden gebruikt.

Er zijn geen nieuwe suppressions toegevoegd.

## Volledige regressie

```bash
bash tests/run_tests.sh
bash tests/run_open_checks_tests.sh
bash tests/run_pilot05b_tests.sh
bash tests/run_oem14_approval_tests.sh
bash tests/run_oem_wrapper_tests.sh
bash tests/run_pilot07_tests.sh
bash tests/run_signer_pending_tests.sh
bash tests/run_signer_batch_tests.sh
```

| Suite | Resultaat |
|---|---:|
| Core/original + Pilot07 corebinding | 74/74 |
| Open checks | 27/27 |
| Pilot05b-Pilot05e | 39/39 |
| OEM14 approval/staging | 13/13 |
| OEM wrapper/security | 36/36 |
| Pilot07 media/V2/security | 48/48 |
| Signer pending/approvalstatus + awk-warning | 14/14 |
| Signer multi-target batch | 14/14 |
| **Totaal** | **265/265** |

Pilot07-dekking omvat onder meer signed-manifestvalidatie, ZIP-checksums en
interne OPatch-versie, traversal/symlink/hardlink/special-file rejection,
golden vectors, root-onafhankelijke V2-hash, lokale mutatie, identity/key drift,
permissions, ruimte/inodes, interruption, concurrent staging, offline share bij
APPLY en offline share bij resume. De aanvullende threat-boundarytests dekken
een oracle-owned `/u01` boven de root-owned anchor, verkeerde anchor-owner/mode,
anchor/stage-root-symlinks, write-ACL's, de volledig root-controlled layout en
een inhoudelijk vervangen stagepad dat vóór APPLY/downtime wordt geblokkeerd.
De Oracle ZIP-layouttests bewijzen daarnaast RU/OJVM met en zonder exact
`PatchSearch.xml`, uitsluiting van dit rootbestand uit V2, afwijzing van
symlink/special/alternate spelling/extra roots/traversal/absolute paden en de
ongewijzigd strikte `OPatch/`-root.
De stagingownershiptest bewijst daarnaast root-owned metadata tegenover
oracle-owned `media/` en `opatch/`, met 0640 voor gewone files en behoud van
execute-semantiek als 0750. De bestaande coretest blijft bewijzen dat een
inhoudelijke mutatie na PLAN vóór APPLY/downtime wordt geblokkeerd.

De signer-suite bewijst daarnaast dat default en `--pending` uitsluitend
PENDING tonen, `--list` alle vier statussen bevat, APPROVED uitsluitend na
echte RSA/SHA256-verificatie wordt toegekend, corrupte en onveilig getypeerde
runs UNKNOWN worden, multi-targetmetadata geïsoleerd blijft en de bewust
uitgestelde `--cleanup` geen enkel run- of symlinktarget wijzigt. De actieve
awk-regexen produceren geen GNU awk `\"`-waarschuwing meer.

De multi-target signer-suite bewijst exclusieve PENDING/readinessselectie,
BLOCKED/UNKNOWN/APPROVED/COMPLETE-skips, bestaande CONDITIONAL-regels, verse
hercontrole na selectie, byte-identieke dry-run, exact `yes`, afzonderlijke
tokens/signatures per target, doorgaan na één geïsoleerde signerfailure en een
fail-closed symlink/pathgrens. Default en help blijven read-only. De batchhelper
bevat geen signing- of private-keylogica en verifieert na iedere single-run
aanroep opnieuw de cryptografische APPROVED-status.

## Nog uit te voeren op de non-productietarget

- Genereren/ondertekenen van het echte JUL2026 artifact-manifest met de echte
  ZIP-groottes en SHA256-waarden.
- Installatiecontrole van beide lokale root-owned helperbestanden en sudoers.
- Eén echte `stage-media` benchmark op share en lokale XFS.
- Nieuwe RUN_ID/markers/approval voor de Pilot07 live-run.
