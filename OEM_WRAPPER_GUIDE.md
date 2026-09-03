# Oracle Patch Guard OEM-wrapper

## Ontwerpregel

OEM kiest alleen de target(s) en de fase; Patch Guard bepaalt veilig de rest uit gevalideerde context.

`oem-tasks/opg_oem.sh` bevat geen patch-, approval- of state-machinebeslissingen. Het script doet uitsluitend:

1. centrale cyclemetadata defensief lezen;
2. precies één actief database/SID/Oracle-Home-paar ontdekken;
3. een atomische, rungebonden hostcontext via een strikt begrensde root-helper maken of valideren;
4. de bestaande scripts met afgeleide argumenten aanroepen.

De bestaande lange OEM-commands blijven bruikbaar als fallback.

De wrapper verwacht dat deze bestaande site-specifieke scripts op het target aanwezig blijven:

- `oem-tasks/opg_prepare_host.sh`
- `oem-tasks/opg_create_window.sh`
- `oem-tasks/opg_assess_task.sh`
- `oem-tasks/opg_stage_approval.sh`
- `current/project/patchGD_guard.sh`
- `current/project/oem_apply.sh`

De eerste drie zijn niet in de aangeleverde Pilot05g/OEM14-bronset opgenomen en zijn daarom niet gewijzigd of opnieuw geïmplementeerd. Ontbreken geeft fail-closed `BLOCKED|ROUTING`.

## Centrale metadata

Plaats de actieve-cyclepointer als regulier, niet-symlink en niet group/world-writable bestand:

```text
/mnt/datadomain/software/patches/Linux/oracle-patch-guard/config/active_cycle
```

Dit is `${OPG_ROOT}/config/active_cycle` en nadrukkelijk niet
`current/config/active_cycle`. `current` selecteert de immutable softwarerelease;
`active_cycle` selecteert de operationele patchcycle.

Voorbeeldinhoud:

```text
APR2026
```

Plaats de metadata naast de RU/OJVM-directories:

```text
PATCH_ROOT/APR2026/opg_cycle.conf
```

Voor lokale immutable staging zijn exact deze keys vereist en toegestaan:

```text
PATCH_CYCLE
DB_RU_PATCH_ID
OJVM_PATCH_ID
OPATCH_VERSION
OPATCH_ZIP
DB_RU_ZIP
DB_RU_ZIP_SHA256
OJVM_ZIP
OJVM_ZIP_SHA256
OPATCH_ZIP_SHA256
ARTIFACT_MANIFEST
ARTIFACT_MANIFEST_SIG
```

Het bestand wordt nooit gesourcet. Voor APR2026 zijn de inhoudelijke waarden
`PATCH_CYCLE=APR2026`, `DB_RU_PATCH_ID=39034528`,
`OJVM_PATCH_ID=38906621` en `OPATCH_VERSION=12.2.0.1.52`.

De OPatch-versie moet uit `OPatch/version.txt` van de werkelijk gebruikte ZIP
worden gelezen en exact gelijk zijn in `opg_cycle.conf`,
`artifact_manifest.json` en de ZIP. Zie
[PATCH_CYCLE_GUIDE.md](PATCH_CYCLE_GUIDE.md) voor het volledige contract en de
signerprocedure.

De OPatch-ZIP wordt bewust gevalideerd onder de bestaande `OPATCH_ROOT` uit `/etc/oracle-patch-guard/patchGD_guard.conf`. Voor de bewezen Pilot05g-config is dat:

```text
/mnt/patch-share/oracle-patches/opatch/p6880880_190000_Linux-x86-64.zip
```

Dit behoudt de bestaande core-semantiek; de wrapper introduceert geen tweede OPatch-locatie.

Aanbevolen modes:

```bash
chown root:oinstall active_cycle opg_cycle.conf
chmod 0640 active_cycle opg_cycle.conf
```

## Target discovery

Productiediscovery gebruikt `/etc/oratab` of het daarin via de vertrouwde lokale config aangewezen bestand. Een entry telt alleen mee wanneer:

- SID, autostartflag en absoluut Oracle-Homepad valide zijn;
- SID geen ASM-entry is en het pad geen Grid-home is;
- de home een uitvoerbare `bin/oracle` bevat en zelf geen symlink is;
- een actieve `ora_pmon_<SID>` exact uit `<ORACLE_HOME>/bin/oracle` draait.

Nul of meer dan één kandidaat geeft `BLOCKED`. Er wordt nooit op volgorde, directorydatum of eerste match gekozen.

## Run-context

In de normale operationele flow maakt `prepare` atomisch de nieuwe formele
RUN_ID/context:

```text
/var/lib/oracle-patch-guard/current_run.json
```

Productiemodes zijn directory `root:oinstall 0750` en bestand `root:oinstall 0640`. De context bevat RUN_ID, short hostname, FQDN, SID, Oracle Home, cyclemetadata, configpad, maintenance-window-ID en creatietijd.

