# Immutable release-layout

## Actieve software en persistente data

Oracle Patch Guard activeert één complete, read-only release via:

```text
${OPG_ROOT}/current -> ${OPG_ROOT}/releases/<unieke-release-id>
```

De release-directory bevat alle releasegebonden code:

```text
releases/<unieke-release-id>/
├── oem-tasks/
│   ├── opg_oem.sh
│   ├── opg_prepare_host.sh
│   ├── opg_create_window.sh
│   ├── opg_assess_task.sh
│   ├── opg_stage_approval.sh
│   ├── opg_blackout.py
│   ├── opg_bootstrap_host.sh
│   ├── opg_build_artifact_manifest.py
│   ├── opg_context_root.sh
│   ├── opg_media_stage_root.sh
│   └── opg_media_stage_root.py
├── project/
│   ├── patchGD_guard.sh
│   ├── oem_assess.sh
│   ├── oem_apply.sh
│   ├── lib/
│   └── checks/
├── config/examples/
└── artifact_manifest.schema.json
```

De actuele runtimepaden zijn uitsluitend:

```text
${OPG_ROOT}/current/oem-tasks/
${OPG_ROOT}/current/project/
```

Er is geen actieve helperfallback naar `${OPG_ROOT}/oem-tasks`.

Operationele data blijft buiten de release en wordt bij een releasewissel niet
gekopieerd of vervangen:

```text
${OPG_ROOT}/config/                 centrale configuratie en active_cycle
${OPG_ROOT}/approvals/              approvals en completion-publicaties
${OPG_ROOT}/evidence/               persistente centrale evidence
/etc/oracle-patch-guard/            root-owned hostconfig
/var/lib/oracle-patch-guard/        current_run.json, archive en context_history.log
/var/log/oracle-patch-guard/<RUN_ID>/ run-evidence
```

## Complete release maken

Maak voor iedere kandidaat een nieuwe, unieke directory. Vul die vanuit één
geteste Git-commit met de volledige repositorymappen `oem-tasks/` en `project/`,
plus `config/examples/` en `artifact_manifest.schema.json`. De map
`oem-tasks/` is pas compleet wanneer ten minste de zes hierboven genoemde
wrapper/helpers en alle door de wrapper aangeroepen releasehelpers aanwezig
zijn.

Leg vóór activatie de Git-commit en SHA256 per runtimebestand vast, zet eigenaar
en modes volgens het lokale deploymentbeleid en maak de release daarna
read-only. Voer de regressies tegen precies deze directory uit. Wijzig een
bestaande release-directory nooit in-place; maak bij iedere wijziging een
nieuwe release-id.

Activeer na validatie `current` met één atomische symlinkwissel naar de nieuwe
release. De huidige handmatig gewijzigde
`oracle-patch-guard-stable-20260902` wordt niet hergebruikt als nieuwe
immutable baseline. Gebruik een nieuwe unieke naam die de gevalideerde build
identificeert, bijvoorbeeld datum plus korte Git-hash.

## Bootstrapcontract

`current/oem-tasks/opg_bootstrap_host.sh` leest de centrale hostconfigcandidate
uit `${OPG_ROOT}/config/patchGD_guard.conf`, valideert die en plaatst hem
atomisch als `/etc/oracle-patch-guard/patchGD_guard.conf`. Ook `approval_public.pem`
en `oracle_home_rebuild.md` komen uit die centrale configdirectory en worden
vóór de lokale config als root-owned bestanden geïnstalleerd. Bootstrap maakt
RUN_ROOT, LOCK_ROOT en de context/stage-roots zodat STAGE_MEDIA en PRECHECK
geen voorafgaande PREPARE nodig hebben. PREPARE controleert later uitsluitend
deploymentdrift; de wrapper behoudt zijn bestaande formele contextrol.
Zie het volledige [fresh-host contract](../OEM_WRAPPER_GUIDE.md#fresh-host-installatiecontract).
De meegeleverde
privileged helpers komen uit dezelfde actieve release onder
`current/oem-tasks`. Bootstrap verandert de patch- of lifecyclelogica niet.
