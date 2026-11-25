# OEM 24ai deploymentprocedure

> **Historische low-level procedure.** De actuele OEM-flow gebruikt de
> immutable release onder `${OPG_ROOT}/current`, met wrapper en helpers uit
> `current/oem-tasks` en core uit `current/project`. Gebruik voor nieuwe
> deployments [OEM_WRAPPER_GUIDE.md](../OEM_WRAPPER_GUIDE.md) en
> [RELEASE_LAYOUT.md](../docs/RELEASE_LAYOUT.md). De `/opt`-commando's hieronder
> beschrijven de oudere rechtstreekse core-integratie.

## 1. Targetvoorbereiding

Plaats root-owned, niet door het OEM-agentaccount wijzigbare kopieën onder bijvoorbeeld `/opt/oracle-patch-guard/`:

```text
patchGD_guard.sh
patchGD_guard.conf
lib/opg_core.sh
lib/opg_active_home.py
oem_assess.sh
oem_apply.sh
oem_status.sh
```

`oem_collect_results.sh` kan op de centrale rapportagehost staan. Maak `/var/log/oracle-patch-guard` en `/var/lock/oracle-patch-guard` aan met een lokaal beoordeelde eigenaar/groep. Installeer de approval public key read-only. Controleer dat `/bin/bash`, `flock`, `sha256sum`, `openssl`, `timeout`, Oracle-clients en de organisatiespecifieke checkexecutables aanwezig zijn.

Na overdracht vanuit de Windows-zip moeten Linux-owner en modes expliciet worden gezet en gecontroleerd: directories maximaal `0750`, scripts maximaal `0750`, configuratie en publieke sleutel maximaal `0640`, waarbij de configuratie root-owned blijft. Neem geen executable bit uit het zipbestand als bewijs over.

Vul het root-owned, niet group/world-writable `/etc/oracle-patch-guard/patchGD_guard.conf` met exacte patch-, inventory-, log-, lock-, listener- en agentpaden. De back-up-, Oracle Home-recovery-, Data Pump-, Data Guard- en onderhoudsvensterhooks moeten argumentloze, read-only executables zijn met 0 voor aantoonbaar veilig, 2 voor onveilig en 3 voor onbekend. Niet configureren levert nooit fictief succes op.

## 2. Uitvoerende gebruiker en minimale sudo

Voor APPLY moeten `lsof`, `timeout` en Python 3 beschikbaar zijn. De verplichte
procesinspectie draait standaard als de Oracle Home-owner. Vóór shutdown controleert
PREAPPLY de procfs-toegang. Vóór de RU en opnieuw vóór OJVM controleert OPG de
actieve executables en mappings. Een aangetoonde treffer geeft `BLOCKED`
(detector-exitcode 20). Zonder treffer geeft ontbrekend proceszicht
`UNKNOWN` (30), voor iedere UID. Een verdwenen PID telt alleen als afgehandeld
als procfs zijn afwezigheid bevestigt. Voor een nog aanwezige PID zonder
leesbare executable vereist de detector leesbare, lege maps en één thread.
De scan is een momentopname binnen de zichtbare PID- en mountnamespace.
Houd clients stil tijdens het onderhoud en kwalificeer de scan in de
hostnamespace.

