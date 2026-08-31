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
- `COMPLETE`: dezelfde volledig geverifieerde approval plus een veilig regulier
  `completion.json` dat exact aan RUN_ID, host, Oracle Home, cycle, manifest-
  SHA256 en approval-SHA256 is gebonden. De completiontimestamp is canoniek,
  komt exact overeen met `completion_epoch` en ligt op of vóór de ondertekende
  `expires_epoch`.
- `UNKNOWN`: corrupte, incomplete, inconsistente of onveilig getypeerde data,
  een ontbrekende/onjuiste signature, verlopen approval zonder betrouwbaar
  completion-artifact, completion na expiry of een status die niet
  ondubbelzinnig kan worden vastgesteld.

Alle runs worden per directory geïsoleerd beoordeeld. Een fout bij één target
maakt andere targets niet UNKNOWN. Alleen SID mag uit het strikt gecontroleerde
`HOST-SID-CYCLE-OEM-timestamp` RUN_ID-formaat worden afgeleid wanneer de
executionmetadata geen SID bevat.

## Completion evidence en trust boundary

De tijdens `stage` gepubliceerde `execution_state.json` blijft de immutable
historische PLAN-state en wordt nooit overschreven. Na een succesvolle APPLY
publiceert de lokaal geïnstalleerde root-owned helper afzonderlijk
`completion.json` in exact dezelfde RUN_ID-directory. Het artifact bevat geen
nieuwe target-side signature: er wordt bewust geen private signingkey op het
target geïntroduceerd.

De helper construeert completion evidence zelf uit de lokale coherente
`12_COMPLETE / COMPLETE / exit_code=0` state, de root-controlled actieve
context en de bestaande manifest- en approvalbytes. Publicatie is atomisch,
rungebonden en non-overwriting. De signer vertrouwt completion niet zelfstandig:
hij verifieert nog steeds beide bestaande signatures, de manifestgebonden
public-keyfingerprint, alle approvalbindings en conditionals, en vergelijkt
daarna beide SHA256-bindings en de completiontijd met de approval-expiry.

Dit is target-published lifecycle evidence binnen de bestaande target/root-
helpertrustgrens, geen cryptografische targetattestatie. Een gecompromitteerde
root blijft buiten deze bescherming. `completion.json` kan later input zijn
voor een afzonderlijk ontworpen retentionbeleid, maar autoriseert nu geen
automatische cleanup.

## Runtimepaden

De signer resolveert `APPROVAL_ROOT` en `APPROVAL_PUBLIC_KEY` standaard uit
`/etc/oracle-patch-guard/patchGD_guard.conf`, zonder het bestand te sourcen.
Voor de bestaande signer-layout hebben `OPG_APPROVAL_ROOT` en
`OPG_APPROVAL_PUBLIC_KEY` expliciet precedence; `OPG_CONFIG_FILE` kan een ander
veilig configbestand aanwijzen. Alle opgeloste waarden moeten absolute,
lexicaal veilige paden zijn. Een ontbrekende, lege, dubbele, relatieve of
ongeldige waarde resulteert in `UNKNOWN`/exit 30.

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
