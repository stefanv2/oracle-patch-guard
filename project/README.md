# Oracle Patch Guard core runtime

Oracle Patch Guard automatiseert de herkenbare `patchGD.sh`-werkwijze als een lokale, stateful patch-eenheid per canonieke Oracle Home. OEM 24ai verzorgt staging, targetselectie, waves en paralleliteit tussen hosts; de lokale guard blijft altijd beslissen of één home veilig verwerkt mag worden.

> Status: pilotsoftware. Gebruik vereist een lokaal beoordeelde configuratie,
> herstelprocedure, approval-inrichting en representatieve non-productietest.

## Ondersteunde scope

- Oracle Database 19c op Oracle Linux 8/9;
- Bash, single-instance;
- één of meerdere databases in exact één gedeelde Oracle Home;
- in-place DB-RU gevolgd door OJVM;
- expliciete uitvoering per SID van `datapatch -verbose`, `utlrp.sql` en eindvalidatie;
- lokale uitvoering of OEM-agentaccount met vooraf ingerichte `sudo -n`.

RAC, SEHA, Data Guard, Grid Infrastructure en ASM worden gedetecteerd en in deze MVP geblokkeerd. OS-update en reboot zijn bewust geen onderdeel van `apply`.

## Bestanden

- `patchGD_guard.sh`: interface, assessment, plan, apply, resume, status en cleanup;
- `lib/opg_core.sh`: logging, atomische state, hashing, commando- en lockwrappers;
- `patchGD_guard.conf.example`: alle lokale paden, drempels en integratiehooks;
- `oem_assess.sh`, `oem_apply.sh`, `oem_status.sh`, `oem_collect_results.sh`: OEM-laag;
- `OEM_DEPLOYMENT_PROCEDURE.md`: praktische OEM-inrichting;
- `SECURITY_AND_SAFETY.md`: trust boundaries, approvals en herstelgedrag;
- `checks/check_oracle_home_recovery`: read-only verificatie van hersteloptie 2 (rebuild);
- `checks/check_maintenance_window`: validatie van het root-beheerde onderhoudsvenster;
- `tests/run_tests.sh`, `tests/run_open_checks_tests.sh` en `fixtures/`: gesimuleerde regressie- en concrete policytests.

## Interface

```bash
./patchGD_guard.sh assess --target-oracle-home /u01/app/oracle/product/19c/dbhome_1 --run-id DEMO123-assess \
  39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip

./patchGD_guard.sh plan --run-id DEMO123-assess

./patchGD_guard.sh apply --non-interactive --run-id DEMO123-assess \
  --approved-manifest /secure/approval/patch_manifest.json \
  --approval-token /secure/approval/approval.json

./patchGD_guard.sh status --run-id DEMO123-assess
./patchGD_guard.sh resume --run-id DEMO123-assess
./patchGD_guard.sh cleanup --run-id DEMO123-assess --approval-token /secure/approval/cleanup-approval.json
```

Zonder vijf geldige patchparameters wordt usage getoond. De historische defaults werken alleen met `--use-defaults`. `--dry-run` voert assessment en de volledige read-only pre-applyhercontrole werkelijk uit, maar onderdrukt muterende stop/apply/startopdrachten. Een dry-run-apply bewijst dus geen geslaagde patch of eindvalidatie.

## Beslismodel en exitcodes

| Exit | Betekenis |
|---:|---|
| 0 | `READY` of `COMPLETE` |
| 10 | `CONDITIONAL` |
| 20 | `BLOCKED` |
| 30 | `UNKNOWN` |
| 40 | `PARTIAL` |
| 50 | `MANUAL_INTERVENTION_REQUIRED` |
| 60 | `BLOCKED_ALREADY_RUNNING` |
| 70 | Ongeldige OEM/CLI-parameters |

Iedere uitvoering eindigt waar mogelijk met:

