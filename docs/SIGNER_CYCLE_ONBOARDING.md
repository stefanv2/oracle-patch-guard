# Signer-side cycle onboarding

`signer/opg_prepare_cycle.sh` en de bijbehorende Python-helper automatiseren
onboarding zonder wijzigingen aan de core, state-machine of OEM-jobs.
De bestaande `opg_build_artifact_manifest.py` blijft de enige signer.
Python 3.6+, Linux, OpenSSL en een filesystem met flock, hardlinks, atomic rename
en directory-fsync zijn vereist. Voer uit als de beheerder die de centrale
configuratie en cycledirectory bezit (operationeel doorgaans root).

## Installatie en invoer

Installeer met root-owner en mode 0755 in `/secure/oracle-patch-guard/bin/`:

- `signer/opg_prepare_cycle.sh`
- `signer/opg_prepare_cycle.py`
- `oem-tasks/opg_build_artifact_manifest.py`

Houd ook de volledige signer-directoryketen vrij van symlinks en group/world
schrijfrecht. De wrapper accepteert uitsluitend reguliere bestanden en veilige
directories, eigendom van root of de uitvoerende signer-user. Binnen de ingestelde
patch-root is ook expliciet de lokale owner `oracle` toegestaan voor de share,
cycledirectories en media/configbestanden (PATCH_MANAGED: geen group/world-write).
Bij validatie van deze paden gebruikt de chain boven de patch-root PATCH_ANCESTOR:
trusted owners en echte directories zonder symlinks blijven vereist, maar writable
ancestors zijn toegestaan. Dit vertrouwt het beheer van de mount/share-chain;
het biedt geen bescherming tegen vervanging door iemand met schrijfrecht daarop.
Paden met `..` worden geweigerd. Paden buiten de patch-root, keys en signer-tooling gebruiken
de strenge SIGNER_SECURE-context en blijven uitsluitend root/signer-owned;
een ontbrekend `oracle`-account
verruimt de toegestane owners niet. Root-owned sticky
ancestors zoals `/tmp` zijn toegestaan; de eigen invoer- en outputdirectories
zelf mogen niet group/world-writable zijn. Verruim share-rechten niet om de
controle te omzeilen.

Standaard keypaden (pas expliciet aan de bestaande signerinstallatie aan):

- private: `/secure/oracle-patch-guard/approval_private.pem`, mode 0600/0400;
- public: `/secure/oracle-patch-guard/approval_public.pem`, niet group/world-writable.

De private key blijft op de signer. `activate` gebruikt uitsluitend de public key.
Opties `--private-key`, `--public-key`, `--builder`, `--patch-root` en
`--config-dir` zijn expliciete beheerdersinstellingen; geef deze wrapper geen
onbeperkte sudo-delegatie aan onvertrouwde accounts.

Voorbeeldmedia, vooraf aangeleverd uit een vertrouwde Oracle-download:

```text
/mnt/datadomain/software/patches/Linux/OKT2026/p12345678_190000_Linux-x86-64.zip
/mnt/datadomain/software/patches/Linux/OKT2026/p87654321_190000_Linux-x86-64.zip
/mnt/datadomain/software/patches/Linux/opatch/p6880880_190000_Linux-x86-64.zip
```

De IDs hierboven zijn placeholders. Alleen dit bestaande Linux 19c
bestandsnaampatroon wordt ondersteund. ZIP CRC, patch-ID-directory, dubbele en
onveilige ZIP-paden worden gecontroleerd. De OPatch-versie wordt daadwerkelijk
gelezen uit `OPatch/version.txt`; er is geen hardcoded gewenste versie.
Een syntactisch geldige oudere versie wordt dus niet automatisch afgewezen.
Deze tool bewijst geen Oracle-herkomst: controleer de downloads tegen Oracle's
vertrouwde bron/checksums voordat ze als signer-input worden aangeboden.

## Prepare, review, activate

```bash
/secure/oracle-patch-guard/bin/opg_prepare_cycle.sh prepare OKT2026 \
  --db-ru 12345678 --ojvm 87654321
```