De OEM-wrapper blijft volledig als `oracle` draaien. Alleen deze context-filesystemhandelingen gaan met `sudo -n` naar de lokale `/usr/local/sbin/opg_context_root.sh`:

- `prepare-root`: uitsluitend de vaste contextroot voorbereiden;
- `publish`: gevalideerde context-JSON via stdin atomisch als `current_run.json` publiceren;
- `rotate <reden>`: uitsluitend een terminale context archiveren en vervangen, met historyregistratie;
- `publish-approval-stage <RUN_ID>`: uitsluitend vier vaste PLAN-artifacts uit een gevalideerde tarstream onder de vaste approvalroot publiceren;
- `publish-completion <RUN_ID>`: uitsluitend voor de actieve, lokaal coherente
  `12_COMPLETE`-run een nieuw hashgebonden `completion.json` atomisch toevoegen.

De helper accepteert geen pad of command van de wrapper. In productie zijn de contextroot (`/var/lib/oracle-patch-guard`) en runroot (`/var/log/oracle-patch-guard`) in de root-owned helper vastgelegd. De centrale sharecopy is uitsluitend installatiemedium en is nooit een toegestaan sudo-target. Onbeschikbare non-interactive sudo, afwijkende helperownership/mode, een symlink, een onveilige parentdirectory, ongeldige JSON, een niet-terminale oude run of een filesystemfout stopt fail-closed.

`OPG_ROOT` en `APPROVAL_ROOT` komen in productie uitsluitend uit de root-owned,
niet group/world-writable `/etc/oracle-patch-guard/patchGD_guard.conf`. De
root-helper parseert alleen exact `APPROVAL_ROOT` en voert de config nooit als
shellcode uit. Relatieve, lege, dubbele of lexicaal onveilige paden worden
fail-closed geweigerd. Testfixtures behouden uitsluitend onder expliciete
testmodus hun begrensde `OPG_TEST_*`/`OPG_CONTEXT_HELPER_TEST_*` overrides.

Installeer de helper en de meegeleverde sudoersregel als root:

```bash
install -o root -g root -m 0755 \
  oem-tasks/opg_context_root.sh \
  /usr/local/sbin/opg_context_root.sh

install -o root -g root -m 0440 \
  config/examples/oracle-patch-guard-context.sudoers \
  /etc/sudoers.d/oracle-patch-guard-context

visudo -cf /etc/sudoers.d/oracle-patch-guard-context
sudo -u oracle sudo -n \
  /usr/local/sbin/opg_context_root.sh prepare-root
```

De helper moet `root:root 0755` blijven en mag via mode of ACL niet schrijfbaar zijn voor `oracle` of `oinstall`. Ook `/usr/local/sbin`, `/usr/local`, `/usr` en `/` moeten root-owned, niet-symlink en niet group/world-writable zijn. Controleer dit vóór ingebruikname bijvoorbeeld met `namei -l /usr/local/sbin/opg_context_root.sh`. Geef `oracle` geen algemene sudo voor shell, filesystemtools, de centrale helpercopy of de gehele wrapper.

Bereid ook de vaste approvalroot eenmalig als root voor; `oracle` hoeft en mag daar niet schrijven:

```bash
install -d -o root -g oinstall -m 0750 \
  /mnt/patch-share/oracle-patch-guard/approvals
```

Bij `stage` valideert `opg_stage_approval.sh` de bestaande vier PLAN-artifacts eerst onprivileged en byte-voor-byte. Daarna streamt het uitsluitend `patch_manifest.json`, `assessment.json`, `findings.psv` en `execution_state.json` naar de lokale helper. De helper accepteert geen bron- of doelpad, weigert symlinks, onbekende of dubbele tar-items en onveilige RUN_ID's, zet directory `root:oinstall 0750` en bestanden `root:oinstall 0440`, en publiceert binnen dezelfde approvalroot atomisch. Een bestaande definitieve RUN_ID-directory wordt nooit overschreven.

Na een succesvolle core-APPLY roept de wrapper dezelfde lokale helper aan voor
completion-publicatie. De oorspronkelijke vier PLAN-artifacts en alle signer-
artifacts worden nooit overschreven. `completion.json` wordt `root:oinstall
0440`, bevat SHA256 van exact `patch_manifest.json` en `approval.json`, en wordt
alleen gepubliceerd wanneer context, lokale state, host, home, cycle,
conditionals en expiryrelatie coherent zijn. Een identieke retry is idempotent;
een afwijkend bestaand artifact wordt fail-closed geweigerd.

Vervolgfases herhalen cycle- en targetdiscovery en eisen een exacte match met deze context. Ze maken geen nieuwe RUN_ID.

Een terminale oude run wordt niet stil hergebruikt. Start een nieuwe wave expliciet met een reden:

```bash
OPG_NEW_RUN_REASON='Nieuwe OCT2026 wave na afgeronde JUL2026 run' \
  /bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh new-run
```

