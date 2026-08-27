# Pilot07 security- en failure-analyse

## Dreigingen en controles

| Dreiging | Fail-closed controle |
|---|---|
| Gewijzigde centrale ZIP | signed manifest + grootte + SHA256 vóór extractie |
| Gewijzigd manifest | detached signature tegen lokaal vertrouwde sleutel |
| Verkeerde cycle/patch/OPatch | exacte cross-check cycle-config ↔ signed manifest |
| ZIP traversal/absolute pad | entryvalidatie vóór extractie; geen entry mag escaping zijn |
| Onverwachte Oracle ZIP-rootentry | RU/OJVM: uitsluitend patch-ID-directory plus optioneel exact regulier `PatchSearch.xml`; OPatch: uitsluitend `OPatch/` |
| Symlink/special in ZIP of stage | extractie en V2-hasher weigeren deze objecten |
| Lokale stage achteraf gewijzigd/vervangen | verse V2/SHA-check tegen signed/run-binding bij plan/apply/resume; iedere inhoudsafwijking blokkeert vóór gebruik |
| Verwisselde stage | run bindt aan canonical pad én artifact-manifest SHA |
| Oracle vervangt root-helper | vast lokaal pad, root:root 0755, veilige parents, sudoers exact begrensd |
| Onderbreking tijdens copy/extract | werk uitsluitend onder unieke incoming; geen actieve publicatie |
| Onderbreking tijdens publish | rename op hetzelfde filesystem; pointer pas na eindvalidatie |
| Onvoldoende ruimte/inodes | preflight op ZIP-groottes met fail-closed veiligheidsmarge |
| Race tijdens broncopy | hash van lokaal gekopieerde bytes moet signed SHA zijn; bronmutatie kan geen gemengde geaccepteerde ZIP opleveren |
| Race tijdens lokale hashing | dubbele inventarisatie en metadata vóór/na iedere file |
| Share onbereikbaar tijdens APPLY | geen effect; APPLY gebruikt en valideert alleen lokale stage |
| Onvolledige cleanup | geen automatische destructieve cleanup; incoming blijft auditbaar of wordt expliciet beheerd |

## Privilege boundary

Alle muterende staginghandelingen lopen via
`/usr/local/sbin/opg_media_stage_root.sh`, lokaal `root:root 0755`, met
root-controlled parents. De launcher valideert en start uitsluitend de lokale
`root:root 0755` engine `/usr/local/libexec/opg_media_stage_root.py`; ook haar
parents zijn root-controlled. Sudo staat alleen de vaste actie `stage-active-cycle`
toe; er worden geen paden of shellcommands aangeleverd. De read-only actie
`verify-active-stage` mag zonder sudo worden uitgevoerd en schrijft niets.

De helper gebruikt geen `eval`, volgt geen symlinks, accepteert alleen beperkte
cycle/patch/filename-syntax en houdt alle afgeleide paden binnen vaste roots.
Een onveilige helper, helper-parent of bestaand stage-object blokkeert de flow.

## Local-stage threat boundary

De strikte root-owned parent-chain-eis geldt voor privileged helpers en
sudo-targets. Voor patchmedia begint de trusted stage boundary expliciet bij
`/u01/stage`: deze anchor is `root:root 0755`; de stage-root eronder is
`root:oinstall 0750`. De beheerstructuur, stage-identiteit, manifesten, evidence
en active pointer blijven root-owned. De daadwerkelijke execution media onder
`ready/<cycle>/<manifest-sha>/{media,opatch}` zijn bewust `oracle:oinstall`:
directories 0750, reguliere files 0640 en ZIP-entries met execute-semantiek
0750. De root-helper is de enige publisher, maar de execution payload is voor
Oracle/OPatch bruikbaar zonder root-ownershipconflict.

Symlinks, hardlinks en speciale files blijven verboden. Voor de root-owned
beheerstructuur blijft een POSIX default/access ACL die `oracle` of een van
diens groepen schrijfrecht geeft fail-closed. Boven de anchor mogen directories
zoals `/u01` een andere owner hebben, mits de keten geen symlink bevat en
nergens group/world-writable is.

