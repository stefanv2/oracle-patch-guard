# OEM Agent blackout orchestration

## Scope and installation

Keep **Same targets for all tasks / Host**. The existing `oracle` Named
Credential runs all steps. No substitutions, EMCLI, REST, root privileges or
additional sudo are used. Deploy `oem-tasks/opg_blackout.py` together with
`opg_oem.sh`; Python 3 and Linux `flock` support are required. This is wrapper
functionality, not a change to patchcore.

Add the `OEM_*` keys from `project/patchGD_guard.conf.example` to the existing
trusted, root-owned local config using the normal installation procedure.
Missing `OEM_BLACKOUT_MODE` means `disabled`; explicit `disabled` has the same
APPLY behavior but requires the matching new module to validate configuration.
Explicit start/stop actions are still available when mode is disabled.

Configure the exact Agent-instance `bin/emctl`. The binary must belong to the
executing user, be executable, not group/world writable and have no symlink
path components. Existing group-writable Oracle parent directories such as
`/u01` are accepted; existing site trust in the Oracle installation is retained.
Agent Home, Started by user, readiness and the exact local host inventory
entry are checked. No path search or fallback to database/Grid homes occurs.

## Target binding

START reuses APPLY's existing context, host, SID/home discovery and
`03_PLAN_GENERATED` requirement. Its target binding is deliberately limited to:

**validated local OPG SID + exact local Agent oracle_database target name**.

`listtargets` does not prove Oracle Home. Zero exact matches blocks; duplicate
matches block; malformed inventory is unknown. PDB/service/listener entries
never qualify. One active database context per host remains the existing limit.

## Run identity and state

START creates `OPG_<RUN_ID>` and records binding in
`/var/log/oracle-patch-guard/<RUN_ID>/blackout_state.json` (0600, oracle-owned,
inside the existing 0700 directory). The conservative OPG name limit is 84
characters; this is not asserted as Oracle's maximum.

Per-run nonblocking lock, no-follow reads, duplicate-key rejection and atomic
temporary-file/flush/fsync/rename/directory-fsync publication prevent partial
state. This follows the publication sequence in `opg_atomic_write`; Python
implements it locally to retain structured JSON and no-follow file descriptors
without sourcing core or launching a separate shell for each state write.

PREPARED is durable before external START. A crash after START is reconciled
against that record; unknown existing names are never adopted. Repeated START
only succeeds with the same active binding and adequate remaining duration.
STOP uses `--run-id` and saved binding, not current context or fresh DB discovery.
The wrapper loads only RUN_ROOT from local path configuration for STOP, including
nondefault roots. No patch-cycle, PMON or execution-state validation is involved.
STOP reads only the Agent binding from OEM configuration; invalid or duplicate
START/APPLY mode, duration and minimum-remaining settings are ignored for cleanup.
Agent binding/config trust and saved state validation remain mandatory.
It therefore works after failure, manual intervention or PMON shutdown. Changes
to the configured Agent path require operator reconciliation, not silent retargeting.

## Job flow and APPLY guard

1. `opg_oem.sh blackout-start`
2. `opg_oem.sh apply --run-id <the START run ID>` on START success
3. `opg_oem.sh blackout-stop --run-id <the same run ID>` after APPLY terminates

Pin run IDs per host before scheduling; do not reconstruct them in STOP from
`current_run.json`, use the newest directory, or reuse one host's ID on another.
The required-mode APPLY guard demands an explicit expected run ID to detect
context rotation. The old parameterless APPLY remains compatible in disabled
mode. The run ID is an explicit script argument, not an OEM substitution.

Configure `OEM_BLACKOUT_MODE=required` only when the flow is ready. The guard
checks STARTED state, run/host/SID/home binding, exact own active blackout and
minimum remaining duration before invoking existing `oem_apply.sh`.

There is no evidenced production runtime in this change from which to select
a safe default. Configure duration (00:01 through 23:59)
from measured full APPLY time plus scheduling/cleanup margin. Set minimum
remaining seconds to the required APPLY coverage, not merely a few seconds.
The 300-second default is a technical admission floor, not a patch-duration SLA.
Maximum duration is a fallback, not primary cleanup. No automatic extension.