Prepare schrijft eerst in een private tijdelijke directory, roept de bestaande
builder aan, verifieert de signature en vergelijkt het volledige artifactobject
met opnieuw gelezen media. Daarna publiceert het manifest, signature en exact
gegenereerde `opg_cycle.conf` met exclusieve writes. `.opg-prepared` wordt als
laatste gepubliceerd en bindt aan de manifesthash. Geen runtimeconfig of
`active_cycle` wordt tijdens prepare gewijzigd.

Controleer handmatig `opg_cycle.conf` en `artifact_manifest.json`, met bijzondere
aandacht voor cycle, IDs, SHA256 en OPatch-versie. Activeer daarna expliciet:

```bash
/secure/oracle-patch-guard/bin/opg_prepare_cycle.sh activate OKT2026
```

Activate herhaalt de volledige verificatie en vereist de preparation-marker.
Het vervangt de unieke letterlijke `OPATCH_ZIP_SHA256=`-regel in
`oracle-patch-guard/config/patchGD_guard.conf`, en schrijft daarna
`oracle-patch-guard/config/active_cycle`. Beide bestaande bestanden moeten
aanwezig en veilig zijn. Owner, group en mode worden behouden; data en directory
worden gefsynct en de inhoud wordt na schrijven opnieuw gelezen. Houd de
runtimeconfig als vertrouwde declaratieve config: dynamische shellcode die later
de hash overschrijft is geen ondersteunde configuratie.

Resultaten zijn `OPG_CYCLE_PREPARE|cycle=...|status=READY_TO_ACTIVATE` en
`OPG_CYCLE_ACTIVATE|cycle=...|status=ACTIVE`. Operationele fouten geven
`OPG_CYCLE_<fase>|status=BLOCKED`, uitleg op stderr en exitcode 20.
Argparse-gebruiksfouten geven exitcode 2. De builder-output wordt niet doorgestuurd.
Er worden geen target-, database- of Oracle Home-acties uitgevoerd.

## Herhaling, fouten en grenzen

- Herhaald activeren van dezelfde geldige cycle is veilig en schrijft niets
  wanneer beide configuratiebestanden al kloppen.
- Prepare weigert ieder bestaand manifest, signature, cycle-config of marker,
  ook als de inhoud identiek is. Na een gedeeltelijke publicatie: bewaar evidence,
  onderzoek de fout en laat een beheerder de specifieke incomplete bestanden
  opruimen. Er is geen automatische overschrijving of cleanup van cycles.
- Een centrale flock serialiseert deze wrappers. Handmatige writers en targets
  nemen dit slot niet. Voer activatie uit zonder gelijktijdige bootstrap/staging
  of andere config/media-writers.
- De twee centrale bestanden kunnen zonder corewijziging geen enkele gezamenlijke
  atomaire transactie vormen. `active_cycle` is altijd een volledig oud of nieuw
  bestand. Bij afgevangen fouten probeert de wrapper beide oude bestanden terug
  te zetten. Bij SIGKILL, stroomuitval of falende rollback kan de runtimehash al
  nieuw zijn terwijl de oude cycle nog actief is. Stop orchestration, controleer
  beide bestanden en herhaal `activate` voor de gecontroleerde cycle om dit te
  herstellen. Een reader kan ook tijdens normale activatie kort beide generaties
  zien; plan daarom dit korte beheerinterval buiten targetactiviteiten.
- Een gewijzigde globale OPatch-ZIP kan eerder voorbereide cycles ongeldig maken;
  herverificatie blokkeert die cycles. Bewaar originele media voor herstel.
- POSIX owner/mode blijven behouden; bijzondere ACLs, xattrs en SELinux-labels
  worden niet gekopieerd. Gebruik standaard directory-inheritance en controleer
  de lokale share-policy vóór deployment. Dit beschermt niet tegen een
  gecompromitteerde signer/root of een parallel schrijvende vertrouwde beheerder.

Tests: `python3 project/tests/run_prepare_cycle_tests.py` en
`bash project/tests/run_pilot07_tests.sh` op Linux. De eerste suite gebruikt echte
RSA-signatures en ZIPs; alleen de gerichte write-failure wordt geïnjecteerd.
