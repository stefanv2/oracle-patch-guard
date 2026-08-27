#!/usr/bin/env bash
# Verzamel gekopieerde run-directories tot één machineleesbaar batchrapport.
set -u
set -o pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() { printf 'Gebruik: oem_collect_results.sh OUTPUT_DIR RUN_DIR [RUN_DIR ...]\n' >&2; }
[[ $# -ge 2 ]] || { usage; exit 70; }
OUTPUT_DIR=$1; shift
[[ "$OUTPUT_DIR" == /* ]] || { usage; exit 70; }
mkdir -p -- "$OUTPUT_DIR" || exit 20
CSV="${OUTPUT_DIR}/oem_batch_report.csv"; MD="${OUTPUT_DIR}/oem_batch_report.md"
printf 'Host,Oracle Home,Databases,Oude RU,Nieuwe RU,Assessmentstatus,Uitvoeringsstatus,Mislukte fase,Datapatchstatus per database,Starttijd,Eindtijd,Downtime,Handmatige actie vereist\n' >"$CSV"
printf '# OEM Oracle Patch Guard batchrapport\n\n| Host | Oracle Home | Databases | Nieuwe RU | Assessment | Uitvoering | Fase | Datapatch | Handmatig |\n|---|---|---|---|---|---|---|---|---|\n' >"$MD"
failures=0
for run_dir in "$@"; do
  [[ "$run_dir" == /* && -r "$run_dir/execution_state.json" && -r "$run_dir/patch_manifest.json" ]] || { failures=$((failures + 1)); continue; }
  json_string() { awk -v k="\"$2\"" 'index($0,k){x=$0;sub(".*"k"[[:space:]]*:[[:space:]]*\"","",x);sub("\".*","",x);print x;exit}' "$1"; }
  host=$(json_string "$run_dir/execution_state.json" hostname)
  home=$(json_string "$run_dir/execution_state.json" target_oracle_home)
  state=$(json_string "$run_dir/execution_state.json" state)
  phase=$(json_string "$run_dir/execution_state.json" phase)
  ru=$(json_string "$run_dir/patch_manifest.json" db_patch)
  assessment=$(json_string "$run_dir/assessment.json" status)
  databases=$(awk -F, 'NR>1{gsub(/"/,"",$1);a=a (a?";":"") $1}END{print a}' "$run_dir/database_state_before.csv")
  datapatch=$(for sid in ${databases//;/ }; do
    if [[ ! -r "$run_dir/datapatch_${sid}.log" ]]; then printf '%s=NOT_RUN;' "$sid"
    elif grep -Eiq 'ORA-|SP2-|failed|with errors' "$run_dir/datapatch_${sid}.log"; then printf '%s=FAILED;' "$sid"
    else printf '%s=COMPLETE;' "$sid"; fi
  done)
  manual=false; [[ "$state" == MANUAL_INTERVENTION_REQUIRED || "$state" == PARTIAL ]] && manual=true
  start=$(awk -F'|' 'NR==1{print $1}' "$run_dir/state_history.log")
  end=$(awk -F'|' 'END{print $1}' "$run_dir/state_history.log")
  old_ru=$(grep -Ei 'Database Release Update|Release_Update' "$run_dir/inventory_before.txt" 2>/dev/null | tail -1 | tr ',' ';')
  stopped=$(awk -F'|' '$3=="05_DATABASES_STOPPED"{print $1;exit}' "$run_dir/state_history.log")
  started=$(awk -F'|' '$3=="08_DATABASES_STARTED"{print $1;exit}' "$run_dir/state_history.log")
  downtime=UNKNOWN
  if [[ -n "$stopped" && -n "$started" ]] && date -d "$stopped" +%s >/dev/null 2>&1; then
    downtime="$(( $(date -d "$started" +%s) - $(date -d "$stopped" +%s) ))s"
  fi
  printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' "$host" "$home" "$databases" "$old_ru" "$ru" "$assessment" "$state" "$phase" "$datapatch" "$start" "$end" "$downtime" "$manual" >>"$CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$host" "$home" "$databases" "$ru" "$assessment" "$state" "$phase" "$datapatch" "$manual" >>"$MD"
  [[ "$state" == 12_COMPLETE ]] || failures=$((failures + 1))
done
printf 'OPG_BATCH_RESULT|runs=%s|failures=%s|report=%s\n' "$#" "$failures" "$CSV"
(( failures == 0 )) && exit 0 || exit 40
