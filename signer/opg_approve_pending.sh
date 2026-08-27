#!/usr/bin/env bash
# Veilige batch-orchestratie rond de bestaande single-run signerflow.
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
  cat <<'EOF'
Gebruik: opg_approve_pending.sh [--all [--dry-run] | --help]

Zonder opties       Toon uitsluitend runs die READY FOR APPROVAL zijn; wijzig niets.
--all               Toon selectie en skips, vraag exact één batchbevestiging en
                    roep daarna opg_approve_run.sh afzonderlijk per RUN_ID aan.
--all --dry-run     Voer dezelfde selectie uit zonder approval-artifacts te schrijven.
--help              Toon deze hulp.

Alleen exact "yes" op de batchvraag start de bestaande single-run signerflow.
EOF
}

DO_ALL=false
DRY_RUN=false
while (( $# > 0 )); do
  case $1 in
    --all) DO_ALL=true ;;
    --dry-run) DRY_RUN=true ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$DRY_RUN" == true && "$DO_ALL" != true ]]; then
  usage >&2
  exit 2
fi

SIGNER_BIN=${OPG_SIGNER_BIN:-/secure/oracle-patch-guard/bin}
if [[ -L "$SIGNER_BIN" || ! -d "$SIGNER_BIN" ]]; then
  printf 'OPG batch UNKNOWN: signer-bin ontbreekt of is een symlink: %s\n' "$SIGNER_BIN" >&2
  exit 70
fi
if ! SIGNER_BIN=$(cd -P -- "$SIGNER_BIN" 2>/dev/null && pwd -P); then
  printf 'OPG batch UNKNOWN: signer-bin kan niet veilig worden gecanonicaliseerd.\n' >&2
  exit 70
fi
LIST_PENDING=${SIGNER_BIN}/opg_list_pending.sh
APPROVE_RUN=${SIGNER_BIN}/opg_approve_run.sh

validate_program() {
  local path=$1 label=$2 mode
  if [[ -L "$path" || ! -f "$path" || ! -x "$path" ]]; then
    printf 'OPG batch UNKNOWN: %s ontbreekt, is geen executable of is een symlink: %s\n' \
      "$label" "$path" >&2
    return 1
  fi
  mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
    printf 'OPG batch UNKNOWN: %s is group/world-writable: %s\n' "$label" "$path" >&2
    return 1
  fi
}

validate_program "$LIST_PENDING" opg_list_pending.sh || exit 70
validate_program "$APPROVE_RUN" opg_approve_run.sh || exit 70

declare -a READY_LINES=() READY_RUNS=() SKIPPED_LINES=()
declare -A SEEN_RUNS=()

collect_snapshot() {
  local output line host sid cycle created status run_id reason
  READY_LINES=(); READY_RUNS=(); SKIPPED_LINES=(); SEEN_RUNS=()
  if ! output=$("$LIST_PENDING" --list --machine); then
    printf 'OPG batch UNKNOWN: statusinventarisatie is mislukt.\n' >&2
    return 70
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r host sid cycle created status run_id reason <<<"$line"
    if [[ -z "${host:-}" || -z "${sid:-}" || -z "${cycle:-}" ||
          -z "${created:-}" || -z "${status:-}" || -z "${run_id:-}" ||
          -z "${reason:-}" || ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ||
          -n "${SEEN_RUNS[$run_id]:-}" ]]; then
      printf 'OPG batch UNKNOWN: ongeldige of dubbele machine-statusregel.\n' >&2
      return 70
    fi
    SEEN_RUNS[$run_id]=1
    case $status in
      PENDING)
        READY_LINES+=("$host"$'\t'"$sid"$'\t'"$cycle"$'\t'"$status"$'\t'"$run_id")
        READY_RUNS+=("$run_id")
        ;;
      APPROVED|COMPLETE|UNKNOWN)
        SKIPPED_LINES+=("$host"$'\t'"$sid"$'\t'"$status"$'\t'"$reason"$'\t'"$run_id")
        ;;
      *)
        printf 'OPG batch UNKNOWN: onbekende status voor RUN_ID=%s.\n' "$run_id" >&2
        return 70
        ;;
    esac
  done <<<"$output"
}

show_ready() {
  local line host sid cycle status run_id
  printf 'READY FOR APPROVAL: %d\n\n' "${#READY_RUNS[@]}"
  printf '%-14s %-14s %-10s %-10s %s\n' HOST SID CYCLE STATUS RUN_ID
  for line in "${READY_LINES[@]}"; do
    IFS=$'\t' read -r host sid cycle status run_id <<<"$line"
    printf '%-14s %-14s %-10s %-10s %s\n' "$host" "$sid" "$cycle" "$status" "$run_id"
  done
}

