# Security and safety

## Veiligheidsgrenzen

OEM orkestreert, maar kan geen lokale `BLOCKED` of `UNKNOWN` overrulen. De guard vertrouwt uitsluitend deterministische controles, exacte hashes, expliciete state en een cryptografische manifestgoedkeuring. AI-samenvattingen mogen nooit state, checksums, exitcodes of approvals wijzigen.

De Oracle Home, patchstage, configuratie, scripts, publieke approvalsleutel en run-root moeten alleen schrijfbaar zijn voor de daarvoor aangewezen beheerders. Het OEM-agentaccount krijgt geen algemene shell- of rootrechten. Bescherm logs omdat zij hostnamen, paden, database-SIDs en commandoregels bevatten; credentials of connect strings mogen er nooit in worden opgenomen.

## Goedkeuring en integriteit

- `patch_manifest.json` wordt na assessment read-only gemaakt en zijn hash apart opgeslagen.
- Apply vergelijkt het centraal aangeleverde manifest byte-voor-byte via SHA-256 met het lokale manifest.
- Host, canonieke home, `oratab`, patchboomchecksums, OPatch-zip, recoverymanifest, onderhoudsvenstermanifest en assessmentleeftijd worden opnieuw gecontroleerd.
- Buiten testmodus zijn OpenSSL-handtekeningen over zowel manifest als volledig approval-token met de geconfigureerde publieke sleutel verplicht.
- Iedere `CONDITIONAL` finding vereist een eigen `accept_<FINDING_ID>`-waarde.
- De private signing key hoort niet op Oracle-targets of bij het OEM-agentaccount te staan.

Een databaseback-up is geen herstelroute voor beschadigde binaries. `DATABASE_BACKUP_VERIFIED`, `ORACLE_HOME_RECOVERY_VERIFIED` en `ROLLBACK_PLAN_VERIFIED` blijven daarom afzonderlijk zichtbaar. De rebuild-route blijft bovendien een expliciet te accepteren `CONDITIONAL`.

## Locking en state

De exclusieve lock is `flock`-gebaseerd en afgeleid van hostname plus canonieke home. Metadata bevat PID, host, run-ID en home. Een bezette lock wordt nooit verwijderd. Een tweede job krijgt exitcode 60. Als `flock` ontbreekt, blokkeert productie omdat exclusiviteit niet bewezen kan worden.

State wordt eerst naar een uniek tijdelijk bestand geschreven en daarna atomair verplaatst. `state_history.log` bewaart de overgangen. Een trap registreert of ontgrendelt alleen; hij voert geen rollback, cleanup, OS-update of reboot uit.

Resume ondersteunt alleen benoemde, inhoudelijk controleerbare toestanden. Binary inventory wordt opnieuw gelezen; een patch wordt niet blind herhaald. Ambiguïteit leidt tot `MANUAL_INTERVENTION_REQUIRED`.

## Commandoveiligheid

- Geen `eval`, onveilige word splitting of interactieve profiles.
- Oracle Home en SID worden per commando gezet en nadien gecontroleerd/hersteld.
- Kritieke opdrachten hebben exitcode- én fouttekstcontrole.
- Patch-ID’s, versies, run-ID’s, zipnamen, listenernamen en PDB-identifiers worden streng gevalideerd.
- Organisatiespecifieke hooks accepteren alleen een absoluut pad naar een argumentloze executable; geen shellfragment.
- Productieconfiguratie is root-owned, geen symlink en niet group/world-writable; een onveilig bestand geeft exitcode 70 vóór `source`.
- De testmodus is expliciet opt-in en productie houdt `ALLOW_TEST_MODE=false`; `--dry-run` laat read-only checks echt lopen en onderdrukt muterende opdrachten.
- Data Pump wordt uitsluitend via de geïntegreerde inventory-SQL beoordeeld; een losse hook kan die uitkomst niet tegenspreken.
- Recoveryprocedure en onderhoudsvenster zijn reguliere, niet-symlink, veilig gemodede beheerbestanden; productie vereist root-eigendom.
- OS-update en reboot geven in `apply` exitcode 70; zij vereisen een afzonderlijk, lokaal beoordeeld proces.

## Faalgedrag en bewaren

Na binary patchfalen wordt de volgende patch niet uitgevoerd. De run wordt `PARTIAL` of `MANUAL_INTERVENTION_REQUIRED`; er volgt geen cleanup, OS-update, reboot of automatische rollback. Het rapport noemt de laatst bewezen state en het exacte logbestand.

Cleanup verwijdert in deze MVP niets, zelfs na goedkeuring. Hierdoor blijven `OPatch.old`, inactive patches, `.patch_storage`, rollbackdata, logs, manifests en state beschikbaar voor forensics en herstel. Een toekomstige cleanupimplementatie moet retentie, functionele acceptatie, symlinks, exacte targets en recoverability opnieuw laten beoordelen.

## Bekende beperkingen

De JSON-lezer is doelbewust beperkt tot het door deze oplossing gegenereerde, één-veld-per-regel contract; gebruik geen willekeurig geformatteerde JSON. Voor een productie-uitrol verdient een gevalideerde `jq`-dependency of een klein, formeel parserhulpmiddel de voorkeur. De patch-README blijft altijd leidend en wordt in deze MVP alleen op aanwezigheid gecontroleerd, niet semantisch uitgevoerd. De Linux-`flock`-implementatie, werkelijke Oracle/RMAN/OEM-uitvoer en OEM-time-outsignalen zijn lokaal niet end-to-end bewezen.
