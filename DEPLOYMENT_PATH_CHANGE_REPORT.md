# Config-driven deployment paths change report

## Scope

Deze wijziging vervangt uitsluitend hardcoded Oracle Patch Guard-sharepaden
door veilige resolutie uit `patchGD_guard.conf`. PLAN, approval, signing, APPLY,
completion, stagingownership en privilegegrenzen zijn niet gewijzigd.

## Configcontract

De actieve example-config bevat nu:

```text
OPG_ROOT=/mnt/patch-share/oracle-patch-guard
APPROVAL_ROOT=/mnt/patch-share/oracle-patch-guard/approvals
```

De waarden zijn voorbeelden. De live config mag de organisatiespecifieke
absolute paden bevatten. Parsers accepteren alleen exact toegestane keys,
voeren geen `source` of `eval` uit, weigeren duplicaten/lege waarden en eisen
absolute lexicaal veilige paden zonder traversal.

## Precedence

- Context-root-helper: expliciete begrensde testvariabele in testmodus;
  anders `APPROVAL_ROOT` uit de vaste root-owned live config.
- OEM-wrapper: expliciete `OPG_TEST_*` alleen in testmodus; anders `OPG_ROOT`
  en `APPROVAL_ROOT` uit de vaste live config.
- Signer: `OPG_APPROVAL_ROOT`/`OPG_APPROVAL_PUBLIC_KEY`, daarna de waarden uit
  `OPG_CONFIG_FILE` of de vaste live config.
- Approval-staging en approval-check ontvangen de reeds gevalideerde waarden
  van de wrapper en lezen bij standalone gebruik dezelfde config.
- De privileged media-helper leest zijn productiepaths rechtstreeks en veilig
  uit dezelfde root-owned config; zijn bestaande testmode blijft ongewijzigd.

## Verwijderde fallbacks

Actieve post-bootstrap runtimecomponenten bevatten geen hardcoded share-root.
Generieke paden blijven alleen zichtbaar in de publieke example-config en
documentatievoorbeelden. De bootstrapbronlocatie is een afzonderlijke
site-deploymentintegratie omdat de lokale runtimeconfig dan nog niet bestaat.
