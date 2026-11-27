# Privileged Active Home via BOOTSTRAP

## Centraal hostbeleid

De centrale `${OPG_ROOT}/config/patchGD_guard.conf` houdt de ingebouwde standaard
`local` of zet `ACTIVE_HOME_INSPECTION_MODE=local` expliciet. Een host zonder
fragment behoudt dezelfde lokale configuratie en heeft geen privileged helper,
sudoers-fragment of SELinux-installatietools nodig.

Voor een opt-in installeert de beheerder één bestand op
`${OPG_ROOT}/config/hosts/<host>/active-home.conf`. Gebruik de uitvoer van
`hostname -f` in kleine letters. Als `hostname -f` faalt, geldt de uitvoer van
`hostname` in kleine letters. Gebruik geen aliassen, wildcards of gedeeld
defaultfragment. De directoryketen is root-owned en vrij van symlinks en
group/world-write. Het fragment is een regulier root:root-bestand zonder extra
hardlinks of group/world-write. Gebruik mode `0644` zodat PREPARE het kan lezen.

Het [voorbeeldfragment](../config/examples/active-home.conf) bevat de twee
verplichte sleutels. Vervang het voorbeeldpad door de canonieke Oracle Home op
die host. De parser accepteert ASCII, lege regels, commentaarregels en één
letterlijke waarde per sleutel. Elke andere sleutel, dubbele sleutel,
shelluitdrukking, lege padcomponent of `..` blokkeert BOOTSTRAP en PREPARE.

Het fragment heeft alleen voor `ACTIVE_HOME_INSPECTION_MODE` voorrang op de
centrale basis. BOOTSTRAP leest de Oracle Home uit hetzelfde fragment voor de
beleidsgeneratie. Het valideert de home tegen `ORATAB_FILE` of `/etc/oratab` en
weigert meerdere verschillende databasehomes. De home moet eigendom zijn van
`oracle`. De beleidsgeneratie bevat de numerieke UID, primaire GID en aantoonbare
initiële PID- en usernamespace plus dezelfde mountnamespace als host-PID 1.
Verwijdering van het fragment voor een bestaande privileged installatie blokkeert
synchronisatie. Terugdraaien naar local vereist een afzonderlijke beheerwijziging.

## Publicatie en herstel

| Doel | Owner | Mode |
| --- | --- | --- |
| `/usr/local/sbin/opg_active_home_inspect` | root:root | `0755` |
| `/usr/local/libexec/oracle-patch-guard/opg_active_home.py` | root:root | `0644` |
| `/etc/oracle-patch-guard/active-home-inspect.json` | root:root | `0400` |
| `/etc/sudoers.d/oracle-patch-guard-active-home` | root:root | `0440` |

De reguliere bootstrapaanroep blijft geldig.

```bash
/bin/bash /mnt/datadomain/software/patches/Linux/oracle-patch-guard/current/oem-tasks/opg_bootstrap_host.sh
```

BOOTSTRAP neemt het exclusieve slot op de lokale configuratiedirectory.
PREPARE en patchuitvoering in deze release nemen daarop een gedeeld slot.
Privileged BOOTSTRAP neemt ook het bestaande Oracle Home-slot van `b5ce19d`.
De directory van het hostslot blijft op dezelfde inode staan. De patchuitvoering
weigert te starten wanneer de ingelezen standaardconfiguratie intussen is
vervangen of als het deploymentjournaal aanwezig is.

Voor privileged BOOTSTRAP zijn een reguliere host-rootcontext, `CAP_SYS_PTRACE`
en de bestaande bevoegdheid om `unshare --mount` plus een private bind-mount uit
te voeren nodig. De volledige kandidaat-sudoers inclusief de twee OPG-fragmenten
wordt in de private mountnamespace door `visudo -c` gelezen. Externe sudoersbronnen
en afwijkende policyplugins blokkeren de installatie. Plan sudoers-onderhoud in
een ander tijdvenster. De bestaande sudoers-grant bevat alleen de twee vaste
aanroepen `visibility` en `scan` voor `oracle`. De installatie accepteert sudo
mode `4111` of `4755`.

