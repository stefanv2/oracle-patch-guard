# OEM 24ai deploymentprocedure

## 1. Targetvoorbereiding

Plaats root-owned, niet door het OEM-agentaccount wijzigbare kopieën onder bijvoorbeeld `/opt/oracle-patch-guard/`:

```text
patchGD_guard.sh
patchGD_guard.conf
lib/opg_core.sh
oem_assess.sh
oem_apply.sh
oem_status.sh
```

`oem_collect_results.sh` kan op de centrale rapportagehost staan. Maak `/var/log/oracle-patch-guard` en `/var/lock/oracle-patch-guard` aan met een lokaal beoordeelde eigenaar/groep. Installeer de approval public key read-only. Controleer dat `/bin/bash`, `flock`, `sha256sum`, `openssl`, `timeout`, Oracle-clients en de organisatiespecifieke checkexecutables aanwezig zijn.

Na overdracht vanuit de Windows-zip moeten Linux-owner en modes expliciet worden gezet en gecontroleerd: directories maximaal `0750`, scripts maximaal `0750`, configuratie en publieke sleutel maximaal `0640`, waarbij de configuratie root-owned blijft. Neem geen executable bit uit het zipbestand als bewijs over.

Vul het root-owned, niet group/world-writable `/etc/oracle-patch-guard/patchGD_guard.conf` met exacte patch-, inventory-, log-, lock-, listener- en agentpaden. De back-up-, Oracle Home-recovery-, Data Pump-, Data Guard- en onderhoudsvensterhooks moeten argumentloze, read-only executables zijn met 0 voor aantoonbaar veilig, 2 voor onveilig en 3 voor onbekend. Niet configureren levert nooit fictief succes op.

## 2. Uitvoerende gebruiker en minimale sudo

Laat OEM standaard als agentaccount uitvoeren. Gebruik alleen vooraf geconfigureerde `sudo -n -u oracle` voor de root-owned OEM-wrapper die nodig is. Een conceptueel, commandospecifiek sudoerspatroon is:

```text
Cmnd_Alias OPG_ASSESS = /opt/oracle-patch-guard/oem_assess.sh *
Cmnd_Alias OPG_APPLY  = /opt/oracle-patch-guard/oem_apply.sh *
Cmnd_Alias OPG_STATUS = /opt/oracle-patch-guard/oem_status.sh *
oemagent ALL=(oracle) NOPASSWD: OPG_ASSESS, OPG_APPLY, OPG_STATUS
```

Dit is nadrukkelijk geen kant-en-klaar sudoersfragment: wildcardargumenten vergroten de bevoegdheid. Laat security lokaal beoordelen of vaste launchers per actie, sudoers-digests, SELinux, een root-owned parameterdrop en padrestricties nodig zijn. Geef nooit `NOPASSWD: ALL`, een algemene `/bin/bash`, package-manager-, delete- of rebootbevoegdheid. Als Oracle-binaries en locks zonder sudo veilig als oracle kunnen worden beheerd, laat sudo geheel weg.

Test ieder toegestaan pad met `sudo -n`; een passwordprompt moet als configuratiefout falen.

## 3. OEM-parameters

Maak minimaal deze job/targetparameters aan en markeer gevoelige locaties niet als vrij invoerveld:

- `TARGET_ORACLE_HOME`
- `RUN_ID` (bijvoorbeeld OEM job-ID plus change-ID)
- `DB_PATCH`, `OJVM_PATCH`, `MONTH`, `OPATCH_VERSION`, `OPATCH_ZIPFILE`
- `OPG_CONFIG`
- `APPROVED_MANIFEST`
- `APPROVAL_TOKEN`
- `WAVE`
- `MAX_PARALLEL_TARGETS=2`
- `FAILURE_THRESHOLD=1`
- `STOP_NEXT_WAVE_ON_FAILURE=true`
- `ASSESSMENT_MAX_AGE_MINUTES=60`

Vertrouw niet op `ORACLE_HOME`, `ORACLE_SID` of `PATH` uit een agentprofile. De wrappers roepen expliciet `/bin/bash` aan en de guard beheert de Oracle-omgeving per SID.

