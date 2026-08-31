# Migratie Pilot06c naar Pilot07

> **SUPERSEDED — historische Pilot07-migratieprocedure.** Gebruik dit document
> niet als deployment- of runbookinstructie voor de huidige stable baseline.
> De fresh-host bootstrap installeert inmiddels de root-helpers, sudoers,
> runtimeconfiguratie en stage anchors. Zie [README.md](README.md) en
> [RELEASE_NOTES_20260831.md](RELEASE_NOTES_20260831.md).

Pilot06c blijft immutable en bestaande Pilot06c-runs worden niet geconverteerd.
Pilot07 vereist altijd een nieuwe RUN_ID, nieuwe context, nieuw plan en nieuwe
approval.

## Installatie als root (historische Pilot07-procedure)

1. Kopieer `oem-tasks/opg_media_stage_root.sh` naar
   `/usr/local/sbin/opg_media_stage_root.sh`.
2. Kopieer `oem-tasks/opg_media_stage_root.py` naar
   `/usr/local/libexec/opg_media_stage_root.py`. Dwing op beide bestanden
   `root:root 0755` af en controleer dat `/usr`, `/usr/local`,
   `/usr/local/sbin` en `/usr/local/libexec` niet schrijfbaar zijn door oracle,
   oinstall of world.
3. Maak de expliciete trusted stage anchor `/u01/stage` als `root:root 0755` en
   `/u01/stage/oracle-patch-guard` als `root:oinstall 0750`. Beide moeten echte
   directories zonder symlink zijn, niet group/world-writable en zonder
   access/default ACL die `oracle` of `oinstall` schrijfrecht geeft. De huidige
   OPG stage trust boundary begint bij `/u01/stage`; `/u01` en hogere
   directories vallen buiten deze policy en krijgen van OPG geen aanvullende
   owner-, mode-, write-bit- of symlinkvoorwaarde. De helper bewaakt de vaste
   anchor/stage-root en accepteert geen arbitraire paden.
4. Installeer de sudoersregel uit
   `config/examples/oracle-patch-guard-context.sudoers` met `visudo -cf`.
5. Plaats de artifact-verificatiesleutel als
   `/etc/oracle-patch-guard/approval_public.pem`, root-owned en niet schrijfbaar
   voor group/world. Pilot07 hergebruikt bewust dezelfde lokale trust anchor;
   iedere run bindt aan de key-SHA256.

## Cycle voorbereiden (DBA/offline signer)

1. Plaats de originele DB-RU- en OJVM-ZIP onder de cycledirectory en de originele
   OPatch-ZIP onder de bestaande centrale `opatch`-directory.
2. Genereer `artifact_manifest.json` en `artifact_manifest.sig` met
   `oem-tasks/opg_build_artifact_manifest.py` op de gecontroleerde signinghost.
3. Neem de door de tool berekende bestandsnamen, groottes en SHA256-waarden over
   in `opg_cycle.conf`; gebruik `config/examples/opg_cycle.conf` als contract.
4. Publiceer pas daarna `active_cycle`. De private key komt nooit op de target.

## Uitvoering als oracle/OEM

```text
opg_oem.sh prepare
opg_oem.sh stage-media
opg_oem.sh create-window
opg_oem.sh assess
opg_oem.sh plan
opg_oem.sh stage
# bestaande offline approvalflow
opg_oem.sh apply
```

`stage-media` mag ruim vóór het onderhoudsvenster plaatsvinden. Een geldige
stage kan door meerdere nieuwe runs voor exact dezelfde cycle/artifactidentiteit
worden hergebruikt. APPLY en resume lezen geen patchpayload van de share.

Bij deze pragmatische layout biedt Pilot07 geen inode/pathname-integriteitsclaim
tegen een kwaadwillende target-`oracle`-user die `/u01` bezit. PLAN, APPLY en
resume herberekenen daarom vóór gebruik altijd de lokale V2 tree hashes en de
OPatch-ZIP-SHA256 tegen de ondertekende en run-gebonden waarden. Iedere
inhoudelijke mutatie of vervanging blokkeert fail-closed vóór downtime; een
byte-identieke vervanging is dezelfde toegestane artifactidentiteit.

## Recovery en cleanup

Er is geen automatische rollback of destructieve cleanup. Een incomplete
`incoming`-directory wordt nooit actief. Een beheerder bewaart evidence,
onderzoekt de oorzaak en verwijdert alleen een exact geïdentificeerde oude
incoming/stage via een apart goedgekeurd beheerproces. Bestaande cycle-identiteiten
worden nooit overschreven.
