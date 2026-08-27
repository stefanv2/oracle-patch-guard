# Oracle Patch Guard signer-statusoverzicht

Installeer `signer/opg_list_pending.sh` op de signinghost als:

```text
/secure/oracle-patch-guard/bin/opg_list_pending.sh
```

Installeer voor gecontroleerde multi-targetorchestratie daarnaast:

```text
/secure/oracle-patch-guard/bin/opg_approve_pending.sh
```

De bestaande `/secure/oracle-patch-guard/bin/opg_approve_run.sh` blijft de
enige muterende signerflow. De batchhelper leest of parseert de private key niet
en maakt zelf geen tokens of signatures.

Aanbevolen ownership/mode: signer-beheeraccount, niet schrijfbaar voor group of
world, mode 0750 of 0755 volgens het lokale signerbeleid.

## Configuratie

Standaard leest het script:

```text
OPG_APPROVAL_ROOT=/mnt/patch-share/oracle-patch-guard/approvals
OPG_APPROVAL_PUBLIC_KEY=/secure/oracle-patch-guard/keys/approval_public.pem
```

Beide waarden kunnen als environmentvariabele worden overschreven. Gebruik de
publieke sleutel die correspondeert met de bestaande approval private key en
waarvan de SHA256 in ieder patchmanifest is gebonden. De tool gebruikt de
private sleutel nooit en schrijft geen runbestand.

Alle drie signer-scripts moeten reguliere executables zijn, geen symlink en
niet schrijfbaar voor group/world. `opg_approve_pending.sh` weigert anders
fail-closed met exit 70.

## Gebruik

```bash
/secure/oracle-patch-guard/bin/opg_list_pending.sh
/secure/oracle-patch-guard/bin/opg_list_pending.sh --pending
/secure/oracle-patch-guard/bin/opg_list_pending.sh --list
/secure/oracle-patch-guard/bin/opg_list_pending.sh --help
```

Default en `--pending` tonen uitsluitend PENDING. `--list` toont alle gevonden
runs, nieuwste eerst, met `HOST SID CYCLE CREATED STATUS RUN_ID`.

## Statuscontract

- `PENDING`: manifest, assessment, findings en PLAN-state zijn coherent en er
  bestaan nog geen approval-artifacts.
- `APPROVED`: approval-token is inhoudelijk gebonden aan exact manifest,
  host en Oracle Home; expiry en conditionals zijn geldig; manifest- en
  approval-signature zijn met de manifestgebonden public key geverifieerd.
- `COMPLETE`: dezelfde cryptografisch betrouwbare approval plus coherente
  `12_COMPLETE / COMPLETE / exit_code=0` executionmetadata.
- `UNKNOWN`: corrupte, incomplete, inconsistente of onveilig getypeerde data,
  een ontbrekende/onjuiste signature, verlopen approval of een status die niet
  ondubbelzinnig kan worden vastgesteld.

Alle runs worden per directory geïsoleerd beoordeeld. Een fout bij één target
maakt andere targets niet UNKNOWN. Alleen SID mag uit het strikt gecontroleerde
`HOST-SID-CYCLE-OEM-timestamp` RUN_ID-formaat worden afgeleid wanneer de
executionmetadata geen SID bevat.

## Aanbevolen multi-targetworkflow

```bash
/secure/oracle-patch-guard/bin/opg_list_pending.sh
/secure/oracle-patch-guard/bin/opg_approve_pending.sh --all --dry-run
/secure/oracle-patch-guard/bin/opg_approve_pending.sh --all
/secure/oracle-patch-guard/bin/opg_list_pending.sh --list
```

Default gebruik van `opg_approve_pending.sh` toont alleen READY FOR APPROVAL en
wijzigt niets. `--all --dry-run` gebruikt exact dezelfde selectie zonder de
single-run signer aan te roepen. `--all` toont eerst READY en SKIPPED, vraagt
één bevestiging en accepteert uitsluitend exact `yes`.

Voor iedere geselecteerde RUN_ID wordt de PENDING-status direct voor signing
opnieuw via `opg_list_pending.sh` vastgesteld. Daarna wordt uitsluitend
`opg_approve_run.sh RUN_ID` aangeroepen. Een succesvolle single-run returncode
is niet voldoende: de batchhelper eist vervolgens dat `opg_list_pending.sh` de
nieuwe approval cryptografisch als APPROVED verifieert. Een per-run fout stopt
de overige onafhankelijke runs niet; een globale status-/securityfout stopt de
batch wel fail-closed.

Exitcodes van de batchhelper zijn: 0 voor een geldige read-only uitvoering of
volledig geslaagde batch, 2 voor usage, 20 wanneer geen READY-run bestaat, 30
voor een per-run failure/race-skip en 70 voor een interne/securityfout.

## Cleanup

Cleanup is bewust niet gebouwd. De approval-share bevat momenteel geen apart,
ondertekend completionbewijs dat destructieve retentie voldoende sterk bindt.
`--cleanup` retourneert daarom exit 70 en wijzigt niets. PENDING, APPROVED,
COMPLETE, UNKNOWN en symlinktargets blijven onaangeraakt.
