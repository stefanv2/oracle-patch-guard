# Oracle Patch Guard stable baseline — 2026-08-31

## Scope

This release consolidates the live-validated Oracle Patch Guard baseline. It
does not introduce any P1/P2/P3 redesign from the independent critical review.
Oracle patching remains single-instance Oracle Database 19c without RAC, SEHA,
ASM/Grid or Data Guard.

## Stable changes

### Per-container datapatch correctness

OPG establishes an exact expected container set consisting of `CDB$ROOT`
(`con_id=1`) and all user PDBs from the original PDB-state snapshot.
`PDB$SEED` is deliberately excluded. For every expected container and expected
patch ID, exactly one latest SQLPATCH record must contain the correct container
identity, patch ID, `SUCCESS` status and a parseable action timestamp.

Missing, duplicate, unexpected, ambiguous, unparseable or non-SUCCESS evidence
stops fail-closed. The permanent negative regression reproduces the original
false-PASS: root has RU and OJVM SUCCESS while a user PDB has only RU; OJVM is
reported MISSING and the run cannot become COMPLETE.

### PDB state policy

- READ WRITE user PDBs remain open.
- READ ONLY user PDBs are temporarily reopened READ WRITE.
- MOUNTED/closed user PDBs are temporarily opened READ WRITE.
- Per-container SQLPATCH validation runs before state restoration.
- The original state is restored and verified with a fresh SQL query.
- Open or restore failure requires manual intervention; no automatic rollback
  is performed.
- ORA-65019 is tolerated only when the fresh state query proves the exact
  desired state was already reached.

### Deployment and approval lifecycle

- Fresh-host bootstrap installs root-owned helpers, the validated sudoers
  fragment, protected runtime configuration and trusted stage anchors.
- Runtime roots are obtained from safely parsed configuration; configuration is
  not sourced or evaluated as shell code.
- Public defaults remain conservative. Site-specific thresholds, including
  `/tmp` and Oracle Home recovery headroom, belong only in protected site
  configuration and are used consistently by ASSESS and PREAPPLY.
- Batch approval performs one operator confirmation and then feeds `APPROVE` to
  the existing single-run signer for each still-PENDING run.
- A successful `12_COMPLETE` APPLY publishes atomic, hash-bound completion
  evidence. Historical COMPLETE remains valid only when all signatures and
  bindings verify and completion occurred no later than approval expiry.

## Live validation evidence

- Full regression baseline: **351/351 PASS**.
- Fresh target bootstrap and PLAN completed without manual target fixes.
- PLAN reached `WAITING_FOR_APPROVAL`.
- Batch approval completed successfully.
- APPLY completed with `status=COMPLETE`, `phase=VALIDATION`, `exit_code=0`.
- Completion publication returned `status=SUCCESS`.
- Oracle Database 19.32 CDB root and user PDB both registered DB RU 39472050
  and OJVM RU 39222882 as SUCCESS.
- `PDB$SEED` remained READ ONLY; the user PDB returned to READ WRITE.
- Observed APPLY runtime: 23m13s, including approximately 10m20s DB RU binary,
  2m46s OJVM, 5m27s datapatch and 2m03s final validation.

## Release discipline

`current` is a pointer to an immutable validated release, never a directory for
loose fixes. Future work must be built and tested in a separate RC/release
directory before `current` is deliberately advanced.
