# Requirements traceability

Legenda: `IMPLEMENTED`, `PARTIAL`, `MOCKED`, `PLACEHOLDER`, `NOT_IMPLEMENTED`, `NOT_TESTED_ON_ORACLE`.

| Hoofdgroep | Status | Implementatie/bewijs |
|---|---|---|
| Origineel behouden/ongewijzigd | IMPLEMENTED | `MIGRATION_FROM_patchGD.md`; actuele SHA in `CODE_AUDIT_REPORT.md` |
| Interface assess/plan/apply/status/resume/cleanup | IMPLEMENTED | `patchGD_guard.sh` command-dispatch; syntax/tests |
| Historische vijf parameters; defaults opt-in | IMPLEMENTED | `load_patch_parameters`, testparameterflow |
| Canonieke immutable doelhome | IMPLEMENTED | `init_new_run`, `opg_canonical_dir` |
| Configtrust | IMPLEMENTED | `validate_config_trust`; OEM-wrapperpadcontrole |
| Veilige oratab-parser/andere homes | IMPLEMENTED | `opg_parse_oratab`; scenario’s 2–4 |
| SID↔PMON↔home-koppeling | PARTIAL / NOT_TESTED_ON_ORACLE | `inventory_databases`, `verify_no_unexpected_home_processes`; `/proc` niet echt getest |
| RAC/SEHA/ASM/Grid-detectie | PARTIAL / NOT_TESTED_ON_ORACLE | `detect_unsupported_topology`, ASM datafilecheck; alleen fixturetest |
| Data Guard-detectie | IMPLEMENTED / NOT_TESTED_ON_ORACLE | database role-query plus `checks/check_dataguard`; scenario 9 mock |
| Oracle Linux 8/9, x86_64, 19c | IMPLEMENTED / NOT_TESTED_ON_ORACLE | `perform_assessment`, `perform_preapply_recheck` |
| Central/local inventory en OPatch lsinventory | IMPLEMENTED / NOT_TESTED_ON_ORACLE | assessment en preapply inventorylogs |
| OPatch-versie | IMPLEMENTED / MOCKED | assessment/preapply; scenario 5 |
| Patch-ID/type/README | PARTIAL | directory-ID en README-aanwezigheid; semantische README/patchtypebeoordeling handmatig |
| Patchchecksums en wijzigingsdetectie | IMPLEMENTED | `opg_tree_hash`, manifest, `verify_static_context_unchanged`; scenario 18 |
| DB-RU- en OJVM-conflicten vóór downtime | IMPLEMENTED / MOCKED | assessment én `perform_preapply_recheck`; scenario’s 6, 7 en 22 |
| Vrije ruimte | IMPLEMENTED / MOCKED | `check_path_space`, `preapply_check_space`; scenario 21 |
| SQL patchfouten vóór patch | IMPLEMENTED / NOT_TESTED_ON_ORACLE | `inventory.sql`, preapply DB-query; scenario 10 mock |
| Actieve Data Pump | IMPLEMENTED / MOCKED | één inventory-SQL-bron met jobdetails; assessment en preapply; scenario’s 8, 19 en 31 |
| DB/PDB/listener/service-nulmeting | IMPLEMENTED / NOT_TESTED_ON_ORACLE | `inventory_databases`, listenerstatus, CSV |
| Recente databaseback-up | IMPLEMENTED / NOT_TESTED_ON_ORACLE | `checks/check_rman_backup`, inclusief archivelogmaximum 26 uur; scenario 20 hercontrole |
| Oracle Home-herstelroute | IMPLEMENTED / NOT_TESTED_ON_ORACLE | `checks/check_oracle_home_recovery`, deterministisch recoverymanifest; concrete valid/blocked/unknown tests |
| Onderhoudsvenster | IMPLEMENTED / NOT_TESTED_ON_ORACLE | root-owned manifest, fasegebonden tijd- en contextcontrole; concrete valid/blocked/unknown tests |
| Twee controlemomenten | IMPLEMENTED / MOCKED | `perform_assessment` en lockgebonden `perform_preapply_recheck`; scenario’s 18–22 |
| READY/CONDITIONAL/BLOCKED/UNKNOWN | IMPLEMENTED | `opg_determine_assessment_status`; scenario’s 1–10 |
| Afzonderlijke conditional-acceptatie | IMPLEMENTED | `verify_approval` per finding-ID |
| Asymmetrisch ondertekend manifest/token | IMPLEMENTED | OpenSSL verify met `APPROVAL_PUBLIC_KEY`; scenario’s 25–26 gebruiken echte tijdelijke RSA-sleutel |
| Atomische statewrites | IMPLEMENTED | `opg_atomic_write`, `opg_write_state`; lokaal getest |
| Exclusieve host/home-lock | IMPLEMENTED / NOT_TESTED_ON_LINUX | `opg_acquire_lock`; mockscenario 15, echte `flock` open |
| Lock vóór laatste apply-hercontrole | IMPLEMENTED | `perform_apply` volgorde |
| Originele exitcode in wrappers/traps | IMPLEMENTED | corefix en alle OPG_RESULT-asserties |
| Shutdown/startup per oorspronkelijke toestand | IMPLEMENTED / MOCKED | `stop_databases`, `start_original_databases`; scenario 12 |
| Listener stop/start en homecontrole | IMPLEMENTED / NOT_TESTED_ON_ORACLE | listenerfuncties en markers |
| DB-RU/OJVM binary apply + inventory | IMPLEMENTED / MOCKED | `apply_binary_patches`; scenario 11 |
| PDB-herstel | PARTIAL / MOCKED | `restore_pdb_state`; restricted/saved-statevarianten niet bewezen |
| Datapatch per database | IMPLEMENTED / MOCKED | `run_datapatch_all`; scenario 13 |
| Utlrp per database | IMPLEMENTED / MOCKED | `run_utlrp_all` |
| SQLpatch/registry/invalid-object-eindvalidatie | IMPLEMENTED / MOCKED | `validate_all`; scenario 24 |
| Serviceherstel | PARTIAL | automatische DB-start plus inhoudelijke vergelijking; geen generieke startactie |
| OEM-verversing | PARTIAL / MOCKED | `emctl upload agent`; collection mapping ontbreekt |
| Resume zonder blind herhalen | IMPLEMENTED / MOCKED | fasevalidatie, inventory en completion-markers; scenario’s 27–28 |
| OEM-time-outstatus | PARTIAL / MOCKED | wrappermarker + `perform_status`; echt signaleringsgedrag onbewezen |
| OEM waves/paralleliteit | PLACEHOLDER | `OEM_DEPLOYMENT_PROCEDURE.md`; OEM moet dit uitvoeren |
| Centraal batchrapport | PARTIAL / NOT_TESTED_ON_OEM | `oem_collect_results.sh` |
| Cleanup | IMPLEMENTED ALS NO-OP | alleen reviewrapport, geen verwijdering |
| OS-update/reboot | NOT_IMPLEMENTED | opties worden geblokkeerd |
| Dry-run | IMPLEMENTED VOOR SAFETY | read-only assess/preapply draait echt; muterende opdrachten worden onderdrukt; patchsucces wordt niet bewezen |
| 18 oorspronkelijke fixturescenario’s | MOCKED | alle productieflow, externe commando’s gemockt |
| Uitgebreide negatieve regressies | IMPLEMENTED / MOCKED | 35 hoofdscenario’s plus 6 concrete open-checktests |
| ShellCheck | NOT_IMPLEMENTED IN LOKALE OMGEVING | exact later commando in auditrapport |