```text
OPG_RESULT|host=server01|home=/u01/app/oracle/product/19c/dbhome_1|run_id=12345|status=COMPLETE|phase=VALIDATION|exit_code=0
```

`CONDITIONAL` is niet hetzelfde als `READY`: ieder finding-ID moet afzonderlijk in het approval-token worden geaccepteerd. Een volledig geverifieerde rebuild-route levert bewust `HOME_RECOVERY_REBUILD_VERIFIED` als conditional op. `UNKNOWN` mag niet door AI, OEM of `--non-interactive` worden omgezet in succes.

Een oudere actieve OPatch-versie is alleen `CONDITIONAL` wanneer checksum, volledige ZIP-integriteit, veilige entries en de interne versie exact zijn gevalideerd. Na approval, home-lock en preapply wordt OPatch vóór database/listener-downtime via een rungebonden stage en `OPatch.before-<RUN_ID>` bijgewerkt. De backup wordt nooit automatisch verwijderd of teruggezet. Een exacte actieve versie slaat deze mutatie idempotent over.

## Lock-root bootstrap

`LOCK_ROOT` moet vóór uitvoering door beheer/root als echte directory zijn ingericht en voor de Oracle Home-owner toegankelijk en schrijfbaar zijn, bijvoorbeeld `install -d -o root -g oinstall -m 2770 /var/lock/oracle-patch-guard` met de lokaal geldende Oracle-groep. De directory moet root-owned en niet world-writable zijn. Patch Guard maakt deze directory bewust niet zelf onder `/var/lock` aan. Ontbrekende of onbruikbare lockinfrastructuur levert `BLOCKED|LOCK_SETUP`; alleen een aantoonbaar bezette, geldige home-lock levert `BLOCKED_ALREADY_RUNNING`.

## Twee controlemomenten

`assess` is de ruime, read-only controle vóór het onderhoudsvenster. Een toekomstig geldig venster mag dan al worden beoordeeld. `apply` verkrijgt eerst de exclusieve home-lock en voert daarna, vóór state `04_APPROVED` en vóór iedere shutdown/listenerstop, `perform_preapply_recheck` uit. Dan moet het actuele tijdstip binnen het venster liggen en moet minimaal de opgegeven resterende tijd beschikbaar zijn. De hercontrole vergelijkt tevens home/host/owner, platform en Oracle-versie, manifest/oratab/mediachecksums, PMON/database/PDB/service-state, SQL-patchfouten, Data Pump, ASM/Data Guard, OPatch-versie, inventories, beide conflictchecks, vrije ruimte, back-up en de volledige rebuild-route. Het resultaat staat in `preapply_assessment.json`. `BLOCKED` of `UNKNOWN` maakt geen shutdown- of listenerstoplog aan.

Data Pump heeft één bron van waarheid: `inventory.sql`. Conform de bestaande database/CDB-policy gebruikt die de door Oracle 19c gedocumenteerde `DBA_DATAPUMP_JOBS`-view; per actieve job worden `SID`, owner, jobnaam, operation, job mode en state vastgelegd. Een actieve job is `BLOCKED`; ontbrekende of intern inconsistente queryoutput is `UNKNOWN`.

## Herstel- en venstermanifesten

`check_oracle_home_recovery` verifieert een goedgekeurde base image met checksum, de staged OPatch-zip met checksum en versie, DB-RU/OJVM-media, Oracle Base/Home en inventories, geselecteerde oratab-regels, netwerkconfiguratie, SPFILE/password file/database-eigenschappen/services per draaiende SID, de bestaande RMAN-policycheck, een root-owned herstelprocedure en vrije rebuildruimte. Het deterministische `recovery_manifest.json` bindt de vaste identiteit en READY-status van deze onderdelen aan `patch_manifest.json` en wordt direct vóór apply opnieuw opgebouwd en vergeleken. Vluchtige RMAN-leeftijden en het actuele aantal vrije MiB blijven in evidencebestanden; zij worden opnieuw getoetst maar zijn geen identiteitsveld.

