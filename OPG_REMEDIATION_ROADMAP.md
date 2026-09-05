# OPG remediation-roadmap

## Startpunt en volgorde

HEAD gecontroleerd: `b686525e8db97768b18a1dc95ff88ae398b713b3`; werkboom vooraf schoon.
De afzonderlijke OPG-01 ACTION-commit staat in HEAD en blijft intact.
Vastgelegd bewijs: ACTION 153/153, kern 118/118, bestaande regressies 405/405.
Geen tests herhaald. Historisch APPLY/SUCCESS blijft toegestaan; pogingbinding blijft open.
Bronnen: eerdere reviewcontext, OPG01_ACTION_VALIDATION.md en TEST_ROADMAP.md.
Onderstaande P0/P1/P2/P3 zijn uitvoeringsprioriteiten: P0 kritiek, P1 hoog, P2 middel, P3 laag.
Kleine fixes verdringen P0/P1 niet. Optimalisatie en Rust-hashing wachten tot veiligheidsbevindingen gesloten zijn.

## Golf 1 — bewijsintegriteit en betrouwbare mutatiegrenzen

### OPG-05 — P1: statewrite-fouten laten mutaties doorgaan

- Afhankelijkheden/combinatie: eerst uitvoeren; ondersteunt OPG-02, OPG-01/03 en OPG-08. OPG-08 apart committen.
- Besluit/grens: mislukte statepublicatie blokkeert iedere volgende patchmutatie. Foutmelding moet ook zonder schrijfbare state werken; noodzakelijke stabilisatie krijgt een expliciete grens.
- Implementatie: schrijfresultaten doorgeven en controleren bij mutatieovergangen; geen algemene state-machineherbouw.
- Tests/bewijs: injecteer write-, rename-, ruimte- en permissiefouten vóór/na mutatie; bewijs dat geen volgende patchopdracht start. Test echte filesystemfouten geïsoleerd, zonder Oracle.
- Acceptatie: geen ongepubliceerde overgang autoriseert vervolg; falen levert nooit succes op.
- Commit: uitsluitend statepublicatie en regressies. Model: Sol; Astra voor kritieke eindreview. Kosten: middel.

### OPG-02 — P0: databasebaseline is wijzigbaar bewijs

- Afhankelijkheden/combinatie: na OPG-05; vóór OPG-01/03 en OPG-06. Deel bewijsformaat, geen gecombineerde implementatiecommit.
- Besluit/grens: bepaal welke baselinebestanden en serialisatie onder het gesigneerde manifest vallen; losse onbeveiligde hashes volstaan niet. Leg migratiebeleid voor bestaande runs vast.
- Implementatie: bind baselinebytes cryptografisch aan goedgekeurde run/manifestidentiteit; verifieer vóór gebruik bij APPLY, resume en herstel.
- Tests/bewijs: gewijzigde, ontbrekende, verwisselde baseline; fout RUN_ID; oude manifestversie; ongewijzigde positieve route. Zonder Oracle uitvoerbaar.
- Acceptatie: gewijzigde of ongebonden baseline kan geen mutatie/herstelbesluit dragen.
- Commit: baselinebinding inclusief tests en migratiecontract. Model: Sol; Astra alleen bij migratie-/vertrouwensbesluit. Kosten: middel.

### OPG-06 — P1: herstel sluit PDB's vóór benodigde controles

- Afhankelijkheden/combinatie: direct na OPG-02; alleen afhankelijk van OPG-02 en OPG-05. Het volledige OPG-01/03-contract hoeft niet gereed te zijn. Aparte commit.
- Besluit/grens: onderscheid controles waarvoor PDB's open moeten zijn van bewijs van oorspronkelijk herstelde eindstate; leg fout-/onderbrekingsgedrag vast.
- Implementatie: volgorde en bewijsoverdracht aanpassen, zonder PDB$SEED-scope te verruimen.
- Tests/bewijs: MOUNTED, READ ONLY, meerdere PDB's, controlefout en restorefout. Verplicht echte Oracle 19c CDB met oorspronkelijk MOUNTED én READ ONLY PDB; mocks bewijzen viewzichtbaarheid niet.
- Acceptatie: alle verwachte containers volledig gecontroleerd, oorspronkelijke states daarna exact bewezen; anders geen COMPLETE.
- Commit: validatie-/restorevolgorde met tests. Model: Sol; Astra kritieke eindreview. Kosten: middel.

### OPG-04 — P1: racegevoelige privileged cleanup