show_skipped() {
  local line host sid status reason run_id
  printf '\nSKIPPED: %d\n\n' "${#SKIPPED_LINES[@]}"
  printf '%-14s %-14s %-10s %-32s %s\n' HOST SID STATUS REASON RUN_ID
  for line in "${SKIPPED_LINES[@]}"; do
    IFS=$'\t' read -r host sid status reason run_id <<<"$line"
    printf '%-14s %-14s %-10s %-32s %s\n' "$host" "$sid" "$status" "$reason" "$run_id"
  done
}

current_status() {
  local run_id=$1 output line host sid cycle created status found found_run reason
  if ! output=$("$LIST_PENDING" --list --machine --run-id "$run_id"); then
    return 70
  fi
  found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r host sid cycle created status found_run reason <<<"$line"
    [[ "$found_run" == "$run_id" ]] || return 70
    found=$((found + 1))
    CURRENT_STATUS=$status
    CURRENT_REASON=$reason
  done <<<"$output"
  [[ $found -eq 1 ]] || return 20
}

collect_snapshot || exit $?
show_ready

if [[ "$DO_ALL" != true ]]; then
  printf '\nGebruik opg_approve_run.sh RUN_ID voor één run, of eerst:\n'
  printf '  opg_approve_pending.sh --all --dry-run\n'
  printf '  opg_approve_pending.sh --all\n'
  (( ${#READY_RUNS[@]} > 0 )) && exit 0
  exit 20
fi

show_skipped
if (( ${#READY_RUNS[@]} == 0 )); then
  printf '\nGeen READY-runs gevonden; er is niets ondertekend.\n'
  exit 20
fi
if [[ "$DRY_RUN" == true ]]; then
  printf '\nDRY-RUN: geen signer aangeroepen en geen approval-artifacts geschreven.\n'
  exit 0
fi

printf '\nApprove all %d READY runs? [yes/no]: ' "${#READY_RUNS[@]}"
answer=
IFS= read -r answer || true
if [[ "$answer" != yes ]]; then
  printf 'Geannuleerd; er is niets ondertekend.\n'
  exit 0
fi

declare -a RESULT_LINES=()
approved_count=0
failed_count=0
runtime_skipped=0
for run_id in "${READY_RUNS[@]}"; do
  CURRENT_STATUS=UNKNOWN
  CURRENT_REASON='statushercontrole mislukt'
  current_status "$run_id"
  check_rc=$?
  if (( check_rc == 70 )); then
    printf 'OPG batch UNKNOWN: statushercontrole kon niet veilig worden uitgevoerd.\n' >&2
    exit 70
  fi
  if (( check_rc != 0 )) || [[ "$CURRENT_STATUS" != PENDING ]]; then
    runtime_skipped=$((runtime_skipped + 1))
    RESULT_LINES+=("$run_id"$'\t'"SKIPPED"$'\t'"status gewijzigd: $CURRENT_STATUS ($CURRENT_REASON)")
    continue
  fi

  "$APPROVE_RUN" "$run_id" </dev/null
  approve_rc=$?
  if (( approve_rc != 0 )); then
    failed_count=$((failed_count + 1))
    RESULT_LINES+=("$run_id"$'\t'"FAILED"$'\t'"opg_approve_run.sh rc=$approve_rc")
    continue
  fi

  CURRENT_STATUS=UNKNOWN
  CURRENT_REASON='post-signing verificatie mislukt'
  current_status "$run_id"
  check_rc=$?
  if (( check_rc == 0 )) && [[ "$CURRENT_STATUS" == APPROVED ]]; then
    approved_count=$((approved_count + 1))
    RESULT_LINES+=("$run_id"$'\t'"APPROVED"$'\t'"cryptografisch geverifieerd")
  else
    failed_count=$((failed_count + 1))
    RESULT_LINES+=("$run_id"$'\t'"FAILED"$'\t'"post-signing status: $CURRENT_STATUS ($CURRENT_REASON)")
  fi
done

printf '\nAPPROVAL SUMMARY\n\n'
printf 'APPROVED: %d\n' "$approved_count"
printf 'FAILED:   %d\n' "$failed_count"
printf 'SKIPPED:  %d\n\n' "$(( ${#SKIPPED_LINES[@]} + runtime_skipped ))"
for result in "${RESULT_LINES[@]}"; do
  IFS=$'\t' read -r run_id result_status result_reason <<<"$result"
  printf '%s  %-9s  %s\n' "$run_id" "$result_status" "$result_reason"
done

if (( failed_count > 0 || runtime_skipped > 0 )); then
  exit 30
fi
exit 0
