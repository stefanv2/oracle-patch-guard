# Pilot07 change report

> **HISTORICAL — Pilot07 wijzigingsevidence.** Dit report beschrijft de
> oorspronkelijke Pilot07-wijzigingen en is geen volledig current runbook. Zie
> [README.md](README.md) en
> [RELEASE_NOTES_20260831.md](RELEASE_NOTES_20260831.md) voor stable-20260831.

## Functionele wijziging

- Nieuwe expliciete OEM-fase `stage-media` vóór maintenance-window/assess.
- Nieuwe lokaal geïnstalleerde, root-begrensde helper voor signed ZIP-validatie,
  single-pass transportcopy, veilige extractie, V2 hashing en atomic publish.
- Core bindt PLAN aan lokale stage-identiteit, artifact-manifest/key-SHA256 en
  V2 tree hashes; APPLY en resume herverifiëren uitsluitend lokaal.
- De media-parentboundary begint bij de vaste trusted anchor `/u01/stage`.
  `/u01` en hogere directories vallen buiten de OPG stage trust policy en
  krijgen geen aanvullende owner-, mode-, write-bit- of symlinkvoorwaarde.
  Anchor en stage-root blijven strikt root-owned en veilig.
- De RU/OJVM ZIP-validator accepteert naast de patch-ID-directory uitsluitend
  optioneel exact één regulier rootbestand `PatchSearch.xml`. OPatch blijft
  beperkt tot `OPatch/`; alle andere rootentries blijven fail-closed.
- Op basis van de live OPatch-test zijn uitsluitend de execution trees
  `media/` en `opatch/` gewijzigd naar `oracle:oinstall`. Directories zijn 0750,
  gewone bestanden 0640 en ZIP-entries met execute-semantiek 0750. Metadata,
  pointers, helper/sudo-boundary en beheerstructuur blijven root-controlled.
- Geen fallback naar de uitgepakte centrale tree in `LOCAL_MEDIA_MODE=required`.
- V1 blijft uitsluitend beschikbaar achter `LOCAL_MEDIA_MODE=disabled` voor
  regressie/backward-compatibility; de Pilot07-productieconfig staat op required.

## Ongewijzigd

Pilot06c approval/signing, locking, state-machine, preapply-hercontrole,
OPatch-self-upgrade, RU/OJVM, listener, datapatch, utlrp, recoverychecks en
fail-closed exitcodes zijn niet herontworpen.

Artifact-manifestvalidatie, ZIP-SHA256, V2 tree hashing, PLAN-binding, approval-
signing en verse APPLY/resume-herverificatie zijn functioneel ongewijzigd.

## Belangrijkste bestanden

- `oem-tasks/opg_media_stage_root.sh`
- `oem-tasks/opg_media_stage_root.py`
- `oem-tasks/opg_build_artifact_manifest.py`
- `oem-tasks/opg_oem.sh`
- `project/patchGD_guard.sh`
- `artifact_manifest.schema.json`
- `TREE_HASH_V2_SPEC.md`
- `project/tests/run_pilot07_tests.sh`

## Bekende beperkingen

- De echte JUL2026 artifact-SHA256/size/signature moeten op de gecontroleerde
  omgeving uit de originele ZIPs worden gegenereerd; de RC bevat geen verzonnen
  productiehandtekening.
- Staging vereist tijdelijk ruimte voor ZIP-copy plus extractie. Automatische
  cleanup is bewust afwezig.
- Wave-orkestratie moet gelijktijdige eerste copies over verschillende targets
  begrenzen; Pilot07 orkestreert geen hosts.
- Een host-root- of offline-signing-keycompromise valt buiten dit model.
- Een kwaadwillende target-oracle user bij een oracle-owned `/u01` valt buiten
  lokale pathname-integriteit; inhoudsafwijkingen blijven door verse signed
  V2/SHA256-herverificatie vóór PLAN/APPLY/resume fail-closed gedetecteerd.