- Afhankelijkheden/combinatie: zelfstandig beveiligingswerk in deze golf; niet vermengen met SQL/resume of hashingoptimalisatie.
- Besluit/grens: racebestendige directory-/descriptorstrategie kiezen binnen ondersteunde Python 3.6 en least privilege; geen ruimere sudo-rechten.
- Implementatie: uitsluitend cleanup-padbinding en verwijderingsoperaties; controle en gebruik moeten dezelfde vertrouwde objecten betreffen.
- Tests/bewijs: concurrente symlink-/rename-/directorywissels, retry en externe sentinelbestanden; echte Linux-filesystems en doel-Python vereist, Oracle niet.
- Acceptatie: geen verwijdering buiten geautoriseerde stage; onzekerheid behoudt data en rapporteert falen.
- Commit: cleanupbeveiliging en aanvalstests. Model: Astra ontwerp/eindreview, Sol implementatie. Kosten: hoog.

## Golf 2 — datapatchbewijs, autorisatie en containerlevenscyclus

### Resterend OPG-01 — P0 + OPG-03 — P1: bewijs en resume vormen één contract

- Afhankelijkheden/combinatie: OPG-02/05 gereed. Gezamenlijk ontwerpen; afzonderlijke commits voor pogingbewijs en resumeautorisatie, samen vrijgeven. Bestaande ACTION-fix niet herschrijven.
- Besluit: definieer duurzame pogingidentiteit, start-/completionbewijs, registrykoppeling en expliciet toegestaan historisch/no-op-bewijs. Timestamp alleen volstaat niet.
- Autorisatiematrix: normale resume binnen venster vereist equivalente approval-/bindingscontrole; verdere patchmutaties buiten venster vereisen nieuw geldig venster en geldige autorisatie. Diagnostiek blijft read-only. Noodzakelijke stabilisatie/recovery krijgt een beperkte, geaudite actieklasse en escalatiepad; nooit impliciet verdere patchmutaties.
- Implementatiegrens: pogingevidence, markerinterpretatie en checks vóór resterende mutaties; geen stilzwijgende wijziging van historisch beleid of generieke recovery-engine.
- Tests/bewijs: onderbroken poging met oude APPLY/SUCCESS; echte no-op; ontbrekend/verkeerd marker; herstart; verlopen approval/venster; alle vier actieklassen. Mocks eerst, daarna gecontroleerde Oracle 19c-datapatchonderbreking/no-op en OEM-resume.
- Acceptatie: iedere vervolgmutatie heeft actuele autorisatie en toereikend pogingbewijs; recovery omzeilt geen patchautorisatie.
- Model: Astra voor contractgate/eindreview, Sol voor beide implementaties. Kosten: hoog.

## Golf 3 — herstelbaarheid en betrouwbare operationele uitkomsten

### OPG-07 — P1: backupmetadata bewijst geen herstelbaarheid

- Afhankelijkheden/combinatie: beleidsontwerp vroeg starten; bewijs bindt via OPG-02. Apart van backupsoftwareontwikkeling houden.
- Besluit/grens: DBA/backupbeheer kiezen RMAN/Commvault-hersteldoel, RPO/RTO, retentie, benodigde database-/archivelog-/controlfile-/configuratie-/key-evidence en Oracle-Home-herstelroute.
- Implementatie: beleidsgebonden readiness/evidence; recente backupsets mogen geen volledige herstelbaarheid claimen.
- Tests/bewijs: ontbrekende keten, verlopen bewijs, verkeerd target, onbereikbare media; echte geïsoleerde restore/recovery onder gekozen beleid.
- Acceptatie: aantoonbaar haalbaar hersteldoel plus gebonden bewijs; onbekend blijft blokkerend.
- Commit: bewijscontract/readiness en gerichte tests. Model: Astra beleidsgate, Sol implementatie. Kosten: hoog.

### OPG-08 — P2: state, resultaatregel en exitcode spreken elkaar tegen

- Afhankelijkheden/combinatie: na OPG-05 en resumecontract; geen algemene CLI-herbouw.
- Besluit/grens: autoritatieve uitkomstmatrix, inclusief patchsucces met falende publicatie/cleanup; wijzig externe exitcodes alleen expliciet.
- Tests/bewijs: succes, gedeeltelijke mutatie, signalen, statewrite-/publicatie-/cleanupfout; echte OEM-jobinterpretatie naast mocks.
- Acceptatie: drie uitkomstkanalen volgen dezelfde vastgelegde matrix; geen vals operationeel succes.
- Commit: uitkomstpropagatie en contracttests. Model: Sol; Astra bij incompatibel contractbesluit. Kosten: middel.

### OPG-10 — P3: handmatige OPatch-versie is ongeverifieerd