Het root-owned, niet-symlink en niet group/world-writable `MAINTENANCE_WINDOW_MANIFEST` gebruikt één `key=value` per regel:

```text
hostname=dbhost01.example.com
change_id=DEMO-2026-001
start=2026-08-15T20:00:00+02:00
end=2026-08-16T00:00:00+02:00
allowed_oracle_home=/u01/app/oracle/product/19.0.0/dbhome_1
run_id=DEMO-2026-001-server01
min_remaining_minutes=120
```

`run_id` mag leeg zijn; alle andere velden zijn verplicht. De checksum van dit bestand hoort bij het goedgekeurde patchmanifest, zodat een wijziging na assessment apply blokkeert.

## Goedkeuringscontract

`approval.json` verwijst naar het exacte SHA-256 van het immutable manifest, dezelfde host en home, een vervaltijd en iedere geaccepteerde conditional:

```json
{
  "approved": true,
  "manifest_sha256": "<sha256>",
  "hostname": "dbhost01.example.com",
  "target_oracle_home": "/u01/app/oracle/product/19c/dbhome_1",
  "expires_epoch": 1785776400,
  "accept_SHARED_HOME": "SHARED_HOME",
  "accept_HOME_RECOVERY_REBUILD_VERIFIED": "HOME_RECOVERY_REBUILD_VERIFIED",
  "manifest_signature_file": "/secure/approval/patch_manifest.sig",
  "approval_signature_file": "/secure/approval/approval.sig"
}
```

Buiten de expliciete testmodus controleert de guard met `APPROVAL_PUBLIC_KEY` afzonderlijke OpenSSL-handtekeningen over het exacte manifest én het volledige approval-token. De private sleutel blijft centraal; de token- en signaturelocaties moeten tegen wijziging worden beschermd.

## Run-artifacts

Per run ontstaan onder `RUN_ROOT/RUN_ID` onder meer `summary.txt`, `assessment.json`, `patch_manifest.json`, `execution_state.json`, `commands.log`, inventories, database/SQL-patch/invalid-object CSV’s, beide conflictrapporten, logbestanden per SID, `proposed_runbook.sh`, `rollback_plan.txt` en `change_report.md`. State-overgangen worden atomair geschreven en tevens append-only in `state_history.log` vastgelegd.

`proposed_runbook.sh` is informatief en voert geen patch uit. Cleanup verwijdert in deze MVP bewust niets; het maakt alleen een reviewrapport na afzonderlijke functionele acceptatie.

Productieconfiguratie wordt met Bash `source` geladen en is dus vertrouwde code. De guard accepteert buiten testmodus uitsluitend een regulier, niet-symlink, root-owned bestand zonder group/world-write. De OEM-wrappers accepteren alleen configuratiepaden onder `/etc/oracle-patch-guard/`.

## Testen

Op Linux met Bash:

```bash
for script in patchGD_guard.sh lib/opg_core.sh oem_*.sh checks/* tests/*.sh; do bash -n "$script"; done
bash tests/run_tests.sh
bash tests/run_open_checks_tests.sh
```

De harness zet `OPG_TEST_MODE=1`, bouwt tijdelijke fake homes en voert geen Oracle-, OS-update- of rebootopdracht uit. Productieconfiguratie moet `ALLOW_TEST_MODE=false` houden.

## Veilige praktijktestvolgorde

1. Lokale `assess` op een testserver.
2. Lokale `plan` en handmatige beoordeling van `proposed_runbook.sh` plus recovery- en vensterbewijs.
3. OEM-assess op één testtarget.
4. Echte patch op één niet-productietarget.
5. Gecontroleerde mislukking en resume-test.
6. Herstel- of rollbacktest van database én bestaande Oracle Home.
7. OEM-pilotwave met maximaal twee targets.
8. Pas daarna productie in kleine waves.