BOOTSTRAP gebruikt onder SELinux Enforcing `matchpathcon`, `chcon` en `stat`
voor het label van de doelbestanden en verifieert hun labels na publicatie. Het
meldt `visibility=UNVERIFIED`. PREPARE controleert de lokale configuratie, het
root-owned deploymentbewijs `active-home-deployment.json`, de kandidaatbytes en
bestandsmetadata. PREPARE laat vervolgens de bestaande helper onder de werkelijke
Oracle-aanroepcontext de procesdekking bewijzen. `UNKNOWN`, een ontbrekende marker
of een afwijkende home blokkeert. De testsuite voor de stock SELinux-opdrachten is
synthetisch. De functionele SELinux-toegang wordt op OL8 en OL9 afzonderlijk
gekwalificeerd.

De vier handmatig geïnstalleerde bestanden uit `b5ce19d` kunnen worden overgenomen
wanneer de drie statische bestanden exact overeenkomstig zijn en de dynamische
policy bij dezelfde UID, GID en home hoort. Latere kandidaten herkennen een
vertrouwde vorige generatie via het root-owned bewijs. Onbekende drift blokkeert.
Een reboot mag de mountnamespace actualiseren nadat de actuele hostdekking opnieuw
is vastgesteld. Home-, gebruiker- en lockrootmigraties vereisen apart beheer.

Het lokale journaal `.active-home-transaction.json` en de bijbehorende verborgen
hardlinks bewaren de vorige inodes en daarmee modes en labels. Bij een fout zet
BOOTSTRAP de eigen getroffen deploymentbestanden terug terwijl beide sloten zijn
vastgehouden. Na een proces- of stroomonderbreking herstelt een volgende
BOOTSTRAP onder dezelfde hostpolicy eerst dat journaal. Laat het journaal en de
hardlinks staan als herstel door een opslagfout niet kan worden geverifieerd.
Hervat dan pas na herstel en een geslaagde PREPARE. Dit deploymentherstel omvat
geen Oracle-bestanden of patchrunevidence.

## Acceptatie op SV2620535

Voer dit uit nadat de kandidaat afzonderlijk voor operationele acceptatie is
vrijgegeven. Houd geplande jobs en handmatige patchaanroepen voor deze host
tijdens de proef tegen, inclusief aanroepen uit al geopende `b5ce19d`-processen.
Laat database en applicatie online. Gebruik een afzonderlijke acceptatieroot met
een eigen `current` die naar de immutable build van de kandidaat wijst. De
gedeelde release `oracle-patch-guard-rc-b5ce19d` blijft via de centrale `current`
beschikbaar. Voor deze proef bevat de acceptatieroot de vertrouwde centrale
config, publieke verificatiesleutel en herstelprocedure met dezelfde sitewaarden
en dezelfde lokale `LOCK_ROOT`, `RUN_ROOT` en `ORATAB_FILE`. Zet `OPG_ROOT` op
de acceptatieroot en houd de basismodus `local`. Gebruik het hostfragment voor
de opt-in op die host.

Stel `ACCEPT_ROOT` in op het absolute pad van die acceptatieroot en `ORACLE_HOME`
op de vooraf op de host vastgestelde canonieke home van `d000116a`. Gebruik als
geautoriseerde hostbeheerder vóór de eerste BOOTSTRAP deze momentopname.

