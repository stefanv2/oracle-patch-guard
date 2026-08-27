# Public release audit

Auditdatum: 2026-08-27

Publicatiedoel: `https://github.com/stefanv2/oracle-patch-guard.git`

## Scope

De audit omvat ieder bestand dat voor de eerste Git-commit is geselecteerd:
runtimecode, privileged helpers, signer-tools, tests, fixtures, schema's,
configvoorbeelden en actuele Pilot07-documentatie. Historische workspace- en
releasearchieven vallen buiten de Git-tree en zijn niet gescand als te
publiceren inhoud.

## Privacy- en infrastructuurscrub

De initiële source-of-truth bevatte publicatiegevoelige, site-specifieke
voorbeelden. De volgende categorieën zijn vervangen:

- acht productieachtige hostidentiteiten door `DBHOST01`–`DBHOST08`;
- acht database-identiteiten door `ORCL1`–`ORCL8`;
- een intern DNS-suffix door het gereserveerde `example.com`;
- de centrale shareboom door `/mnt/patch-share/oracle-patches` en
  `/mnt/patch-share/oracle-patch-guard`;
- de backup-agenthost, library en storage-unit door generieke voorbeeldwaarden;
- een lokaal Windows-bronpad en voorbeeld-change-ID's door neutrale waarden;
- een niet-publieke recoverymediaboom door `/mnt/patch-share/oracle-media`.

De vervangingen raken alleen hardcoded defaults, voorbeelden, tests en
documentatie. Configuratie-invoer, validatieregels, manifestbinding, hashing,
approval, state-machine en fail-closed gedrag zijn niet versoepeld.

## Bewust uitgesloten

Niet opgenomen in de repository:

- `archive/`, alle oude worktrees en evidence-unpacks;
- `releases/`, release-tarballs en checksums;
- de cleanup-workspace en Codex/lokale metadata;
- presentaties, screenshots en presentation-build/node_modules;
- tijdelijke bestanden, logs, editorlocks, Pythoncache en `*.before-*`;
- de site-specifieke `project/patchGD_guard.conf`, inclusief de daarin eerder
  aanwezige concrete recoverychecksum en lokale agentconfiguratie;
- verouderde Pilot06/OEM14 change reports en oude MVP audit/extension/migration
  reports;
- alle private key-, credential-, approval- en runtime-stategegevens.

Alleen `project/patchGD_guard.conf.example` is opgenomen als generieke
configuratiebasis.

## Secret scan

De uiteindelijke Git-tree is gecontroleerd op:

- PEM-, RSA- en SSH-private-keyheaders;
- passwords, bearer/authorizationwaarden, API keys en credentialtoewijzingen;
- key- en walletachtige bestandsnamen;
- e-mailadressen, niet-publieke URLs, Windows/UNC-paden en IPv4-adressen;
- high-risk namen zoals private key containers, wallets en Oracle network
  configuration.

Resultaat: geen opgeslagen private key, password, tokenwaarde, API key,
credential, certificate, SSH key of e-mailadres gevonden. Er zijn geen
`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, wallet- of SSO-bestanden in de
Git-tree.

Functionele termen zoals approval token en private key komen terecht voor in
validatiecode en securitydocumentatie. De regressietests genereren uitsluitend
kortlevende RSA-testkeys onder een tijdelijke directory en schrijven geen key
naar de repository.

De IPv4-regex vindt alleen vierdelige OPatch-versienummers; er staat geen
netwerk-IP-adres in de public-tree. De enige HTTP(S)-verwijzingen zijn het
officiële JSON Schema-adres, een bewust ongeldig schema-ID en de beoogde GitHub
repository-URL.

## Validatie

- Bash syntax: schoon voor alle actieve shellbestanden.
- Pythoncompile: 2/2 actieve Pythonhelpers schoon, zonder cachebestand.
- ShellCheck: geen nieuwe bevindingen; alleen de bestaande SC1091 en drie
  indirect gebruikte SC2034-baselinemeldingen.
- Regressies: 265/265 groen.

| Suite | Resultaat |
|---|---:|
| Core/original + Pilot07 corebinding | 74/74 |
| Open checks | 27/27 |
| Pilot05b-Pilot05e | 39/39 |
| OEM14 approval/staging | 13/13 |
| OEM wrapper/security | 36/36 |
| Pilot07 media/V2/security | 48/48 |
| Signer status/awk | 14/14 |
| Signer multi-target batch | 14/14 |

## REVIEW_REQUIRED

- Er is bewust geen `LICENSE` toegevoegd. De eigenaar moet vóór formele
  open-sourcepublicatie een licentie kiezen.
- Oracle software, OPatch en RU/OJVM-media zijn niet opgenomen. De eigenaar
  moet toepasselijke Oracle-licentie- en distributievoorwaarden zelf bewaken.
- Het bestaande site-controlled `opg_approve_run.sh` is niet aangeleverd en
  daarom geen onderdeel van deze repository; batchsigning blijft daarvan
  afhankelijk.
- Generieke public defaults moeten vóór ieder gebruik worden vervangen door
  lokaal beoordeelde, root-controlled configuratie en herstelprocedures.
