# OPG-06 PDB-validatievolgorde

## Contract en wijziging

Voor iedere draaiende CDB leest OPG de oorspronkelijke PDB-states uit de door
OPG-02 gevalideerde baseline-snapshot. Alleen de daarin verwachte user-PDB's
worden tijdelijk READ WRITE gemaakt. Na datapatch wordt de bestaande strikte
OPG-01 SQLPATCH-validatie uitgevoerd terwijl die containers toegankelijk zijn.
Het gevalideerde SQLPATCH-resultaat krijgt een completion-marker die run, SID,
Oracle Home, stap en SHA-256 van de volledige output bindt.

Pas daarna herstelt OPG iedere PDB naar haar oorspronkelijke MOUNTED, READ ONLY
of READ WRITE-state en leest het resultaat opnieuw uit de database. De latere
eindvalidatie verifieert marker, outputhash en de volledige OPG-01-parser opnieuw,
maar voert geen containerafhankelijke SQLPATCH-query meer uit nadat PDB's zijn
hersteld. `PDB$SEED` blijft door `con_id > 2` en de bestaande naamcontrole buiten
de mutaties. Non-CDB gebruikt dezelfde bestaande datapatchvalidatie zonder
PDB-mutaties.

Bij een SQLPATCH-fout wordt altijd een gecontroleerde herstelpoging gedaan. Het
oorspronkelijke validatiefalen wordt gelogd; een aanvullende herstelfout wordt
apart gemeld en leidt tot handmatige interventie. Een validatie-, marker- of
herstelfout publiceert state `09_DATAPATCH_COMPLETE` niet en kan daardoor niet
richting `COMPLETE` doorgaan. Exitcodes, approvalcontract en bestaande
state-machineovergangen zijn niet gewijzigd. Wanneer `run_datapatch_all` een
formele `MANUAL_INTERVENTION_REQUIRED`-state publiceert, geeft `perform_apply`
dezelfde status en exitcode 50 door in `OPG_RESULT`. Alleen een echte
datapatch-commandfout behoudt de bestaande `PARTIAL`-status en exitcode 40.

## Testbewijs

De eerste gerichte run op de bestaande implementatie gaf 9 geslaagde en 3
falende controles. De inhoudelijke fouten waren: geen herstel na SQLPATCH-falen,
geen correcte gecombineerde validatie-/herstelfout en een nieuwe SQLPATCH-query
in de eindvalidatie na stateherstel.

`project/tests/run_pdb_validation_order_tests.py` controleert MOUNTED, READ ONLY,
READ WRITE, gemengde PDB-states, validatie vóór herstel, validatie- en
herstelfouten, falende eindstatecontrole, het ontbreken van stateprogressie bij
fouten, non-CDB en de bestaande `PDB$SEED`-grens. Aanvullende perform-apply-tests
controleren de uiteindelijke machine-readable status, fase en exitcode voor alle
MANUAL-datapatchfouten en bewaken afzonderlijk de PARTIAL-commandfout. Hun
gerichte red-fase gaf 15 geslaagde en 5 falende controles; na de propagatiefix
slagen alle 20. De suite gebruikt uitsluitend tijdelijke testpaden en mocks.

## Resterende live-testbeperking

Mocks bewijzen de volgorde en fail-closed-logica, maar niet Oracle-view-
zichtbaarheid of echt PDB-gedrag. Volledige afsluiting vereist een gecontroleerde
Oracle 19c CDB-test met minimaal één oorspronkelijk MOUNTED PDB, één oorspronkelijk
READ ONLY PDB, gemengde states, succesvolle datapatch plus SQLPATCH-validatie,
geforceerde validatie- en restorefouten en bewijs dat alle oorspronkelijke states
exact zijn hersteld. In deze wijziging is geen echte Oracle-patching uitgevoerd.
