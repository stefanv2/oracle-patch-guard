# OPG-05 statewrite-safety

## Scope en contract

Startpunt: `origin/main` en HEAD waren gelijk op
`5a448e3a610b24885b056003b8c2411abe28815d`; de werkboom was schoon.
Deze wijziging raakt uitsluitend betrouwbare statepublicatie en de stopgrens
voor daaropvolgende mutaties. Approval-, manifest-, SQLPATCH-, PDB-, OEM- en
mediabeleid zijn niet gewijzigd. OPG-02 en OPG-08 blijven open.

`execution_state.json` is het autoritatieve statebestand. `state_history.log`
is verplichte audit-evidence, maar autoriseert zelf geen resume of mutatie.
Een historievermelding wordt eerst geschreven en geflusht; daarna wordt het
nieuwe autoritatieve bestand via tijdelijk bestand, gecontroleerde write/close,
gerichte fileflush, rename en gerichte parentdirectoryflush gepubliceerd.
`CURRENT_STATE` en `CURRENT_PHASE` veranderen pas nadat alle bewerkingen zijn
geslaagd.

Bij een fout blijft de geheugenstate op de vorige waarde en zet de library
`OPG_STATE_WRITE_FAILED=true`. Een vaste `STATE_PUBLICATION_FAILED`-regel gaat
rechtstreeks naar stderr en bevat reden, vorige/volgende state, fase en
`manual_intervention_required=true`. Dit pad gebruikt niet `opg_log`,
`opg_mark_failure` of de defecte stateopslag en kan daarom niet recursief worden.
`opg_mark_failure` probeert state en `last_error.txt` ieder eenmaal; falen wordt
op stderr gemeld en als fout teruggegeven.

De duurzame flush gebruikt GNU coreutils `sync FILE`, zoals beschikbaar op de
ondersteunde Oracle Linux 8/9-targets. Zonder `-f` wordt `fsync(2)` gericht op
het opgegeven tijdelijke bestand uitgevoerd, niet `syncfs(2)` op het volledige
filesystem. Na de atomische rename wordt dezelfde methode op de parentdirectory
toegepast om de nieuwe directory-entry duurzaam te maken.

Na een reeds uitgevoerde mutatie stopt de huidige functie vóór de volgende
mutatie. APPLY en RESUME rapporteren daarvoor de bestaande handmatige-
interventieklasse en exitcode 50. Normale exitcodes en succesvolle routes zijn
ongewijzigd; er is geen algemene state-machine- of exitcodeherbouw uitgevoerd.

## Caller-inventaris

Directe `opg_write_state`-callers zijn: `perform_assessment`, `generate_plan`,
`stage_opatch_upgrade`, `perform_opatch_upgrade`, `stop_databases`,
`apply_binary_patches`, `start_original_databases`, `run_datapatch_all`,
`run_utlrp_all`, `validate_all`, `perform_apply`, `perform_resume` en
`opg_mark_failure`. Alle directe callers controleren of propageren nu het
resultaat. De muterende ketens stoppen vóór OPatch-promotie, shutdown,
volgende binary patch, startup, datapatch, utlrp of validatie wanneer hun
vereiste voorafgaande state niet is gepubliceerd.

`opg_mark_failure` wordt aangeroepen door `opg_run_critical` en de foutpaden in
`perform_opatch_upgrade`, database/listener stop/start en registratie,
`apply_binary_patches`, `run_datapatch_all`, `run_utlrp_all`, `validate_all`,
`perform_apply`, `perform_resume` en `handle_signal`. Deze paden voeren na de
melding geen volgende patchmutatie uit; de signal-handler behoudt zijn
best-effort karakter tijdens procesafbraak.

`opg_atomic_write` wordt onderliggend gebruikt voor autoritatieve state en
completion-markers, en rechtstreeks voor gegenereerde SQL, assessment-,
manifest-, precheck-, plan-, OPatch-metadata-, PDB-, samenvattings- en
cleanupbestanden. Alleen de atomische primitive en statecaller-contracten zijn
voor OPG-05 gewijzigd. Bestaande callers voor niet-state-artifacts vallen
buiten deze wijziging; reeds aanwezige expliciete checks zijn behouden.

## Regressiebewijs

`project/tests/run_state_write_tests.py` gebruikt schone tijdelijke runpaden en
geen Oracle-credentials of productie-installatiepaden. De definitieve suite
tegen ongewijzigde HEAD vóór de fix leverde 4 geslaagde en 7 falende controles.
De uitgebreide gerichte suite moet na de fix slagen:

- fout bij tijdelijk bestand maken, write/close, flush en rename;
- history-write- en history-flushfout met behoud van autoritatieve en
  geheugenstate;
- succesvolle historie gevolgd door state-write-, state-rename- of
  directory-flushfout, telkens zonder volgende patchmutatie;
- niet-schrijfbaar runpad en niet-recursieve stderr-fallback;
- statewrite-fout vóór de eerste mutatie, tussen DB-RU en OJVM en na een reeds
  voltooide mutatie, telkens zonder volgende patchopdracht;
- succesvolle stateovergang met overeenkomend statebestand en historie.

De kernsuite en OPG-01 ACTION-suite bewaken respectievelijk de bestaande flow en
SQLPATCH-validatie. Bash-syntax en whitespacecontrole zijn onderdeel van de
afgesproken eindvalidatie.

## Resterende risico's

De twee bestanden vormen geen filesystemtransactie. Een crash nadat de historie
is geflusht maar vóór de autoritatieve rename kan één vooruitlopende
historievermelding achterlaten. Dat record autoriseert niets; consumers moeten
`execution_state.json` blijven volgen. Als de rename slaagt maar de
parentdirectoryflush faalt, kan de diskstate al vooruitgelopen zijn terwijl de
geheugenstate bewust op de vorige waarde blijft. De duurzaamheid van de nieuwe
directory-entry is dan ambigu; automatisch doorgaan blijft verboden en vereist
handmatige interventie. Cryptografische baseline-/statebinding
blijft OPG-02. Volledige harmonisatie van state, resultaatregel en exitcode blijft
OPG-08. Filesystem-full-, hardware- en crashduurzaamheid zijn met foutinjectie
getest, niet met echte storage-faults op een productiedoelfilesystem.
