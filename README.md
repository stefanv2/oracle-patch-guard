# Oracle Patch Guard

Oracle Patch Guard (OPG) is a safe, auditable and approval-driven Oracle
Database patching framework with staged media validation, cryptographic
approval and multi-target support.

<p align="center">
  <img src="docs/images/oracle-patch-guard.png"
       alt="Oracle Patch Guard"
       width="900">
</p>

The controlled workflow is:

```text
PLAN → APPROVE → APPLY
```

PLAN records a fail-closed preflight assessment and binds the exact target,
Oracle Home, patch media and recovery evidence into an immutable manifest.
APPROVE signs that manifest and a separate approval token. APPLY obtains the
Oracle Home lock, repeats volatile checks, re-verifies local staged media and
cryptographic bindings, and only then permits downtime or patch mutation.

## Key properties

- preflight assessment well before the maintenance window;
- a fresh pre-apply recheck before database or listener shutdown;
- local validated media staging with ZIP SHA256 and deterministic V2 tree
  hashes;
- cryptographic manifest binding and explicit approval;
- APPLY and resume re-verification with fail-closed state handling;
- Oracle Home, PMON, listener, SID, service and SQL patch validation;
- controlled OPatch self-upgrade before RU/OJVM mutation;
- multi-target support with a per-host/per-home lock;
- OEM integration through constrained wrappers and local privileged helpers;
- signer-side status reporting and batch approval orchestration.

## Repository layout

- `project/` — patch guard core, checks, OEM wrappers, fixtures and tests;
- `oem-tasks/` — target orchestration, approval staging and media helpers;
- `signer/` — read-only run status and multi-target approval orchestration;
- `config/examples/` — generic cycle and sudoers examples;
- `tools/` — standalone hashing benchmark;
- `PILOT07_*.md`, `TREE_HASH_V2_SPEC.md` — design, security and validation
  documentation.

Site-specific values belong in a protected local configuration copied from
`project/patchGD_guard.conf.example`. The repository intentionally contains no
production configuration, private key, approval data or release archive.

Example public paths use `/mnt/patch-share`; example hosts use the reserved
`example.com` domain. Review every path, owner, group, sudo rule, recovery hook
and maintenance-window policy before deployment.

## Validation

Run on Linux with Bash, Python 3, OpenSSL and ShellCheck available:

```bash
cd project
bash tests/run_tests.sh
bash tests/run_open_checks_tests.sh
bash tests/run_pilot05b_tests.sh
bash tests/run_oem14_approval_tests.sh
bash tests/run_oem_wrapper_tests.sh
bash tests/run_pilot07_tests.sh
bash tests/run_signer_pending_tests.sh
bash tests/run_signer_batch_tests.sh
```

The current public-release baseline is 265/265 passing regressions. See
`PILOT07_VALIDATION_REPORT.md` and `PUBLIC_RELEASE_AUDIT.md` for details.

## Important limitations

- The project is pilot software and requires non-production validation for the
  target Oracle release, topology and backup implementation.
- RAC, SEHA, ASM/Grid and Data Guard configurations are detected and blocked by
  the current single-instance scope.
- The existing site-controlled `opg_approve_run.sh` remains the sole mutating
  single-run signer. It is an integration dependency and is not included in
  this repository.

## License

Oracle Patch Guard is licensed under the [Apache License 2.0](LICENSE).
