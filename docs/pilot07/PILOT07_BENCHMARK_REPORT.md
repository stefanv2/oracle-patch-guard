# Pilot07 benchmarkrapport en meetplan

## Bestaande metingen

Voor DB RU `39472050` (27.846 files, circa 5.457 GB) op dezelfde server:

| Locatie / methode | Gemeten duur |
|---|---:|
| Centrale share, huidige pipeline | 969 s / 553 s |
| Centrale share, sequentieel lezen | circa 224 s |
| Centrale share, hashing | circa 219 s |
| Centrale share, P2-variant | circa 283 s |
| Lokale XFS, huidige pipeline | 32 s / 28 s |
| Lokale XFS, sequentieel lezen | circa 24 s |
| Lokale XFS, hashing | circa 26 s |
| Lokale XFS, P2-variant | circa 40 s |

De spreiding en het verschil tussen NFS en XFS bewijzen dat share-latency,
metadata-walks, file-reads en cachetoestand dominant zijn. SHA256-CPU of
single-threading is niet de primaire bottleneck; parallelisatie was lokaal zelfs
langzamer. Pilot07 optimaliseert daarom de architectuur: één transportcopy per
ZIP, daarna alle herhaalde V2-verificaties lokaal.

## Reproduceerbaar meetplan op één target

Voer iedere variant minimaal drie keer uit en registreer wall/user/sys,
filesystemtype, mountoptions, filecount/bytes en cachetoestand.

1. metadata-only: `find ROOT -type f -printf '%P|%s\n'` naar `/dev/null`;
2. read-only: deterministische filelijst, alle bytes naar `/dev/null`;
3. bestaande V1-pipeline;
4. Pilot07 V2-hasher;
5. dezelfde vier metingen op de share en op lokale XFS;
6. cold cache alleen wanneer infrastructuurbeheer expliciet cache-drop toestaat;
   anders eerste/volgende runs als `cold-ish`/`warm` labelen;
7. registreer `nfsstat -c`, `iostat -xz 1`, CPU, load, read throughput en vrije
   inodes/bytes gedurende de run;
8. meet `stage-media` afzonderlijk als copy, extract en hash met
   `evidence/timings.psv`;
9. meet PLAN, PREAPPLY en resume met de share online en offline om te bewijzen
   dat zij geen remote tree-I/O uitvoeren.

Cache-drop, mountwijzigingen en productiebelasting worden niet door Patch Guard
zelf gemuteerd. Een testcoördinator legt die omstandigheden buiten de tool vast.

## Acceptatiecriteria

- V2-hash van dezelfde boom onder verschillende roots is gelijk.
- Een byte- of padwijziging verandert de hash; links/specials falen gesloten.
- De share wordt per stage voor payload slechts eenmaal sequentieel gelezen.
- PLAN/APPLY/resume veroorzaken geen volledige remote tree-walk.
- Lokale herhashduur blijft in dezelfde orde als de bestaande XFS-metingen.
- Twee gelijktijdige stage-aanvragen publiceren één identieke stage.

## Gefaseerde aanbeveling

1. **Pilot06/Pilot07 quick win:** stage drie signed ZIPs eenmaal lokaal en gebruik
   V2 lokaal. Geen parallel hashwerk op NFS.
2. **Middellange termijn:** centrale offline signing en per-target stages vooraf
   vullen, met capaciteit-, inode- en timingtelemetrie per wave.
3. **Multi-server waves:** één gecontroleerde centrale artifact-release, targets
   in begrensde stagingwaves, daarna volledig lokale maintenancewaves. Alleen
   wanneer lokale V2-metingen later CPU-dominantie aantonen is een Rust-helper
   met exact dezelfde golden vectors te rechtvaardigen.