Before any external START or PREPARED publication, a new START requires duration
at least `minimum remaining + 120 seconds`. The explicit 120-second operational
margin covers the two 45-second command limits for START/status confirmation
plus 30 seconds of scheduling allowance. The request timestamp is taken after
preflight, immediately before PREPARED publication. Runtime uncertainty still
requires confirmation and the existing remaining-duration check after START.
`00:05` with minimum 300 is rejected with BLACKOUT_DURATION_INSUFFICIENT (20)
without starting a blackout or writing PREPARED. `00:05` with minimum 60 is valid.

Multi-target task dependency isolation remains unproven. Qualify two hosts
with dummy APPLY (one succeeds, one exits 1), and verify each cleanup runs after
its own APPLY. Never treat `Always` as a proven finally without that test.
Cancellation and Agent loss can prevent cleanup. Preserve the APPLY result and
report cleanup separately; STOP never modifies patch execution state.

## Status and failure contract

The strict 13.4 adapter covers the user-supplied during/after output, including
finite `Time` records and unrelated indefinite records. Own blackout duration
must match state; its Agent-local start time must be within 120 seconds of the
durable request. Agent and wrapper must use the same host timezone. Remaining
coverage uses the earlier of those two timestamps. Unknown output fails
closed. An exit code or matching name alone is not success. Unrecognized output
must be added as reviewed fixtures before supporting that Agent variant.

START blocks when a foreign active blackout affects the target. In the supplied
test output `automatic_patching_OPG` remains active after the test blackout ends:
OPG will not stop, claim or silently work around it. Operators must reconcile
that blackout separately before testing a new START through OPG.
The supplied output shows technical coexistence of the two blackouts. Blocking
overlap is conservative OPG policy, not a demonstrated OEM limitation. Establish
the owner and originating operational process of `automatic_patching_OPG`
before considering any policy change; never automatically stop or adopt it.

STOP ends only the saved exact-name/exact-target blackout and succeeds when
that blackout is absent or explicitly expired, even if a foreign one remains.
It does not prove all monitoring is restored. Corrupt/mismatched state blocks;
timeouts are reconciled via status. Unconfirmed actions return UNKNOWN (30),
policy/binding failures BLOCKED (20), valid operations 0.

## First five-minute test (after review; no APPLY)

Keep mode disabled. Set `OEM_BLACKOUT_MIN_REMAINING_SECONDS=60` for this short
test only, through the normal config-management process. Restore a suitably
sized production threshold before enabling required mode. Resolve the existing
foreign blackout separately. A valid PLAN-stage context is required.

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh blackout-start --duration 00:05
```

Record the returned run ID. In OEM verify only the database target was selected,
then run a new Host-based probe task (`id; date -u; echo OPG_PROBE`). Stop using
the recorded ID, not a new context lookup:

```bash
/bin/bash /mnt/patch-share/oracle-patch-guard/oem-tasks/opg_oem.sh blackout-stop --run-id <RECORDED_RUN_ID>
```

Check the own blackout disappeared and metric collection resumes. The supplied
September 10 run ID may no longer be PLAN-stage: do not force or rewrite its
state to pass this test.

Next qualify two-host dummy success/failure cleanup, then required-mode real
APPLY on the testhost. No database-core change is needed.

## CDB/PDB limitation

Only `d001pcdb:oracle_database` is selected. Separate `oracle_pdb` targets are
not automatically added. The supplied test coexisted with a foreign blackout
already covering PDBs; it cannot prove that the narrow database blackout alone
suppresses PDB alerts. Verify this independently before claiming full coverage.

## Validation commands

```bash
python3 -B project/tests/run_blackout_tests.py
bash project/tests/run_oem_wrapper_tests.sh
bash project/tests/run_tests.sh
python3 -B project/tests/run_sqlpatch_action_tests.py
bash project/tests/run_pilot07_tests.sh
python3 -B project/tests/run_state_write_tests.py
bash -n oem-tasks/opg_oem.sh
git diff --check
```
