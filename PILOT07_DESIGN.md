# Pilot07: lokale immutable patchmedia

> **PARTIALLY STALE — historisch Pilot07-ontwerp.** Dit document is de
> ontwerpvoorganger van stable-20260831 en geen volledig huidig runbook. Zie
> [README.md](README.md) en
> [RELEASE_NOTES_20260831.md](RELEASE_NOTES_20260831.md) voor de actuele
> baseline.

## Besluit

Pilot07 gebruikt de centrale share uitsluitend als transportbron voor drie
originele, ondertekend gemanifesteerde ZIP-artifacts. Een root-helper kopieert
en valideert deze eenmaal, extraheert ze veilig naar een lokale incoming-boom,
berekent V2 tree hashes en publiceert daarna atomisch een immutable stage.
`PLAN`, `APPLY` en `resume` gebruiken uitsluitend die gepubliceerde lokale stage.
Er bestaat geen fallback naar uitgepakte media op de share.

Dit adresseert de gemeten bottleneck: dezelfde DB-RU-boom van circa 5.5 GB kost
op de centrale share 553-969 seconden per hash, tegenover 28-32 seconden op
lokale XFS. De winst komt primair uit het elimineren van herhaalde NFS metadata-
en read-I/O, niet uit zwakkere hashing of parallelisatie.

## Filesystemmodel

```text
/u01/stage/oracle-patch-guard/
  incoming/<cycle>.<random>/
  ready/<cycle>/<artifact-manifest-sha256>/
    artifact_manifest.json
    artifact_manifest.sig
    media/<cycle>/<db-patch-id>/...
    media/<cycle>/<ojvm-patch-id>/...
    opatch/<opatch-zip>
    stage_manifest.psv
    evidence/
  ready/<cycle>/active_stage
```

`active_stage` bevat exact de 64-hex SHA256 van het ondertekende artifact-
manifest. De beheerstructuur, metadata en pointer zijn `root:oinstall`, met
directories 0750 en bestanden 0440. De execution trees `media/` en `opatch/`
zijn `oracle:oinstall`: directories 0750, reguliere bestanden 0640 en bestanden
waarvan de gevalideerde ZIP-entry execute-semantiek bevat 0750. Bestaande
gepubliceerde stages worden niet overschreven. Andere cycli en identiteiten
kunnen naast elkaar bestaan.

`/u01/stage` is de expliciete trusted stage anchor (`root:root 0755`). De OPG
stage trust policy begint bij deze anchor; `/u01` en hogere directories vallen
erbuiten en krijgen van OPG geen aanvullende owner-, mode-, write-bit- of
symlinkvoorwaarde. De stage-securityclaim is inhoudsgericht: verse
signed-manifest/V2/SHA256-verificatie blokkeert een inhoudelijk gemuteerde of
vervangen stage vóór ieder gebruik. Zie
`PILOT07_SECURITY_ANALYSIS.md` voor de bewuste pathname-beperking.

De term immutable duidt hier op de cryptografisch gebonden artifactidentiteit,
niet op root-ownership van execution files. De oracle-account kan haar lokale
execution tree technisch schrijven; iedere inhoudsafwijking moet bij de verse
PLAN/APPLY/resume-verificatie fail-closed worden gedetecteerd.

## Vertrouwensketen

1. De lokaal geïnstalleerde helper en parents zijn root-owned en niet
   schrijfbaar door oracle/oinstall.
2. De helper leest de actieve cyclus en `opg_cycle.conf` van de centrale share,
   maar vertrouwt artifact-identiteit alleen na detached-signature-validatie
   van `artifact_manifest.json` met de lokale trusted public key.
3. Cycle-config en signed manifest moeten exact overeenkomen voor cycle, patch
   IDs, ZIP-namen, checksums en OPatch-versie.
4. Van iedere ZIP worden grootte en SHA256 vóór extractie gecontroleerd.
5. ZIP entries met absolute paden, traversal, symlinks of speciale types worden
   geweigerd. RU/OJVM staan uitsluitend de verwachte top-level patch-ID en
   optioneel exact het reguliere rootbestand `PatchSearch.xml` toe. Dit bestand
   blijft ZIP-SHA256-gebonden maar wordt niet geëxtraheerd en valt buiten de V2
   tree-hash van de patch-ID-directory. OPatch staat uitsluitend `OPatch/` toe.
6. De stage-identiteit is de SHA256 van de exact ondertekende manifestbytes.
7. Na publicatie herberekent de helper beide V2 tree hashes en de OPatch ZIP-
   hash. Pas dan wordt `active_stage` atomisch gepubliceerd.

## Runbinding

De patch-manifestatie bindt aanvullend aan:

- `media_mode=LOCAL_IMMUTABLE_V2`;
- canonical lokale stage-root;
- artifact-manifest SHA256;
- signing-key fingerprint;
- `tree_hash_format=OPG_TREE_HASH_V2`;
- DB-RU en OJVM V2 tree hash;
- lokale OPatch ZIP SHA256.

`APPLY` en `resume` vereisen dezelfde stage-identiteit en herberekenen de lokale
hashes. Sharepaden worden in deze fasen niet gelezen. Een ontbrekende,
gewijzigde of onleesbare stage resulteert in `UNKNOWN/BLOCKED` vóór downtime.

## OEM-flow

De expliciete volgorde wordt:

```text
prepare -> stage-media -> create-window -> assess -> plan -> stage -> approve -> apply -> publish-completion
```

`stage-media` is idempotent wanneer exact dezelfde reeds volledig geverifieerde
stage bestaat. Een conflicterende of incomplete stage wordt nooit hergebruikt.

## Lifecycle completion evidence

De bij `stage` gepubliceerde `execution_state.json` blijft de historische
`03_PLAN_GENERATED / PLAN`-snapshot. Na een volledig succesvolle APPLY en pas
nadat de lokale state `12_COMPLETE / COMPLETE / exit_code=0` is, voegt de
begrensde lokale root-helper afzonderlijk `completion.json` toe aan exact de
approvaldirectory van dezelfde RUN_ID. Geen bestaand PLAN-, approval- of
signature-artifact wordt daarbij gewijzigd.

Het completion-artifact bindt de lokale terminale identiteit, completiontijd,
manifest-SHA256 en approval-SHA256. Het introduceert geen target-side private
key en is dus target-published evidence binnen de root-helpertrustgrens, geen
nieuwe cryptografische attestatie. Signer-side COMPLETE vereist daarnaast nog
steeds volledige verificatie van de bestaande manifest- en approvalsignatures,
public-keyfingerprint, conditionals en de relatie `completion_epoch <=
expires_epoch`. Publicatiefalen blijft zichtbaar en retrybaar, maar draait een
reeds toegepaste patch nooit terug.

## Scope

Approval-, signing-, locking-, state-machine-, OPatch-upgrade-, RU/OJVM-,
datapatch-, utlrp- en OEM-contextsemantiek van Pilot06c blijven ongewijzigd,
behalve de expliciete mediabinding en de nieuwe vóórfase `stage-media`.
