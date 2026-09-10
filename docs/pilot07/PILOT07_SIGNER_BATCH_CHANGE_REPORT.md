# Pilot07 multi-target signer change report

## Scope en gewijzigde bestanden

- `signer/opg_approve_pending.sh`: nieuwe batchorchestrator zonder eigen
  signing- of cryptografische implementatie.
- `signer/opg_list_pending.sh`: kleine read-only machine-interface en
  diagnostische reden per status; de bestaande gebruikersoutput en statusregels
  blijven gelijk.
- `project/tests/run_signer_batch_tests.sh`: 14 gerichte selectie-, race-,
  multi-target- en no-write-tests.
- `SIGNER_PENDING_GUIDE.md`: installatie en aanbevolen batchworkflow.
- `PILOT07_VALIDATION_REPORT.md`: bijgewerkte regressiematrix.

Er zijn geen wijzigingen aan manifest, signing, approval-token, PLAN, APPLY,
staging, OEM/AWX of cleanup aangebracht.

## Selectie en readiness

De helper selecteert uitsluitend runs die de bestaande fail-closed
`opg_list_pending.sh`-logica als PENDING/READY FOR APPROVAL classificeert.
APPROVED, COMPLETE en UNKNOWN worden getoond als SKIPPED. Een BLOCKED of
inconsistente assessment wordt door de bestaande vierstatuslogica UNKNOWN en
kan daardoor nooit worden geselecteerd. Geldige CONDITIONAL-runs passeren
dezelfde findings/readinessregels; `opg_approve_run.sh` blijft de definitieve
autoriteit voor de bestaande conditional-acceptatiesemantiek.

De selectie wordt direct vóór iedere single-run aanroep opnieuw uitgevoerd.
Na een succesvolle aanroep moet de bestaande statusverificatie de afzonderlijke
token- en signatureset cryptografisch als APPROVED herkennen. Alleen een
exitcode nul van het signer-script is dus niet voldoende.

## Securitygrenzen

- Geen private-keytoegang of nieuwe signingcode in de batchhelper.
- Geen globale signature, wildcard-signing of automatische approval.
- Alleen exact `--all` plus bevestiging `yes` kan signing starten.
- De bestaande single-run signer wordt per gevalideerde RUN_ID aangeroepen.
- Signer-bin, list-helper en single-run signer mogen geen symlink of
  group/world-writable executable zijn.
- Approval-root/path/typecontrole blijft bij de bestaande status- en
  single-run signerlogica; twijfel wordt UNKNOWN of exit 70.
- Een per-run failure wordt geïsoleerd; een globale inventarisatie- of
  securityfout stopt de batch.

De bestaande `opg_approve_run.sh`-bron is niet onderdeel van deze RC en is niet
gewijzigd. Installatie en regressie van die bestaande signerflow op de
signinghost blijven een releasevoorwaarde.

## Tests

De nieuwe suite bevat 14 tests voor exclusieve PENDING-selectie, BLOCKED,
UNKNOWN, APPROVED en COMPLETE skips, CONDITIONAL, verse race-hercontrole,
dry-run, exacte bevestiging, multi-targetisolatie, doorgaan na één per-run
failure, symlinkgrens, default en help. De bestaande signer-listtests en alle
bestaande Oracle Patch Guard-regressies worden aanvullend ongewijzigd gedraaid.
