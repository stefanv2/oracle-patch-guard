# Pilot07 signer usability change report

## Scope

Alleen signer-side statusweergave en de actieve GNU awk quote-warning zijn
gewijzigd. Signing, approval, manifest, PLAN, APPLY, state-machine en Pilot07
media staging/security zijn inhoudelijk ongewijzigd.

## Gewijzigde bestanden

- `signer/opg_list_pending.sh`: nieuw read-only multi-target overzicht.
- `project/tests/run_signer_pending_tests.sh`: 14 signer/awk-regressies.
- `project/oem_apply.sh`: actieve awk-regex zonder ongeldige `\"` escape.
- `project/oem_collect_results.sh`: idem.
- `project/patchGD_guard.sh`: vier actieve OS-releasepatronen gecorrigeerd.
- `SIGNER_PENDING_GUIDE.md`: installatie, configuratie en statuscontract.

Historische `patchGD_guard.sh.before-*` bestanden zijn niet opgenomen in de
publieke source-tree.

## Statuslogica

PENDING vereist coherente staged manifest-, assessment-, findings- en PLAN-
metadata zonder approval-artifacts. APPROVED vereist daarnaast inhoudelijke
tokenbinding, geldige expiry/conditionals, manifestgebonden public-key-SHA256 en
twee succesvolle RSA/SHA256-verificaties. COMPLETE vereist dezelfde crypto-
grafische approval en coherente terminale executionmetadata. Iedere ambiguity
of fout wordt per run UNKNOWN; directorynaam is alleen een gecontroleerde
SID-fallback.

## Cleanup-besluit

Cleanup is uitgesteld. De centraal gestagede `execution_state.json` begint als
PLAN-snapshot en er bestaat nog geen afzonderlijk ondertekend completionbewijs.
Dat is voldoende voor conservatieve statusweergave wanneer coherente terminale
metadata aanwezig is, maar onvoldoende sterk om automatisch/destructief data te
verwijderen. `--cleanup` faalt daarom expliciet met exit 70 zonder mutatie.

## Tests en beperkingen

De nieuwe suite controleert default/`--pending`, alle vier statussen, echte RSA-
signatures, presence-only en corrupte approvals, multi-targetisolatie, metadata-
binding, gecontroleerde SID-fallback, niet-destructieve cleanupweigering en de
GNU awk warning. De volledige bestaande regressiematrix, Bash syntax en
ShellCheck worden opnieuw gerapporteerd in `PILOT07_VALIDATION_REPORT.md`.

Bekende beperking: COMPLETE kan alleen worden weergegeven wanneer terminale
executionmetadata aantoonbaar naar de approvaldirectory is teruggepubliceerd;
de bestaande stagingflow laat daar aanvankelijk de PLAN-snapshot staan.
