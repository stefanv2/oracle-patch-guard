# Pilot07 signer usability change report

> **SUPERSEDED — historisch Pilot07-change report.** De hierin beschreven
> oorspronkelijke COMPLETE-classificatie is vervangen door hash-bound
> `completion.json`-evidence. Gebruik voor de huidige stable baseline
> [README.md](README.md),
> [RELEASE_NOTES_20260831.md](RELEASE_NOTES_20260831.md) en
> [COMPLETION_PUBLICATION_VALIDATION_REPORT.md](COMPLETION_PUBLICATION_VALIDATION_REPORT.md).

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

De historische Pilot07-statuslogica was: PENDING vereist coherente staged
manifest-, assessment-, findings- en PLAN-
metadata zonder approval-artifacts. APPROVED vereist daarnaast inhoudelijke
tokenbinding, geldige expiry/conditionals, manifestgebonden public-key-SHA256 en
twee succesvolle RSA/SHA256-verificaties. COMPLETE vereist dezelfde crypto-
grafische approval en coherente terminale executionmetadata. Iedere ambiguity
of fout wordt per run UNKNOWN; directorynaam is alleen een gecontroleerde
SID-fallback.

In stable-20260831 vereist COMPLETE daarnaast een veilig, exact aan manifest en
approval gebonden `completion.json`. Een historische COMPLETE blijft geldig na
approval-expiry wanneer de cryptografische verificatie en bindings slagen en
de betrouwbare completiontijd op of vóór `expires_epoch` ligt.

## Cleanup-besluit

Cleanup is uitgesteld. Tijdens deze Pilot07-fase begon de centraal gestagede
`execution_state.json` als PLAN-snapshot en bestond nog geen afzonderlijk
completion-artifact. Stable-20260831 publiceert inmiddels `completion.json`,
maar dat autoriseert nog steeds geen automatische of destructieve cleanup.
`--cleanup` faalt daarom expliciet met exit 70 zonder mutatie.

## Tests en beperkingen

De nieuwe suite controleert default/`--pending`, alle vier statussen, echte RSA-
signatures, presence-only en corrupte approvals, multi-targetisolatie, metadata-
binding, gecontroleerde SID-fallback, niet-destructieve cleanupweigering en de
GNU awk warning. De volledige bestaande regressiematrix, Bash syntax en
ShellCheck worden opnieuw gerapporteerd in `PILOT07_VALIDATION_REPORT.md`.

Historische beperking in deze Pilot07-fase: COMPLETE kon alleen worden
weergegeven wanneer terminale executionmetadata aantoonbaar naar de
approvaldirectory was teruggepubliceerd. Stable-20260831 gebruikt hiervoor het
afzonderlijke, hash-bound `completion.json`.