## 4. Gescheiden assessment en apply

Stage eerst patchsoftware en README’s read-only. Start daarna per target:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_assess.sh \
  "$TARGET_ORACLE_HOME" "$RUN_ID" "$DB_PATCH" "$OJVM_PATCH" "$MONTH" \
  "$OPATCH_VERSION" "$OPATCH_ZIPFILE" "$OPG_CONFIG"
```

Verzamel `assessment.json`, `findings.json`, `patch_manifest.json`, hashes, conflictlogs en rollbackplan. Selecteer alleen `READY` en afzonderlijk beoordeelde `CONDITIONAL` targets. `BLOCKED` en `UNKNOWN` gaan niet naar apply.

Onderteken centraal het exacte manifest, bijvoorbeeld volgens het lokaal goedgekeurde PKI-proces, en maak `approval.json` met dezelfde host/home/hash, korte vervaltijd en afzonderlijke conditional-acceptaties. Distributeer manifest, signature en token via een integriteitsbeschermd pad.

Start apply pas na handmatige vergelijking in een afzonderlijke OEM-job. Apply verkrijgt de home-lock en schrijft `preapply_assessment.json` voordat ook maar één database of listener wordt gestopt:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_apply.sh \
  "$RUN_ID" "$APPROVED_MANIFEST" "$APPROVAL_TOKEN" "$OPG_CONFIG"
```

## 5. Waves en paralleliteit

Gebruik:

```text
WAVE_0  assessment op alle targets
WAVE_1  pilot/niet-productie
WAVE_2  eerste productiebatch
WAVE_3  volgende productiebatch
```

Begin met `MAX_PARALLEL_TARGETS=2`. OEM mag verschillende hosts parallel starten; de lokale home-lock beschermt dezelfde home. Na iedere wave telt OEM exitcodes 20, 30, 40, 50, 60 en 70 als niet-succes. Bij `FAILURE_THRESHOLD=1` en `STOP_NEXT_WAVE_ON_FAILURE=true` wordt de volgende wave niet vrijgegeven. Exitcode 10 vereist bewijs dat alle conditionals centraal zijn geaccepteerd.

## 6. OEM-resultaatregels

Parse uitsluitend de laatste `OPG_RESULT|...`-regel en vergelijk `exit_code` ook met de proces-exitcode. Bewaar de volledige run-directory als jobartifact. Een ontbrekende resultaatregel is `PATCH_STATE_UNKNOWN`, nooit succes.

Na een OEM-time-out mag OEM apply niet opnieuw starten. Controleer:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_status.sh "$RUN_ID" "$OPG_CONFIG"
```

De uitvoer onderscheidt `OEM_JOB_TIMED_OUT`, `PATCH_PROCESS_RUNNING`, `PATCH_PROCESS_STOPPED` en `PATCH_STATE_UNKNOWN`. Alleen een bevoegde DBA mag na inhoudelijke state- en inventorycontrole `resume` starten; een nieuwe run-ID is geen herstelmethode.

## 7. Centrale rapportage

Kopieer na iedere wave de volledige run-directories zonder ze op targets te verwijderen. Voer centraal uit:

```bash
/opt/oracle-patch-guard/oem_collect_results.sh /secure/reports/DEMO123 \
  /secure/collected/server01/RUN1 /secure/collected/server02/RUN2
```

Het CSV/Markdown-rapport bevat host, home, databases, nieuwe RU, assessment-/executionstatus, mislukte fase, datapatchlogstatus per SID, tijden en handmatige-actie-indicatie. Vul oude RU en werkelijke downtime in de centrale OEM-laag aan op basis van de bewaarde before-inventory en state timestamps; deze MVP berekent die twee velden nog niet betrouwbaar.

## 8. Go-livecriteria

Productie is pas toegestaan na een representatieve niet-productietest met echte Oracle-output, meerdere databases in één home, gecontroleerde binary/datapatchfout, veilige resume, OEM-time-out, listener/PDB/serviceherstel en herstel van de bestaande Oracle Home. Voer daarna eerst een pilotwave met maximaal twee targets uit.
