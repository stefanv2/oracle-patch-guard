# Completion publication change report

## Scope

Deze wijziging voegt uitsluitend lifecycle completion evidence toe na een
succesvolle Oracle Patch Guard APPLY. PLAN, approval-signing, private-keylocatie,
media staging en de core patchstate-machine zijn niet gewijzigd.

## Gedrag

- `execution_state.json` op de approval-share blijft de immutable PLAN-snapshot.
- Na core-APPLY exit 0 roept `opg_oem.sh` de lokaal geïnstalleerde root-owned
  helper aan als `publish-completion <RUN_ID>`.
- De helper leest uitsluitend vaste context-, run- en approvalroots, valideert
  de actieve context en lokale `12_COMPLETE / COMPLETE / exit_code=0` state,
  en construeert zelf `completion.json`.
- `completion.json` bindt RUN_ID, host, SID, Oracle Home, cycle,
  completiontijd, manifest-SHA256 en approval-SHA256.
- Publicatie is atomisch, `root:oinstall 0440`, non-overwriting en idempotent
  voor exact dezelfde bytes.
- Iedere RUN_ID heeft zijn eigen completion-artifact; er is geen batchstate.

## Signer-status

`opg_list_pending.sh` classificeert een run alleen als COMPLETE wanneer de
bestaande manifest- en approvalsignatures, public-keyfingerprint, bindings en
conditionals volledig geldig zijn én `completion.json` veilig en exact gebonden
is. Een verlopen approval blijft alleen historisch COMPLETE wanneer de
betrouwbare completiontijd op of vóór `expires_epoch` ligt.

Zonder completion blijft een verlopen approval UNKNOWN. Corrupte, incomplete,
symlinked of anders gebonden completion evidence blijft eveneens UNKNOWN.

## Trust boundary

Er is bewust geen nieuwe private key op het target en geen `completion.sig`.
Completion is target-published evidence binnen de bestaande lokale root-helper-
en filesystemtrustgrens. De SHA256-velden binden het artifact aan de bestaande
cryptografisch verifieerbare manifest- en approvalbytes, maar vormen zelf geen
targetattestatie. Een gecompromitteerde target-root valt buiten deze garantie.

## Failure en recovery

Mislukte publicatie na succesvolle patching retourneert zichtbaar
`OPG_COMPLETION_PUBLISH|...|status=FAILED` en wrapper-exit 30. De lokale
`12_COMPLETE`-state en toegepaste patches worden niet teruggedraaid. Na herstel
van de publicatieoorzaak kan uitsluitend `opg_oem.sh publish-completion` worden
herhaald; APPLY wordt niet opnieuw uitgevoerd.

Automatische cleanup is niet toegevoegd. Completion evidence kan later input
zijn voor een afzonderlijk ontworpen en goedgekeurd retentioncontract.