Dit is pragmatisch geen garantie van lokale pathname-integriteit tegen een
kwaadwillende target-`oracle`-gebruiker die eigenaar is van `/u01`: die kan de
naam `/u01/stage` proberen te vervangen. Zo'n actor valt expliciet buiten die
pathname-garantie. De security-identiteit van de patchmedia berust daarom op
het signed artifact-manifest en een verse `OPG_TREE_HASH_V2`/SHA256-verificatie
bij PLAN, APPLY en resume. Een gemuteerde of inhoudelijk vervangen stage wordt
vóór gebruik fail-closed geblokkeerd. Een byte-identieke vervanging blijft
acceptabel, omdat zij exact dezelfde ondertekende content-identiteit heeft;
inode-identiteit is geen onderdeel van het artifactcontract.

Omdat `oracle` eigenaar is van de execution media kan die account bestanden
technisch wijzigen. Pilot07 presenteert filesystemmodes daarom niet als
immutabilitygrens: de harde grens blijft de signed artifactidentiteit en verse
inhoudsverificatie vóór ieder patchgebruik. Ownership/modes versoepelen geen
enkele manifest-, ZIP-, V2-, PLAN-, approval- of APPLY-controle.

## Oracle RU/OJVM ZIP-layout

Voor DB-RU en OJVM zijn exact de verwachte patch-ID-directory en optioneel één
rootbestand met de byte-exacte naam `PatchSearch.xml` toegestaan. Dit bestand
moet een regulier ZIP-bestand zijn: directories, symlink/special Unix-types,
duplicate entries, padseparators en alternate spelling worden geweigerd. Het
ZIP-formaat draagt geen hardlinkrelatie over naar de veilige extractor; iedere
payloadfile wordt zelfstandig met `O_EXCL` aangemaakt en `PatchSearch.xml`
wordt niet geëxtraheerd. Daardoor kan deze entry geen lokale hardlink worden.

`PatchSearch.xml` blijft via grootte en SHA256 onderdeel van het volledige
signed ZIP-artifact. Het bestand valt bewust buiten de V2 tree-hash, omdat V2
uitsluitend de uitgepakte patch-ID-directory bindt. Voor OPatch blijft alleen
de top-level directory `OPatch/` toegestaan; iedere rootfile blijft BLOCKED.

## Bewuste recovery-keuze

Pilot07 doet geen automatische rollback of verwijdering. Bij een interruption
vóór publicatie blijft de actieve pointer onveranderd. Bij een interruption na
directory-rename maar vóór pointer-publicatie bestaat een niet-actieve,
inhoudelijk complete kandidaat die een volgende idempotente run opnieuw volledig
moet verifiëren. Afwijkingen vereisen handmatige, geaudite recovery.

## Restrisico's

- De offline signer en private key vallen buiten de target-host trust boundary.
- Eerste staging leest iedere ZIP eenmaal van de share; wave-orkestratie moet dit
  spreiden om gelijktijdige sharebelasting te begrenzen.
- Filesystem/host-root compromise kan lokale media en helper wijzigen en valt
  buiten de bescherming van Patch Guard.
- Een kwaadwillende target-`oracle`-user kan bij een oracle-owned `/u01` lokale
  pathnames vervangen. Patch Guard detecteert inhoudsafwijkingen cryptografisch,
  maar belooft voor deze layout geen permanente pathname/inode-integriteit.
- Omdat execution media oracle-owned zijn, valt een doelbewuste gelijktijdige
  wijziging door dezelfde account ná de laatste herverificatie maar vóór/tijdens
  consumptie onder een resterend TOCTOU-risico. Het vereenvoudigde model
  beschermt tegen vóór gebruik waarneembare inhoudsdrift, niet tegen een reeds
  gecompromitteerde target-oracle account die actief met APPLY racet.
- Diskcapaciteit omvat tijdelijk zowel gekopieerde ZIPs als uitgepakte trees.
