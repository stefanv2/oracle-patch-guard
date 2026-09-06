# OPG-02 databasebaselinebinding

## Contract

`database_state_before.csv` blijft het databasebewijs voor herstel- en
vervolgbesluiten. Patchmanifest schema 2 bevat nu
`database_state_before_sha256`: de SHA-256 van de exacte baselinebytes. De
bestaande manifest- en approval-signatures beschermen daarmee ook deze hash.
`database_count` wordt uit een structureel geldige baseline afgeleid.

Voor muterende APPLY en RESUME wordt onder de bestaande home-lock gecontroleerd
dat de baseline een leesbaar, niet-leeg regulier bestand en geen symlink is. De
header moet exact overeenkomen, iedere rij heeft exact tien geciteerde velden,
iedere SID is geldig, niet-leeg en uniek, en iedere Oracle Home is exact de
manifestdoelhome. Schema, bestandsnaam, positieve `database_count` en een
lowercase SHA-256 moeten geldig zijn en exact overeenkomen.

Een schema-1-manifest of een manifest zonder geldige baselinehash blokkeert
APPLY en muterende RESUME. APPLY behoudt de bestaande BLOCKED-uitkomst;
RESUME behoudt de bestaande handmatige-interventie-uitkomst. Status en dry-run
blijven read-only bruikbaar en autoriseren geen patchmutatie.

## Snapshot en gebruik

De validator kopieert de baseline met GNU coreutils `dd iflag=nofollow`, opent
de kopie read-only, maakt haar naamloos en valideert hash en structuur via de
open filedescriptor. Alle latere database-, listener-, PDB- en herstelbesluiten
in hetzelfde proces lezen die descriptor. Een wijziging of padwissel na de
controle verandert daardoor de gebruikte bytes niet. De aanpak gebruikt alleen
voorzieningen die op de ondersteunde Oracle Linux 8/9-targets beschikbaar zijn.

## Regressiebewijs

`project/tests/run_database_baseline_tests.py` gebruikt tijdelijke paden en
geen Oracle-credentials. De red-fase op de ongewijzigde implementatie faalde
voor beide geldige baselines omdat de bindende validator ontbrak. De suite dekt
verwijderde rijen, leeg/ontbrekend bestand, gewijzigde SID/state/home, dubbele
SID, count- en hashfouten, ontbrekende hash, oud schema, verkeerde header,
symlink, geldige single-/multi-databasebaselines en een wijziging na snapshot.
Daarnaast bewijst zij dat een mismatch vóór APPLY en vóór vroege binary- en
datapatch-resumefasen geen volgende patchmutatie start.

## Resterende risico's

De naamloze descriptor voorkomt het relevante validatie/gebruiks-gat binnen
één OPG-proces. Een kwaadwillende actor met voldoende rechten om het draaiende
proces of zijn open descriptors te manipuleren valt buiten deze bestandsbinding.
Een crash vóór manifestpublicatie kan assessmentartefacten incompleet laten;
zij kunnen dan niet worden goedgekeurd of toegepast. Bestaande schema-1-runs
moeten opnieuw worden beoordeeld en goedgekeurd voordat zij mogen muteren.
Resume-autorisatie en onderhoudsvenster-equivalentie blijven afzonderlijk open
onder OPG-03.