- Afhankelijkheden/combinatie: onafhankelijk, na kritiek werk; eigen commit.
- Besluit/grens: betrouwbare versiebron uit exact gehashte media bepalen; ontbrekend/ambigu bewijs blokkeren, niet willekeurig archiefcode uitvoeren.
- Tests/bewijs: mismatch, ontbrekende/dubbele metadata, geldige media; gecontroleerde vergelijking met echte ondersteunde OPatch-distributie.
- Acceptatie: manifestversie aantoonbaar afkomstig uit dezelfde media; handmatige invoer hoogstens gecontroleerde verwachting.
- Commit: builderverificatie en tests. Model: Sol. Kosten: laag.

## Golf 4 — OPG-09: P2, productieclaims vereisen integratiebewijs

- Afhankelijkheden/combinatie: testplan begint vroeg; sluit pas na OPG-01 t/m OPG-08 en OPG-10. Geen productiefixes in deze evidencecommit.
- Besluit/grens: ondersteunde targetmatrix en claim-per-test vastleggen; historische pilots tellen alleen bij aantoonbare toepasselijkheid.
- Zonder Oracle: parsers, signatures/baseline, statefaults, autorisatiematrix, uitkomstmapping, builderfixtures. Cleanup vereist daarnaast echte filesystemconcurrentie/doel-Python.
- Gecontroleerde Oracle/OEM-omgeving: datapatch/no-op/onderbreking, PDB-zichtbaarheid/herstel, RMAN/Commvault-restore, echte PLAN/APPLY/resume/publicatie/cleanup en tweede cycle.
- Acceptatie: iedere productieclaim heeft reproduceerbaar bewijs op exacte release/configuratie; geen mock-only claim als live bewezen presenteren.
- Commit: integratiematrix, procedures en geschoonde bewijsindex. Model: Sol; Astra milestone-eindreview. Kosten: hoog.

## Besluitpoorten

| Poort | Vereiste afsluiting en bewijs |
| --- | --- |
| Volgende non-productiepilot | Alleen read-only/diagnostisch: OPG-02/05 opgelost, gerichte tests groen; bestaande ACTION-commit behouden. OPG-04 en overige open punten blijven uitgesloten van uitvoering; geen APPLY, cleanup of herstelmutaties. |
| Eerste echte muterende pilottest | OPG-02/03/04/05/08/10 opgelost en getest; resterend OPG-01 en OPG-06 geïmplementeerd, ontwerp goedgekeurd, geïsoleerde regressies groen. OPG-07-beleid en vooraf bewezen labherstel vereist. Live afsluiting van OPG-01/06/07/09 is juist pilotdoel. Volledige regressies, begrensde change en recovery-eigenaar verplicht. |
| Bredere uitrol | Alleen non-productie: OPG-01 t/m OPG-10 volledig gesloten, inclusief live bewijs. Echte CDB/PDB-, OEM-, filesystem- en hersteltests geslaagd; volledige regressies op release-SHA en Astra-milestonereview. |
| Productie-GO | Alle tien blijven gesloten op immutable release/configuratie; meerdere representatieve targets/cycles, DBA-bediening, monitoring/audit en RPO/RTO-herstel bewezen. Change-/DBA-/backupverantwoordelijken accorderen; veiligheidsrelevante open punten betekenen NO-GO. |

## Tokenzuinige uitvoering

Eén bevinding of OPG-01/03-contractset per sessie. Hergebruik deze roadmap en korte repositoryrapporten met SHA, scope, besluiten, tests en beperkingen; geen brede herreview.
Eerst gerichte regressies rood/groen; volledige suites bij afgeronde golven en vóór mutatie-/uitrolpoorten, niet na iedere kleine edit.
Geen volledige diffs/logs in chat. Sol implementeert; Astra uitsluitend ontwerp-gates en kritieke milestone-reviews.

## Eerstvolgende taak

1. OPG-05: inventariseer uitsluitend statepublicatiecallers en maak een falende regressie die vervolgmutatie na schrijffout bewijst; implementeer propagatie.
2. Model: Sol; Astra pas voor kritieke eindreview.
3. Waarschijnlijke bestanden: project/lib/opg_core.sh, project/patchGD_guard.sh, project/tests/run_tests.sh; zo nodig een gerichte statewrite-suite en kort wijzigingsrapport.
4. Minimumtests: write/rename/permissie/ruimtefout vóór en na mutatie, geen volgende patchopdracht, positieve overgang; daarna kernsuite en ACTION-suite.
5. Gebruikersbesluit: geen vooraf nodig voor fail-closed propagatie. Als noodzakelijke stabilisatie of externe exitcodes veranderen: eerst het beperkte recovery-/uitkomstcontract laten vaststellen.
