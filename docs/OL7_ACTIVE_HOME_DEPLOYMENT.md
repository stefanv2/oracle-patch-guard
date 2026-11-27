# Oracle Linux 7.9 en privileged Active Home

## Platform en voorwaarden

OPG accepteert Oracle Linux 7.9 op `x86_64` met de UEK6-reeks `5.4.17` vanaf
`5.4.17-2011.4.4.el7uek.x86_64`. De platformcontrole geldt bij PRECHECK, ASSESS,
PREAPPLY, OEM Retry en uitvoerende RESUME-routes. Oracle Linux 8 en 9 blijven
ondersteund. Oudere OL7-releases, RHCK en andere kernelreeksen vallen buiten de
OL7-scope van OPG. Oracle documenteert OL7 met UEK6 voor Database 19c vanaf RU
19.9. Controleer vóór APPLY in My Oracle Support en de meegeleverde README's de
voorwaarden voor de exacte DB-RU, OJVM-RU, OPatch en de hostpakketten.
[Oracle Database 19c-certificatie](https://docs.oracle.com/en/database/oracle/oracle-database/19/rnrdm/linux-certification-info.html)
[Oracle Linux 7-pakketvereisten](https://docs.oracle.com/en/database/oracle/oracle-database/19/lacli/operating-system-requirements-for-x86-64-linux-platforms/supported-oracle-linux-7-distributions-for-x86-64.html)

- Controleer `cat /etc/os-release`, `uname -rm`, `bash --version` en
  `/usr/bin/python3 -I --version`. Vereist is Python 3.6.8 of nieuwer op het
  vaste pad. OL7 levert Bash 4.2 en coreutils 8.22. Oudere Oracle-pakketten
  negeren het padargument van `sync`, terwijl `8.22-24.0.1.el7_9.2` ondersteuning
  daarvoor bevat. OPG gebruikt padgerichte `sync` waar die beschikbaar is en
  anders Python `fsync`. Een mislukte flush wordt nooit met een andere methode
  herhaald. PRECHECK geeft `UNKNOWN` als een anders geslaagd resultaat niet
  betrouwbaar naar het evidencebestand kon worden geschreven.
  [Oracle OL7-pakketindex](https://yum.oracle.com/repo/OracleLinux/OL7/latest/x86_64/index.html)
  [GNU Coreutils 8.24](https://raw.githubusercontent.com/coreutils/coreutils/v8.24/NEWS)
- Controleer `flock`, `timeout`, `lsof`, `pgrep`, `readlink`, `realpath`,
  `sha256sum`, `stat`, `unzip`, `zipinfo`, Perl `File::Copy` en OpenSSL in de
  OEM-runtimeomgeving. De media- en approvalketen blijft RSA/SHA-256 met
  `openssl dgst` gebruiken. Valideer daadwerkelijke ondertekening en verificatie
  met de door de site uitgegeven sleutel en goedgekeurde media binnen de
  bestaande staging- en approvalprocedure.
- Controleer de `procfs`-mount, PID-/mount-/usernamespace en SELinux als onderdeel
  van de hostkwalificatie. De privileged scanner vereist aantoonbaar proceszicht
  en `CAP_SYS_PTRACE`. Die capability blijft beperkt tot het inspectieproces.
  De helper stopt veilig als de capability, privilegeverlaging, UID/GID-binding
  of namespacecontrole niet kan worden bewezen.
  [Privileged inspectie en SELinux](../project/OEM_DEPLOYMENT_PROCEDURE.md#read-only-helper-bij-beperkt-proceszicht)

## Installatie door de beheerder

Voer bootstrap uit volgens het bestaande hostcontract. Privileged Active Home
is een afzonderlijk opt-in onderdeel. De installer leest de gecontroleerde
releasebronnen en maakt uitsluitend lokale bestanden voor één Oracle Home en
één runtimeaccount. Behandel de installer als root-code. Verifieer vóór
uitvoering de releasehashes en gebruik het fysieke pad naar de beoordeelde,
root-owned releasekopie. Gebruik een hostbeheersessie in de hostnamespaces en
een onderhoudsmoment zonder lopende OPG-jobs. Houd SELinux enforcing.

Vervang de drie waarden hieronder door de fysieke releasekopie, de werkelijke
Oracle Home-owner en het canonieke Oracle Home-pad. De GID komt uit het
accountregister. De installateur en de launcher vereisen de initiële Linux
PID- en user-namespace en dezelfde mountnamespace als host-PID 1. Een
onbewezen procfs-weergave geeft `UNKNOWN`.

```bash
release=/pad/naar/de/beoordeelde/release
oracle_user=oracle
oracle_home=/u01/app/oracle/product/19.0.0/dbhome_1

id "$oracle_user"
stat -c '%U:%G:%a %n' /usr/bin/sudo "$oracle_home"
/usr/sbin/visudo -c
/usr/bin/python3 -IBS "$release/oem-tasks/opg_install_active_home.py" \
  --oracle-user "$oracle_user" --oracle-home "$oracle_home"
/usr/sbin/visudo -c
```

De vier bestanden zijn `root:root`.

| Doel | Mode |
| --- | --- |
| `/usr/local/sbin/opg_active_home_inspect` | `0755` |
| `/usr/local/libexec/oracle-patch-guard/opg_active_home-<sha256>.py` | `0644` |
| `/etc/oracle-patch-guard/active-home-inspect.json` | `0400` |
| `/etc/sudoers.d/oracle-patch-guard-active-home` | `0440` |

De installer weigert onveilige eigenaren, modes, symlinks en beschrijfbare
oudermappen. Voor `/usr/bin/sudo` accepteert hij root-owned modes `4111` en
`4755`. Hij valideert met `visudo -c` de volledige kandidaatpolicy in een
private mountnamespace. Dat vereist `CAP_SYS_ADMIN`, `unshare` en `mount` in de
beheersessie. De installer ondersteunt de standaard lokale sudoers-plugin
met uitsluitend lokale sudoers-bronnen. Laat andere sudoers-wijzigingen
tijdens deze installatie achterwege.

De scanner krijgt een pad op basis van zijn SHA-256. De launcher en policy
vormen één verifieerbare generatie. Bij een onderbroken overgang kan inspectie
tijdelijk `UNKNOWN` geven. De oudere scanner blijft beschikbaar voor lopende
aanroepen die hem al gebruiken. De installer valideert de volledige policy
opnieuw vóór de laatste publicatiestap. Bij een mislukte flush na publicatie
probeert hij uitsluitend het vorige sudoers-fragment te herstellen. Als ook
die herstelactie faalt, volgt `UNKNOWN` met de beschikbare herstelkopie of een
melding dat de beheerder het actieve fragment moet inspecteren.

Een identieke herhaling meldt vier keer `UNCHANGED`, behoudt de inodes en
flusht de relevante directories opnieuw. `FILES_VERIFIED` bevestigt de
installatie. De runtimekwalificatie volgt afzonderlijk.

## Verificatie vóór inschakelen

1. Controleer met `stat` en `namei -l` alle vier doelen en hun oudermappen.
   Controleer de scannerhash tegen de releasebron en de waarde in de policy.
   De installer vult een release-identificatie in de launcher in. Controleer
   met `ls -Z` de door de site toegekende SELinux-context. Op hosts waar SELinux
   actief is, vereist de installer enforcing en past hij het doelcontextlabel
   vóór publicatie toe. Site-labelregels moeten ook het pad met de scannerhash
   dekken. Corrigeer afwijkende bestaande labels volgens de sitepolicy en
   herhaal de installer ter controle van `UNCHANGED`.
2. Controleer met `/usr/bin/sudo -l -U "$oracle_user"` of het actieve sudoers-beleid
   de exacte acties `visibility` en `scan` als root bevat. Controleer in de
   echte OEM-context als de Oracle Home-owner, met diens reguliere primaire GID:

   ```bash
   /usr/bin/sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect visibility
   /usr/bin/sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect scan
   ```

   `visibility` vereist exit 0 en `PROC_COVERAGE_CONFIRMED`. De `scan` vereist
   exit 0 met `ACTIVE_HOME_SCAN_CLEAR` voor een vrijgegeven geïsoleerde home, of
   exit 20 met een bewezen bestandstreffer wanneer een fixtureproces een
   bestand daar gebruikt. In beide gevallen moeten `version=1`, de actie, de
   home en de exitcode in `OPG_ACTIVE_HOME_INSPECTION` overeenkomen. Ontbrekend
   proceszicht, verkeerde binding, sudo-weigering of timeout blijft blokkerend
   voor APPLY. Een scan van een actieve productiehome kan al door de aanwezige
   database- of listenerprocessen een bestandstreffer geven.
3. Kwalificeer een bestandstreffer en de vrijgave met een afzonderlijke,
   geïsoleerde fixturehome. Herstel daarna de bedoelde beleidsbinding met
   dezelfde installer en verifieer `visibility` opnieuw. Zet pas dan via de
   beheerde hostconfig `ACTIVE_HOME_INSPECTION_MODE=privileged`. Herkwalificeer
   de binding als namespace-identiteiten wijzigen, bijvoorbeeld na een reboot.
4. Voer de normale OEM PRECHECK uit. Controleer het platformbewijs in
   `host_info.txt` en het resultaat van `OJVM_PERL_FILE_COPY`. Bevestig vóór een
   later APPLY bovendien geldige approvals en het onderhoudsvenster, en laat
   de verplichte PREAPPLY-inspectie vanuit OEM het actuele proceszicht bewijzen.
