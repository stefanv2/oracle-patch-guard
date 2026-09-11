# Completion publication validation report

Validatiedatum: 2026-08-28

## Resultaat

Alle actieve regressies zijn uitgevoerd na de completion-publicationwijziging:

| Suite | Resultaat |
|---|---:|
| Core/original + Pilot07 corebinding | 74/74 |
| Open checks | 27/27 |
| Pilot05b-Pilot05e | 39/39 |
| OEM14 approval/staging | 13/13 |
| OEM wrapper/security/completion routing | 38/38 |
| Pilot07 media/V2/security | 48/48 |
| Signer status/completion/awk | 28/28 |
| Signer multi-target batch | 14/14 |
| Completion root-helper publication | 14/14 |
| **Totaal** | **295/295** |

Bash-syntaxcontrole voor alle actieve shellbestanden is schoon. ShellCheck op
alle gewijzigde scripts is schoon.

## Bewezen completiongedrag

- Een coherente lokale COMPLETE-run publiceert atomisch `completion.json`.
- RUN_ID, host, SID, Oracle Home, cycle, completiontijd en exitcode zijn exact.
- `manifest_sha256` en `approval_sha256` binden de bestaande bytes.
- Publicatie is `root:oinstall 0440`, non-overwriting en exact idempotent.
- Bestaande signer-artifacts met `root:root 0644` worden veilig geaccepteerd
  naast staged `root:oinstall 0440`-artifacts; modes met group/world-write
  (`0664`, `0666`, `0646`) blijven fail-closed geblokkeerd.
- Path traversal, symlink-rundirectory, niet-terminale state, bindingmismatch,
  completion na expiry en conflicterend bestaand artifact blokkeren fail-closed.
- Een wrapperpublicatiefout laat de lokale `12_COMPLETE`-state intact, meldt
  exit 30 en is zonder herhaalde APPLY retrybaar.
- Signer-side worden incomplete, corrupte, symlinked of verkeerd gebonden
  completions UNKNOWN.
- Verlopen approval plus geldige completion binnen expiry wordt COMPLETE;
  zonder completion of na expiry blijft de status UNKNOWN.
- Ongeldige manifest- of approvalsignature blijft UNKNOWN.
- PENDING en niet-verlopen APPROVED zijn ongewijzigd.
- Multi-target completion evidence blijft volledig per RUN_ID geïsoleerd.

## Niet gewijzigd

De core patchstate-machine, PLAN-binding, approval-signing, private-keylocatie,
lokale media-architectuur, APPLY-mutaties en automatische cleanup zijn niet
gewijzigd.
