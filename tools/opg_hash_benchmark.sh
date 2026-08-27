#!/usr/bin/env bash
# Read-only benchmark for Pilot07 media trees. Never drops caches or changes mounts.
set -u
set -o pipefail
umask 077
export LC_ALL=C

usage() { printf 'Gebruik: %s TREE_ROOT [LABEL]\n' "${0##*/}" >&2; exit 70; }
[[ $# -ge 1 && $# -le 2 ]] || usage
ROOT=$1 LABEL=${2:-tree}
[[ "$ROOT" == /* && -d "$ROOT" && ! -L "$ROOT" ]] || { printf 'Ongeldige absolute tree-root.\n' >&2; exit 20; }
ROOT=$(cd -P -- "$ROOT" && pwd -P) || exit 20
TMP=$(mktemp "${TMPDIR:-/tmp}/opg-benchmark.XXXXXX") || exit 30
trap 'rm -f -- "$TMP" "$TMP.hashes"' EXIT

now_ns() { date +%s%N; }
emit_timing() {
  local metric=$1 started=$2 ended=$3
  printf 'OPG_HASH_BENCHMARK|label=%s|metric=%s|duration_ms=%s\n' "$LABEL" "$metric" "$(((ended-started)/1000000))"
}

start=$(now_ns)
if ! find "$ROOT" -xdev -type f -printf '%P\0' | sort -z >"$TMP"; then exit 30; fi
end=$(now_ns); emit_timing metadata_walk_sort "$start" "$end"
files=$(tr -cd '\0' <"$TMP" | wc -c)
bytes=$(find "$ROOT" -xdev -type f -printf '%s\n' | awk '{n+=$1} END{printf "%.0f",n+0}')
printf 'OPG_HASH_BENCHMARK|label=%s|files=%s|bytes=%s|filesystem=%s\n' "$LABEL" "$files" "$bytes" "$(stat -f -c %T "$ROOT")"

start=$(now_ns)
while IFS= read -r -d '' relative; do
  [[ -f "$ROOT/$relative" && ! -L "$ROOT/$relative" ]] || exit 20
  dd if="$ROOT/$relative" of=/dev/null bs=1M status=none || exit 30
done <"$TMP"
end=$(now_ns); emit_timing sequential_read "$start" "$end"

start=$(now_ns)
: >"$TMP.hashes"
while IFS= read -r -d '' relative; do
  hash=$(sha256sum -- "$ROOT/$relative") || exit 30
  printf '%s\0%s\0' "${hash%% *}" "$relative" >>"$TMP.hashes"
done <"$TMP"
v2_like=$(sha256sum "$TMP.hashes" | awk '{print $1}')
end=$(now_ns); emit_timing per_file_sha256 "$start" "$end"
printf 'OPG_HASH_BENCHMARK|label=%s|diagnostic_list_sha256=%s\n' "$LABEL" "$v2_like"

printf 'OPG_HASH_BENCHMARK|note=run_at_least_three_times_and_label_first_run_cold-ish_following_runs_warm\n'