Op OL9 kan `(sd-pam)` dezelfde UID hebben als `oracle` en toch onleesbare
`maps` hebben. De upstream PAM-child wisselt van effectieve UID en GID.
Linux reset daarbij de dumpable-status en baseert procfs-toegang onder meer
op die status, capabilities en SELinux-beleid. Dit verklaart waarom een
gelijke UID op zichzelf geen toegang bewijst.
[systemd 252-broncode](https://raw.githubusercontent.com/systemd/systemd/v252/src/core/execute.c)
[Linux dumpable-status](https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html)
[Linux ptrace-toegangsregels](https://man7.org/linux/man-pages/man2/ptrace.2.html)

### Read-only helper bij beperkt proceszicht

Laat de DBA op een representatieve OL9.9-acceptatiehost de read-only detector
uitvoeren als de Oracle Home-owner, met de OEM-omgeving en dezelfde procfs-mount.
Gebruik een vertrouwde kopie van `lib/opg_active_home.py` met
`/usr/bin/python3 -I`. Test eerst `--visibility` en daarna het scanargument
met een canonieke fixturehome. Houd een bestand in die fixturehome gemapt
onder een andere UID en maak de mapping daarna vrij. Verwacht 20 voor de
zichtbare mapping en 0 na vrijgave bij volledige dekking. Verwacht 30 als
een proces onleesbaar blijft en er geen aangetoonde treffer is. De detector
heeft hiervoor geen database-, listener- of OPatch-opdrachten nodig.

Wanneer de Oracle-owner onvoldoende proceszicht heeft, kwalificeer dan
de opt-in modus `ACTIVE_HOME_INSPECTION_MODE=privileged`. Deze gebruikt
dezelfde scanner in PREAPPLY en vóór RU en OJVM, ook bij Retry en Resume.
PRECHECK blijft advisory. In privileged modus geven een ontbrekende of
onvertrouwde helper, timeout en ongeldige of afwijkend gebonden uitvoer
`UNKNOWN`. Een enkele configuratie bindt één caller aan één Oracle Home.

Installeer bij een afzonderlijk goedgekeurde hostwijziging deze bestanden uit
dezelfde beoordeelde commit. Installeer beide Python-bestanden als
`root:root` op vaste lokale paden. Zorg voor root-owned parentdirectories
zonder symlinks of schrijfbevoegdheid voor groep of anderen.

| Bron | Doel | Mode |
| --- | --- | --- |
| `oem-tasks/opg_active_home_inspect.py` | `/usr/local/sbin/opg_active_home_inspect` | `0755` |
| `project/lib/opg_active_home.py` | `/usr/local/libexec/oracle-patch-guard/opg_active_home.py` | `0644` |
| Hostgebonden JSON | `/etc/oracle-patch-guard/active-home-inspect.json` | `0400` |
| `config/examples/oracle-patch-guard-active-home.sudoers` | `/etc/sudoers.d/oracle-patch-guard-active-home` | `0440` |

Maak de JSON als root vanuit de werkelijke hostnamespaces. Gebruik de
numerieke UID/GID van de bestaande Oracle-eigenaar en het canonieke homepad.
Lees de drie namespace-identiteiten op de host met
`readlink /proc/1/ns/pid /proc/1/ns/mnt /proc/1/ns/user`. Onderstaand voorbeeld
toont het formaat. Herbevestig de binding na reboot of een namespace-wijziging.
Een afwijkende namespace, ook in een geïsoleerde agentservice, levert
`UNKNOWN` op.

```json
{
  "uid": 54321,
  "gid": 54321,
  "oracle_home": "/u01/app/oracle/product/19.0.0/dbhome_1",
  "namespaces": {
    "pid": "pid:[4026531836]",
    "mnt": "mnt:[4026531841]",
    "user": "user:[4026531837]"
  }
}
```

Valideer de afzonderlijke sudoersregel met `visudo -cf`. Pas alleen de
gebruikersnaam aan als de site een andere Oracle-owner heeft. Het privilege
geldt uitsluitend voor de twee exacte acties `visibility` en `scan`.
De guard verwacht `/usr/bin/sudo` als `root:root` met mode `4755`.
De helper valideert `SUDO_UID`, `SUDO_GID` en de hostnamespaces. Vóór het
lezen van doelprocessen draait hij als de geconfigureerde Oracle-owner,
zonder aanvullende groepen en met alleen `CAP_SYS_PTRACE` effective en
permitted. De inheritable, ambient en bounding sets zijn leeg en
`no_new_privs` staat aan. De scanner leest alleen procfs, gebruikt geen
`ptrace()`-attach en start geen subprocessen.
Het canonieke Oracle Home-pad moet met alleen de primaire GID toegankelijk
zijn.
[Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)

**SELinux op OL9.9.** Kwalificeer de twee sudo-aanroepen vanuit de werkelijke
OEM-context met SELinux in enforcing-modus. Vereist zijn toegang tot de
root-owned code/configuratie, de privilegeverlaging (`setuid`, `setgid`,
`setpcap` en `process:setcap`), `sys_ptrace` voor de helper en read-only
toegang tot de relevante procfs-objecten. Bij de SELinux-hook voor
`PTRACE_MODE_READ` gaat het om `file:read` op de doelcontext. Een
`process:ptrace`-toestemming voor attach is hiervoor niet nodig. Onderzoek
weigeringen met `ausearch -m AVC,USER_AVC -ts recent -i`. Laat eventuele
labeling en toegangsregels beperken tot een apart helperdomein en de
geobserveerde leesoperaties. De benodigde doeltypes zijn hostspecifiek.
Borg dat de agent- en Oracle-shellcontext deze rechten niet overerven.
[SELinux-kernelhook](https://github.com/torvalds/linux/blob/v5.14/security/selinux/hooks.c#L2022-L2055)
[SELinux-diagnostiek](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/troubleshooting-problems-related-to-selinux_using-selinux)

Test in een acceptatieomgeving `sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect visibility`
en dezelfde aanroep met `scan`. Controleer exit 20 met een mapping door een
non-dumpable fixtureproces, 0 na vrijgave bij volledige dekking en 30 bij
ontbrekende dekking. Test verkeerde caller, extra argumenten, timeouts en
home-binding. Zet de hostconfig pas op `privileged` na kwalificatie van die
preflight- en scanuitslagen. De scan gebruikt de canonieke doelhome als
padgrens. Kwalificeer de home zonder bindmount- of hardlinkaliassen en houd
clients stil tijdens de onderhoudsoperatie.

Laat OEM standaard als agentaccount uitvoeren. Gebruik alleen vooraf geconfigureerde `sudo -n -u oracle` voor de root-owned OEM-wrapper die nodig is. Een conceptueel, commandospecifiek sudoerspatroon is:

```text
Cmnd_Alias OPG_ASSESS = /opt/oracle-patch-guard/oem_assess.sh *
Cmnd_Alias OPG_APPLY  = /opt/oracle-patch-guard/oem_apply.sh *
Cmnd_Alias OPG_STATUS = /opt/oracle-patch-guard/oem_status.sh *
oemagent ALL=(oracle) NOPASSWD: OPG_ASSESS, OPG_APPLY, OPG_STATUS
```

Dit is nadrukkelijk geen kant-en-klaar sudoersfragment: wildcardargumenten vergroten de bevoegdheid. Laat security lokaal beoordelen of vaste launchers per actie, sudoers-digests, SELinux, een root-owned parameterdrop en padrestricties nodig zijn. Geef nooit `NOPASSWD: ALL`, een algemene `/bin/bash`, package-manager-, delete- of rebootbevoegdheid. Als Oracle-binaries en locks zonder sudo veilig als oracle kunnen worden beheerd, laat sudo geheel weg.

Test ieder toegestaan pad met `sudo -n`; een passwordprompt moet als configuratiefout falen.

## 3. OEM-parameters

Maak minimaal deze job/targetparameters aan en markeer gevoelige locaties niet als vrij invoerveld:

- `TARGET_ORACLE_HOME`
- `RUN_ID` (bijvoorbeeld OEM job-ID plus change-ID)
- `DB_PATCH`, `OJVM_PATCH`, `MONTH`, `OPATCH_VERSION`, `OPATCH_ZIPFILE`
- `OPG_CONFIG`
- `APPROVED_MANIFEST`
- `APPROVAL_TOKEN`
- `WAVE`
- `MAX_PARALLEL_TARGETS=2`
- `FAILURE_THRESHOLD=1`
- `STOP_NEXT_WAVE_ON_FAILURE=true`
- `ASSESSMENT_MAX_AGE_MINUTES=60`

Vertrouw niet op `ORACLE_HOME`, `ORACLE_SID` of `PATH` uit een agentprofile. De wrappers roepen expliciet `/bin/bash` aan en de guard beheert de Oracle-omgeving per SID.

## 4. Gescheiden assessment en apply

Stage eerst patchsoftware en README’s read-only. Start daarna per target:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_assess.sh \
  "$TARGET_ORACLE_HOME" "$RUN_ID" "$DB_PATCH" "$OJVM_PATCH" "$MONTH" \
  "$OPATCH_VERSION" "$OPATCH_ZIPFILE" "$OPG_CONFIG"
```

Verzamel `assessment.json`, `findings.json`, `patch_manifest.json`, hashes, conflictlogs en rollbackplan. Selecteer alleen `READY` en afzonderlijk beoordeelde `CONDITIONAL` targets. `BLOCKED` en `UNKNOWN` gaan niet naar apply.

Onderteken centraal het exacte manifest, bijvoorbeeld volgens het lokaal goedgekeurde PKI-proces, en maak `approval.json` met dezelfde host/home/hash, korte vervaltijd en afzonderlijke conditional-acceptaties. Distributeer manifest, signature en token via een integriteitsbeschermd pad.

Start apply pas na handmatige vergelijking in een afzonderlijke OEM-job. Apply verkrijgt de home-lock en schrijft `preapply_assessment.json` voordat ook maar één database of listener wordt gestopt:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_apply.sh \
  "$RUN_ID" "$APPROVED_MANIFEST" "$APPROVAL_TOKEN" "$OPG_CONFIG"
```

## 5. Waves en paralleliteit

Gebruik:

```text
WAVE_0  assessment op alle targets
WAVE_1  pilot/niet-productie
WAVE_2  eerste productiebatch
WAVE_3  volgende productiebatch
```

Begin met `MAX_PARALLEL_TARGETS=2`. OEM mag verschillende hosts parallel starten; de lokale home-lock beschermt dezelfde home. Na iedere wave telt OEM exitcodes 20, 30, 40, 50, 60 en 70 als niet-succes. Bij `FAILURE_THRESHOLD=1` en `STOP_NEXT_WAVE_ON_FAILURE=true` wordt de volgende wave niet vrijgegeven. Exitcode 10 vereist bewijs dat alle conditionals centraal zijn geaccepteerd.

## 6. OEM-resultaatregels

Parse uitsluitend de laatste `OPG_RESULT|...`-regel en vergelijk `exit_code` ook met de proces-exitcode. Bewaar de volledige run-directory als jobartifact. Een ontbrekende resultaatregel is `PATCH_STATE_UNKNOWN`, nooit succes.

Na een OEM-time-out mag OEM apply niet opnieuw starten. Controleer:

```bash
sudo -n -u oracle /opt/oracle-patch-guard/oem_status.sh "$RUN_ID" "$OPG_CONFIG"
```

De uitvoer onderscheidt `OEM_JOB_TIMED_OUT`, `PATCH_PROCESS_RUNNING`, `PATCH_PROCESS_STOPPED` en `PATCH_STATE_UNKNOWN`. Alleen een bevoegde DBA mag na inhoudelijke state- en inventorycontrole `resume` starten; een nieuwe run-ID is geen herstelmethode.

## 7. Centrale rapportage

Kopieer na iedere wave de volledige run-directories zonder ze op targets te verwijderen. Voer centraal uit:

```bash
/opt/oracle-patch-guard/oem_collect_results.sh /secure/reports/DEMO123 \
  /secure/collected/server01/RUN1 /secure/collected/server02/RUN2
```

Het CSV/Markdown-rapport bevat host, home, databases, nieuwe RU, assessment-/executionstatus, mislukte fase, datapatchlogstatus per SID, tijden en handmatige-actie-indicatie. Vul oude RU en werkelijke downtime in de centrale OEM-laag aan op basis van de bewaarde before-inventory en state timestamps; deze MVP berekent die twee velden nog niet betrouwbaar.

## 8. Go-livecriteria

Productie is pas toegestaan na een representatieve niet-productietest met echte Oracle-output, meerdere databases in één home, gecontroleerde binary/datapatchfout, veilige resume, OEM-time-out, listener/PDB/serviceherstel en herstel van de bestaande Oracle Home. Voer daarna eerst een pilotwave met maximaal twee targets uit.
