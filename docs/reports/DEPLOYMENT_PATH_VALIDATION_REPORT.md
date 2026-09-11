# Config-driven deployment paths validation report

Validatiedatum: 2026-08-28

## Regressieresultaat

| Suite | Resultaat |
|---|---:|
| Core/original + Pilot07 corebinding | 74/74 |
| Open checks | 27/27 |
| Pilot05b-Pilot05e | 39/39 |
| OEM14 approval/staging | 13/13 |
| OEM wrapper/security/config-routing | 42/42 |
| Pilot07 media/V2/security | 48/48 |
| Signer status/completion/config | 32/32 |
| Signer multi-target batch | 14/14 |
| Completion helper/config-publication | 17/17 |
| **Totaal** | **306/306** |

Bash-syntaxcontrole, Python compile-validatie en ShellCheck voor alle gewijzigde
runtime- en testbestanden zijn schoon.

## Config- en fail-closedbewijs

- Context-helper leest `APPROVAL_ROOT` uit config en publiceert completion.
- OEM-wrapper leest `OPG_ROOT` en `APPROVAL_ROOT` uit config.
- Signer leest approvalroot en public key uit config.
- Bestaande expliciete signer-environmentoverrides behouden precedence.
- Expliciete testmode-overrides blijven functioneren.
- Relatieve en ontbrekende verplichte waarden worden fail-closed geweigerd.
- Completion-publicatie en historische COMPLETE-detectie blijven groen.

## Hardcoded-pad-audit

Zoektermen:

```text
/mnt/patch-share/oracle-patch-guard
site-specific deployment roots
```

Actieve post-bootstrap runtimebestanden: geen hardcoded share-root. Resterende
generieke hits zijn uitsluitend publieke example-config of documentatie. De
bootstrapbronlocatie blijft onderdeel van de site-deploymentintegratie omdat
de lokale config op een fresh host nog moet worden geïnstalleerd.
