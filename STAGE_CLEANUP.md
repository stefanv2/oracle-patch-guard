# Lokale stage-cleanup

Oracle Patch Guard verwijdert na een bewezen succesvolle patchrun automatisch uitsluitend de lokale execution-stage van die run. De centrale patchmedia, lifecycle-evidence en herstelgegevens blijven behouden.

De privileged media-engine ondersteunt als minimale target-runtime Python
3.6.8, zoals standaard beschikbaar op de gebruikte Oracle Linux-generatie.

## Automatische happy-path

De volgorde is strikt:

1. APPLY en technische VALIDATE slagen.
2. De execution-state is exact `12_COMPLETE` / `COMPLETE` / `exit_code=0`.
3. `completion.json` wordt succesvol gepubliceerd en is cryptografisch aan hetzelfde manifest en dezelfde approval gebonden.
4. De cleanup-engine verifieert de completion, signatures, conditionals, stage identity en overige runreferenties opnieuw.
5. Alleen `/u01/stage/oracle-patch-guard/ready/<cycle>/<identity>/` wordt atomisch losgekoppeld en verwijderd.
6. Buiten de stage wordt een autoritatief auditrecord geschreven in `/var/lib/oracle-patch-guard/stage-cleanup/<RUN_ID>.json`. De runfolder krijgt daarnaast een niet-autoritatieve kopie `stage_cleanup.json`.

Een cleanup-fout verandert het patchresultaat niet. De run blijft `COMPLETE`; de wrapper rapporteert dan `completion=PUBLISHED|cleanup=FAILED_RETAINED`.

## Cleanup-statussen

| Status | Betekenis |
|---|---|
| `PURGED` | De gebonden lokale execution-stage is verwijderd en audit-evidence is vastgelegd. |
| `ALREADY_PURGED` | Een geldig autoritatief purge-record bewijst dat dezelfde cleanup al is voltooid. |
| `BLOCKED_NOT_RELEASED` | Een coherente COMPLETE-state en succesvolle completion-publicatie konden niet volledig worden bewezen. |
| `BLOCKED_REFERENCED` | Een andere niet-vrijgegeven run kan dezelfde stage identity nog nodig hebben. |
| `FAILED_RETAINED` | Cleanup kon niet betrouwbaar worden afgerond; COMPLETE blijft intact en resterende data wordt behouden. |
| `NOT_REQUIRED` | Lokale immutable media is in de betreffende test-/compatibiliteitsconfiguratie niet actief. |

## Handmatige retry

Een DBA kan uitsluitend voor een expliciete run een mislukte of onderbroken cleanup opnieuw aanbieden:

```bash
opg_oem.sh cleanup-stage --run-id <RUN_ID>
```

De handmatige route gebruikt exact dezelfde privileged cleanup-engine en dezelfde controles als automatische cleanup. Er is geen `--force`. Niet-terminale, onduidelijke of nog gerefereerde runs worden fail-closed geweigerd.

## Behouden evidence en verwijderde data

Cleanup verwijdert alleen de lokale directory `ready/<cycle>/<identity>/`, inclusief de daarin opgenomen uitgepakte DB RU/OJVM-media, de lokale OPatch-ZIP en de lokale kopieën van het artifactmanifest.

Cleanup verwijdert nooit:

- centrale ZIPs, cyclemetadata of artifactmanifesten op de share;
- `$ORACLE_HOME/.patch_storage`;
- `/var/log/oracle-patch-guard/<RUN_ID>` en execution-state/history;
- patch-, recovery- en rollbackevidence;
- approvals, signatures en `completion.json`;
- `/var/lib/oracle-patch-guard/current_run.json`.

`active_stage` wordt alleen verwijderd wanneer de pointer exact de gepurgde identity bevat. Een pointer naar een andere identity blijft ongewijzigd. Stage-publicatie, APPLY/resume en cleanup coördineren via dezelfde medialock, zodat gebruik en verwijdering niet kunnen racen.

Na purge blijven statusraadpleging en herkenning van een COMPLETE-run gebaseerd op de bewaarde lifecycle- en completion-evidence. Een geldige purge-marker voorkomt dat resume de verwijderde lokale media opnieuw probeert te initialiseren.
