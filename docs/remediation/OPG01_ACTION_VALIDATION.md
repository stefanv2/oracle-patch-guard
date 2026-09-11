# OPG-01: ACTION-validatie (gedeeltelijke correctie)

## Uitgangspunt en scope

Voor wijzigingen zijn HEAD, lokale main en remote main gecontroleerd op
`57a5192c92f35a6d95ea08a5a0e86da950939571`. De werkboom was schoon.
De tien bestaande regressiesuites leverden vóór wijzigingen samen 405 geslaagde
tests en nul fouten op. Het ACTION-validatiegat was op deze commit aanwezig.

Het vooraf vastgelegde plan was: ACTION opnemen in de SQLPATCH-records, één
strikte validator gebruiken voor post-datapatch, marker-resume en eindvalidatie,
en historische registraties blijven toestaan. Exitcodes, state-machine,
approval-, registry-, PDB-, service- en overige veiligheidsvoorwaarden blijven
ongewijzigd. OPG-02 tot en met OPG-10 vallen buiten deze wijziging.

## Bewijscontract

De twee SQLPATCH-queries selecteren de maximale ACTION_TIME per patch/container
over **alle acties en statussen**. Er wordt niet vooraf op APPLY of SUCCESS
gefilterd. Alle rijen met die maximale timestamp blijven behouden. De parser
weigert meerdere rijen voor dezelfde combinatie, ook identieke duplicaten.

Het recordformaat is:

```text
CDB_SQLPATCH|CON_ID|CONTAINER_NAME|PATCH_ID|ACTION|STATUS|ACTION_TIME
```

Non-CDB gebruikt de bestaande conventie `0|NONCDB`. Root en verwachte PDB's
gebruiken hun exacte ID en naam uit de bestaande verwachte-containerlijst.
PDB$SEED blijft buiten de bestaande scope. Alleen de exacte verwachte RU/OJVM
en exact `APPLY|SUCCESS` worden geaccepteerd. Ontbrekende, onbekende of
verschoven velden, extra velden, onbekende uitvoer, ontbrekende combinaties,
onverwachte containers/patch-ID's en afgebroken records worden geweigerd.
Lege SQL*Plus-regels en de bestaande testmodus-MOCK-header zijn geen records.

De volledige eindvalidatie gebruikt nu een afzonderlijke verse SQLPATCH-query
via dezelfde validator, ook voor non-CDB. Het bewijs staat in
`validation_sqlpatch_<SID>.log`; de post/resume-lognaam blijft ongewijzigd.
De oude status-only SQLPATCH-query en grep-controles zijn verwijderd.
`sqlpatch_after.csv` behoudt de eerste vier kolommen en voegt ACTION, container-ID
en containernaam toe; ACTION_TIME wordt nu ingevuld en er is één rij per
gevalideerde patch/containercombinatie. Externe CSV-consumenten moeten deze
uitbreiding kunnen verwerken. In de repository zijn geen andere parsers voor
dit CSV-formaat aangetroffen.

De precheck-query `SQLPATCH_ERRORS` blijft intact: deze telt bestaande fouten
en levert geen bewijs dat de verwachte patch actief geïnstalleerd is.
Bestaande mockfixtures zijn naar het nieuwe recordformaat bijgewerkt zonder
testverwachtingen te verlagen.

## Historisch bewijs en resterend onderdeel van OPG-01

Een eenduidige historische laatste APPLY/SUCCESS blijft toegestaan, inclusief
resume met een geldig completion-marker zonder nieuwe datapatchuitvoering.
Een marker slaat de verse registrycontrole niet over. Testacceptatie betekent
uitsluitend dat dit onderdeel van de validator slaagt; alle overige
veiligheidsvoorwaarden blijven gelden.