Dit is alleen toegestaan vanuit `12_COMPLETE`, `BLOCKED`, `UNKNOWN` of `MANUAL_INTERVENTION_REQUIRED`. De oude context wordt onder `archive/` bewaard en de reden wordt aan `context_history.log` toegevoegd. Een PARTIAL/in-progress run wordt niet vervangen.

## OEM-tasks

Voor een volledig nieuwe cycle is de praktische startvolgorde:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh prepare
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh stage-media
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh precheck
```

PRECHECK is functioneel een vroege veiligheidscontrole, maar bij
`LOCAL_MEDIA_MODE=required` moeten eerst gevalideerde staged media aanwezig
zijn. PRECHECK vóór `stage-media` mag fail-closed blokkeren met
`MEDIA_STAGE_UNAVAILABLE`.

Een herhaalbare readinesscontrole kan daarna opnieuw los van de formele
lifecycle worden gestart:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh precheck
```

Richt hiervoor in OEM de taak `OPG_PRECHECK` in. PRECHECK gebruikt dezelfde
assessmentregels als PLAN, maar maakt geen `current_run.json`, formeel manifest
of approval-artifacts en kan APPLY niet autoriseren. Een last-minute PRECHECK
vóór APPLY is toegestaan, maar vervangt de verplichte pre-apply-hercontrole in
APPLY niet.

Na de eerste PRECHECK volgt de formele lifecycle. Gebruik op iedere geselecteerde
host exact dezelfde commands:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh create-window
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh assess
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh plan
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh stage
```

Na signing:

```bash
# Optioneel: read-only last-minute readinesscheck
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh precheck

/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh apply
```

Wanneer Oracle-patching al succesvol `12_COMPLETE` bereikte maar de share-
publicatie faalde, blijft de patchstate intact en retourneert de wrapper
`OPG_COMPLETION_PUBLISH|...|status=FAILED` plus exit 30. Herstel uitsluitend de
publicatieoorzaak en herhaal daarna zonder APPLY opnieuw uit te voeren:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh publish-completion
```

Optionele diagnose, niet automatisch onderdeel van APPLY:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh approval-check
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh show-context
```

`plan` bewaart de core-exitcode en gebruikt de bestaande result-summary wanneer die aanwezig is. `apply` leidt manifest en token af als `approvals/<RUN_ID>/patch_manifest.json` en `approval.json`; de bestaande apply/core blijft fail-closed verantwoordelijk voor leesbaarheid, signatures, binding en preapply. Completion-publicatie gebeurt pas na core-exit 0 en veroorzaakt nooit automatische patchrollback.

## Meerdere targets en signing

OEM mag voor een eerste wave rechtstreeks drie geselecteerde hosts gebruiken; een permanente OEM-group is niet vereist. Iedere host maakt zijn eigen RUN_ID en stagingdirectory. PLAN kan operationeel bijvoorbeeld 3–5 hosts parallel draaien; APPLY begint behoudend met 1–2 hosts parallel. De Home-lock blijft per target bepalen dat nooit twee runs dezelfde Oracle Home muteren.

De signing-server blijft gescheiden. Maak na staging een expliciete lijst en geef die aan een eenvoudige operatorloop; dit wijzigt de signer niet:

```bash
for run_id in \
  svhost1-DB1-JUL2026-OEM-20260824T103000Z \
  svhost2-DB2-JUL2026-OEM-20260824T103005Z \
  svhost3-DB3-JUL2026-OEM-20260824T103010Z
do
  /secure/oracle-patch-guard/bin/opg_approve_run.sh "$run_id" || exit $?
done
```

Dit is batching van afzonderlijke manifestgebonden approvals, geen automatische wave-approval.

## Migratie en rollback

1. Plaats en valideer centrale `active_cycle` en `opg_cycle.conf`.
2. Laat `opg_oem.sh` op de centrale share staan, installeer `opg_context_root.sh` lokaal als `/usr/local/sbin/opg_context_root.sh` met `root:root 0755` en activeer uitsluitend de meegeleverde command-specifieke sudoersregel; verander de bestaande task scripts en core niet.
3. Installeer ook `opg_media_stage_root.sh` lokaal als `root:root 0755`, valideer de begrensde sudoersregel en test `prepare`, `stage-media`, `show-context`, `create-window`, `assess`, `plan` en `stage` op één non-productietarget.
4. Vergelijk RUN_ID, argumenten en core-resultaten met de lange commandroute.
5. Activeer daarna dezelfde korte commands voor de geselecteerde wave.

Rollback is alleen orchestrationrollback: laat `opg_oem.sh` buiten gebruik en zet de bestaande lange OEM-commands terug. Verwijder of wijzig geen Patch Guard run-state. Bewaar `current_run.json` als auditbewijs; archiveer hem alleen via `new-run` met reden. De core, approvals en manifests hoeven voor wrapperrollback niet te worden aangepast.
