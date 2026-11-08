# Instructies voor AI-agents — Oracle Patch Guard

Deze regels gelden voor de volledige repository. Gebruik als uitgangspunt:
`README.md`, `project/README.md`, `project/SECURITY_AND_SAFETY.md`,
`TEST_ROADMAP.md` en `docs/RELEASE_LAYOUT.md`.
Operationele procedures in deze documenten geven AI-agents geen toestemming
om de hieronder vastgelegde veiligheidsgrenzen te overschrijden.

## Development

- Werk uitsluitend op een aparte ontwikkelbranch.
- Maak vóór wijzigingen eerst een wijzigingsplan met scope en validatie.
- Wijzig alleen bestanden die noodzakelijk zijn voor de opdracht.
- Voer relevante syntaxcontroles en regressietests uit, voor zover de opdracht
  en onderstaande veiligheidsregels dit toestaan. Gebruik de tests onder
  `project/tests/` en de validatie-instructies in de README's en TEST_ROADMAP.
- Gebruik waar relevant `bash -n` en ShellCheck. Behoud voor target-side Python
  de gedocumenteerde compatibiliteit met Python 3.6.8.
- Rapporteer de uitgevoerde controles, testresultaten, eventuele regressies en
  overgeslagen controles met reden. Claim geen succes voor niet-uitgevoerde tests.
- Inspecteer vóór afronding de volledige git diff, inclusief staged wijzigingen
  en de inhoud van nieuwe, nog niet getrackte bestanden.

## Veiligheid

- Maak geen verbindingen met productie- of acceptatie-Oracle-omgevingen.
- Voer geen echte Oracle-patchcommando's uit, ook niet via wrappers of hooks.
- Gebruik geen rootrechten of sudo.
- Lees of wijzig geen credentials, tokens of secrets.
- Schakel geen bestaande securitychecks uit en omzeil ze niet.
- Behoud fail-closed gedrag en cryptografische approvals en hun verificatie.
- Zet `UNKNOWN` nooit automatisch om in `SUCCESS`, `READY` of een andere
  succesvolle uitkomst. Ontbrekende of ambigue evidence blijft blokkerend.
- Voer geen automatische rollback of cleanup uit.
- Wijzig geen actieve immutable releases, hun bestanden of de `current`-link.
  Bereid wijzigingen uitsluitend voor in de ontwikkelcheckout.

## Beperkingen

- Maak geen commits, pushes, merges of pull requests zonder expliciete toestemming.
- Overschrijf geen bestaande documentatie.
- Stop bij tegenstrijdige instructies en rapporteer de tegenstrijdigheid;
  kies niet zelfstandig een interpretatie die een veiligheidsgrens versoepelt.

## Specifiek voor OPG

- Respecteer `OPG_TEST_MODE` en `ALLOW_TEST_MODE`: testmodus is expliciet opt-in;
  productieconfiguratie behoudt `ALLOW_TEST_MODE=false`. Wijzig geen echte
  configuratie om testmodus mogelijk te maken.
- Gebruik uitsluitend geïsoleerde, gesimuleerde Oracle Homes voor tests.
  Operationele acceptatieprocedures uit TEST_ROADMAP zijn geen toestemming
  voor AI-agents om echte Oracle-omgevingen te benaderen.
- Sla bootstraptests die rootrechten vereisen over en rapporteer dit expliciet.
- AI mag nooit approvals, checksums, exitcodes of execution-state van echte
  operationele gegevens en evidence aanpassen. Vervals of corrigeer geen
  operationele evidence om een geslaagde uitkomst te verkrijgen.
- Synthetische testfixtures mogen binnen geïsoleerde tests worden aangemaakt
  en gewijzigd, ook voor approvals, checksums, exitcodes en execution-state.
  Presenteer deze fixtures nooit als echte operationele evidence.
- Bewaar bij fouten de beschikbare evidence en rapporteer de laatst bewezen
  status. Forceer geen vervolgstap bij `BLOCKED`, `UNKNOWN`, `PARTIAL` of
  `MANUAL_INTERVENTION_REQUIRED`.