Dit bewijst **niet** dat een nieuwe, nog onvoltooide datapatchpoging succesvol
is afgerond. Daarvoor ontbreekt een betrouwbare koppeling tussen de huidige
poging, de log/completion-evidence en de relevante registryregistraties per
patch/container. Alleen een nieuwste APPLY/SUCCESS is daarvoor onvoldoende.
Een toekomstige ontwerpkeuze moet bepalen wanneer historisch bewijs expliciet
mag worden hergebruikt (bijvoorbeeld een legitieme datapatch-no-op) en welk
duurzaam pogingbewijs daarvoor vereist is. Strikte verplichting van een nieuwe
registryrij zou huidige succesvolle no-op- en historische-resumescenario's
kunnen weigeren. Dit beleid is hier bewust niet gewijzigd: **OPG-01 is niet
volledig opgelost**.

## Gerichte regressies

`python3 project/tests/run_sqlpatch_action_tests.py` voert 153 controles uit:
17 scenario's voor non-CDB, root en meerdere PDB's, elk via post-datapatch,
marker-resume en volledige eindvalidatie. De suite gebruikt de echte gegenereerde
SELECTs, echte Bash-validator en echte routefuncties. SQLite voert de portable
MAX/equality-selectie uit; Oracle-aanroepen en niet-gerelateerde checks zijn
gestubd. Elke subprocess krijgt een schone omgeving en tijdelijke run/home-paden.

Scenario's: APPLY/SUCCESS; nieuwste ROLLBACK/SUCCESS; APPLY gevolgd door ROLLBACK;
ROLLBACK gevolgd door APPLY; RU-rollback; APPLY/WITH ERRORS; ontbrekende ACTION;
onbekende ACTION; conflicterende ACTIONs met gelijke maximale timestamps;
historische APPLY/SUCCESS; ontbrekende combinatie; duplicaat; verkeerd patch-ID;
verkeerde containernaam; extra veld; gedeeltelijk extra record; afgebroken output.
De rollbackvarianten controleren ook OJVM in de laatste verwachte PDB terwijl
root en de andere combinaties correct zijn.

De definitieve suite op de ongewijzigde reviewcommit: **91 geslaagd, 62 gefaald**
(exit 1). Dezelfde suite met de correctie: **153 geslaagd, 0 gefaald** (exit 0).
De eerste red-run vond vóór de implementatiewijziging plaats; de definitieve
suite is daarna opnieuw tegen een schone kopie van de reviewcommit uitgevoerd.

De tests voeren geen echte Oracle-patching uit. SQLite bewijst geen Oracle
viewzichtbaarheid, SQL*Plus-integratie of gedrag op een echte database. Die
integratiebeperkingen en het bestaande containerbeleid zijn niet aangepast.

## Volledige regressieresultaten na de correctie

Alle suites zijn uitgevoerd vanuit tijdelijke WSL-kopieën met een schone
omgeving, zonder productiecredentials. Alleen de bootstrap-suite draaide als
WSL-root voor ownershiptests, met tijdelijke installatiepaden en visudo-mock.

| Suite | Vooraf geslaagd | Na correctie geslaagd | Fouten na correctie |
| --- | ---: | ---: | ---: |
| run_tests.sh | 118 | 118 | 0 |
| run_open_checks_tests.sh | 30 | 30 | 0 |
| run_pilot05b_tests.sh | 39 | 39 | 0 |
| run_oem14_approval_tests.sh | 13 | 13 | 0 |
| run_oem_wrapper_tests.sh | 55 | 55 | 0 |
| run_pilot07_tests.sh | 62 | 62 | 0 |
| run_signer_pending_tests.sh | 34 | 34 | 0 |
| run_signer_batch_tests.sh | 15 | 15 | 0 |
| run_completion_publication_tests.sh | 17 | 17 | 0 |
| run_bootstrap_tests.sh | 22 | 22 | 0 |
| Bestaande suites totaal | 405 | 405 | 0 |
| Nieuwe ACTION-suite | 91 (62 fouten) | 153 | 0 |

Alle Bash-bestanden slagen voor `bash -n`; de nieuwe Python-suite slaagt voor
de bestaande Python-3.6-compatibiliteitschecker. ShellCheck op de gewijzigde
Bash-bestanden meldt uitsluitend de drie reeds bestaande SC2034-waarschuwingen
voor LOCK_ROOT, COMMAND_TIMEOUT_SECONDS en ALLOW_TEST_MODE (exit 1).
`git diff --check` slaagt. Er is geen commit gemaakt en niets gepusht.