```bash
set -euo pipefail
: "${ACCEPT_ROOT:?absolute acceptatieroot vereist}"
: "${ORACLE_HOME:?canonieke Oracle Home van d000116a vereist}"
test "$(hostname -s | tr '[:lower:]' '[:upper:]')" = SV2620535
test "$(getenforce)" = Enforcing
test "$(realpath -e -- "$ORACLE_HOME")" = "$ORACLE_HOME"
CENTRAL=/mnt/datadomain/software/patches/Linux/oracle-patch-guard
test "$(basename -- "$(readlink -e -- "$CENTRAL/current")")" = oracle-patch-guard-rc-b5ce19d
test "$(readlink -e -- "$ACCEPT_ROOT/current")" != "$(readlink -e -- "$CENTRAL/current")"
HOST_KEY=$( (hostname -f 2>/dev/null || hostname) | tr '[:upper:]' '[:lower:]')
HOST_DIR="$ACCEPT_ROOT/config/hosts/$HOST_KEY"
install -d -o root -g root -m 0755 -- "$HOST_DIR"
FRAGMENT=$(mktemp "$HOST_DIR/.active-home.XXXXXX")
printf 'ACTIVE_HOME_INSPECTION_MODE=privileged\nACTIVE_HOME_ORACLE_HOME=%s\n' "$ORACLE_HOME" > "$FRAGMENT"
chmod 0644 "$FRAGMENT"
mv -fT -- "$FRAGMENT" "$HOST_DIR/active-home.conf"
grep -Fx 'ACTIVE_HOME_INSPECTION_MODE=privileged' "$ACCEPT_ROOT/config/hosts/$HOST_KEY/active-home.conf"
grep -Fx "ACTIVE_HOME_ORACLE_HOME=$ORACLE_HOME" "$ACCEPT_ROOT/config/hosts/$HOST_KEY/active-home.conf"

BACKUP=$(mktemp -d /var/tmp/opg-active-home-accept.XXXXXX)
printf 'Deploymentmomentopname %s\n' "$BACKUP"
for path in /etc/oracle-patch-guard/{patchGD_guard.conf,active-home-inspect.json,active-home-deployment.json,approval_public.pem,oracle_home_rebuild.md} \
  /etc/sudoers.d/oracle-patch-guard-{context,active-home} \
  /usr/local/sbin/{opg_active_home_inspect,opg_context_root.sh,opg_media_stage_root.sh} \
  /usr/local/libexec/{oracle-patch-guard/opg_active_home.py,opg_media_stage_root.py}; do
    printf '%s\n' "$path" >> "$BACKUP/targets"
    if [[ -e "$path" ]]; then cp -a --parents -- "$path" "$BACKUP"; fi
done
/usr/sbin/visudo -c
```

Voer de kandidaat tweemaal als hostbeheerder uit. Voer PREPARE en beide
inspectieaanroepen als `oracle` uit.

```bash
export OPG_BOOTSTRAP_BASE="$ACCEPT_ROOT/current"
/bin/bash "$OPG_BOOTSTRAP_BASE/oem-tasks/opg_bootstrap_host.sh"
/bin/bash "$OPG_BOOTSTRAP_BASE/oem-tasks/opg_bootstrap_host.sh"
/usr/sbin/visudo -c
matchpathcon -V /usr/local/sbin/opg_active_home_inspect \
  /usr/local/libexec/oracle-patch-guard/opg_active_home.py \
  /etc/oracle-patch-guard/active-home-inspect.json \
  /etc/sudoers.d/oracle-patch-guard-active-home
runuser -u oracle -- /bin/bash "$OPG_BOOTSTRAP_BASE/oem-tasks/opg_prepare_host.sh"
runuser -u oracle -- /usr/bin/sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect visibility
rc=0
runuser -u oracle -- /usr/bin/sudo -n -u root -- /usr/local/sbin/opg_active_home_inspect scan \
  > "$BACKUP/scan.log" || rc=$?
test "$rc" -eq 20
grep '^ACTIVE_HOME_FILE|' "$BACKUP/scan.log"
grep -Fx "OPG_ACTIVE_HOME_INSPECTION|version=1|mode=scan|home=$ORACLE_HOME|exit_code=20" "$BACKUP/scan.log"
if grep -q '^PROC_COVERAGE_UNKNOWN|' "$BACKUP/scan.log"; then exit 1; fi
test "$(getenforce)" = Enforcing
test "$(basename -- "$(readlink -e -- "$CENTRAL/current")")" = oracle-patch-guard-rc-b5ce19d
```

Beide bootstraps en PREPARE moeten `READY` geven. `visibility` moet code `0`,
`PROC_COVERAGE_CONFIRMED` en de bedoelde home melden. Vergelijk database- en
applicatiebeschikbaarheid en bestaande run-evidence met de controles van vóór de
proef. Herhaal op OL8 en vanuit de echte OEM-agentcontext vóór vrijgave. Test de
feitelijke OEM Retry-knop afzonderlijk in ACC.

## Handmatig terug naar de vooraf vastgelegde deployment

Bij een afgekeurde eerste acceptatie vanaf `b5ce19d` blijven jobs stil.
Gebruik de momentopname van diezelfde host uit `b5ce19d`. Bij een bestaand transactiejournaal
voer je eerst de kandidaat-BOOTSTRAP opnieuw uit voor herstel onder de sloten.
Laat het journaal staan als deze stap blijft falen. Draai een geslaagde
deployment alleen terug onder de configuratiedirectorylock en het Oracle Home-slot.

```bash
set -euo pipefail
: "${BACKUP:?gebruik de originele momentopname}"
: "${ORACLE_HOME:?gebruik dezelfde canonieke Oracle Home}"
CENTRAL=/mnt/datadomain/software/patches/Linux/oracle-patch-guard
test ! -e "$BACKUP/etc/oracle-patch-guard/active-home-deployment.json"
test ! -e /etc/oracle-patch-guard/.active-home-transaction.json
LOCK_ROOT=$(sed -n 's/^LOCK_ROOT=//p' /etc/oracle-patch-guard/patchGD_guard.conf)
test -d "$LOCK_ROOT"
HOST_NAME=$(hostname -f 2>/dev/null || hostname)
LOCK_ID=$(printf '%s' "$HOST_NAME|$ORACLE_HOME" | sha256sum | cut -d ' ' -f 1)
exec {bootstrap_fd}</etc/oracle-patch-guard
flock -n "$bootstrap_fd"
exec {patch_fd}<"$LOCK_ROOT/$LOCK_ID.lock"
flock -n "$patch_fd"

restore_one() {
    local path=$1 temp
    if [[ -e "$BACKUP$path" ]]; then
        temp=$(mktemp "${path%/*}/.opg-restore.XXXXXX")
        cp --preserve=all -- "$BACKUP$path" "$temp"
        mv -fT -- "$temp" "$path"
    else
        rm -f -- "$path"
    fi
}
policy=/etc/oracle-patch-guard/active-home-inspect.json
rm -f -- "$policy"
while IFS= read -r path; do
    if [[ "$path" != "$policy" ]]; then restore_one "$path"; fi
done < "$BACKUP/targets"
restore_one "$policy"
/usr/sbin/visudo -c
test "$(getenforce)" = Enforcing
exec {patch_fd}<&-
exec {bootstrap_fd}<&-
runuser -u oracle -- /bin/bash "$CENTRAL/current/oem-tasks/opg_prepare_host.sh"
```

Controleer extra dat de oude privileged `visibility` weer code `0` oplevert als
die modus vóór de proef actief was. Hervat jobs pas nadat de baseline en de
beschikbaarheid opnieuw zijn bevestigd.
Een latere terugkeer tussen twee beheerde releases gebeurt via BOOTSTRAP vanuit
de eerder vertrouwde immutable release, met dezelfde hostbinding. Het huidige
deploymentbewijs blijft daarbij de bron voor de controle van de aanwezige versie.

## Ontwikkelregressies

```bash
python3 -B project/tests/run_active_home_bootstrap_tests.py
python3 -B project/tests/run_active_home_tests.py
python3 -B project/tests/run_privileged_active_home_tests.py
bash project/tests/run_tests.sh
```

De bestaande rootgebonden bootstrapregressies blijven onder
`project/tests/run_bootstrap_tests.sh`. De gerichte regressies hierboven werken
met geïsoleerde testbestanden onder een gewone Linux-gebruiker.
