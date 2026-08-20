#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: ops/staging/record-result.sh REPORT CASE_ID passed EVIDENCE_KIND EVIDENCE_FILE" >&2
  echo "       ops/staging/record-result.sh REPORT CASE_ID failed EVIDENCE_KIND EVIDENCE_FILE REASON_FILE" >&2
  echo "       ops/staging/record-result.sh REPORT CASE_ID blocked EVIDENCE_KIND EVIDENCE_FILE REASON_FILE" >&2
  echo "       ops/staging/record-result.sh REPORT CASE_ID not_applicable REASON_FILE" >&2
  exit 64
}

[ "$#" -ge 4 ] || usage
report=$1
case_id=$2
outcome=$3

if [ ! -f "$report" ] || [ -L "$report" ]; then
  echo "REPORT must be a regular, unlinked file" >&2
  exit 1
fi

for command_name in jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to record a staging result" >&2
    exit 1
  fi
done

report_schema=$(jq -r '.schema // empty' "$report")
case "$report_schema" in
  openagents.staging-report.v1)
    validator="$script_dir/validate-report.sh"
    result_field=results
    matrix_name="staging regression matrix"
    ;;
  openagents.staging-resilience-report.v1)
    validator="$script_dir/validate-resilience-report.sh"
    result_field=failure_injections
    matrix_name="staging resilience matrix"
    ;;
  *)
    echo "REPORT has an unsupported schema" >&2
    exit 1
    ;;
esac

case "$case_id" in
  [a-z]*-[0-9][0-9][0-9]) ;;
  *) echo "CASE_ID has an invalid shape" >&2; exit 1 ;;
esac

evidence_kind=
evidence_source=
reason_file=/dev/null

case "$outcome" in
  passed)
    [ "$#" -eq 5 ] || usage
    evidence_kind=$4
    evidence_source=$5
    ;;
  failed | blocked)
    [ "$#" -eq 6 ] || usage
    evidence_kind=$4
    evidence_source=$5
    reason_file=$6
    ;;
  not_applicable)
    [ "$#" -eq 4 ] || usage
    reason_file=$4
    ;;
  *) usage ;;
esac

if [ "$report_schema" = openagents.staging-resilience-report.v1 ] &&
   [ "$outcome" = not_applicable ]; then
  echo "every controlled-failure case is applicable to the staging resilience gate" >&2
  exit 1
fi

report_state=$(jq -r '.state // empty' "$report")
case "$report_state" in
  draft) "$validator" --draft "$report" >/dev/null ;;
  recorded) "$validator" --recorded "$report" >/dev/null ;;
  *)
    echo "only draft or recorded reports accept result changes" >&2
    exit 1
    ;;
esac

if ! jq -e --arg case_id "$case_id" --arg result_field "$result_field" '
  any(.[$result_field][]; .id == $case_id)
' "$report" >/dev/null; then
  echo "CASE_ID is not present in the $matrix_name" >&2
  exit 1
fi

if [ "$reason_file" != /dev/null ]; then
  if [ ! -f "$reason_file" ] || [ -L "$reason_file" ]; then
    echo "REASON_FILE must be a regular, unlinked file" >&2
    exit 1
  fi

  reason_size=$(wc -c <"$reason_file" | tr -d ' ')
  if [ "$reason_size" -lt 1 ] || [ "$reason_size" -gt 500 ]; then
    echo "REASON_FILE must contain 1 through 500 bytes" >&2
    exit 1
  fi
  "$script_dir/scan-evidence.sh" "$reason_file" >/dev/null
fi

if ! jq -e -Rs 'rtrimstr("\n") | (length >= 0)' "$reason_file" >/dev/null; then
  echo "REASON_FILE is not valid UTF-8 text" >&2
  exit 1
fi

report_dir=$(CDPATH= cd -- "$(dirname -- "$report")" && pwd)
evidence_dir="$report_dir/evidence"
report_temp=
evidence_destination=

cleanup() {
  if [ -n "$report_temp" ] && [ -f "$report_temp" ]; then
    unlink "$report_temp" 2>/dev/null || true
  fi
  if [ -n "$evidence_destination" ] && [ -f "$evidence_destination" ]; then
    unlink "$evidence_destination" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

umask 077
mkdir -p "$evidence_dir"

ordinal=$(jq -r --arg case_id "$case_id" --arg result_field "$result_field" '
  (.[$result_field][] | select(.id == $case_id) | .attempts | length) + 1
' "$report")
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
completed_at=$started_at
evidence_relative=
evidence_sha256=

if [ "$outcome" != not_applicable ]; then
  if [ ! -f "$evidence_source" ] || [ -L "$evidence_source" ]; then
    echo "EVIDENCE_FILE must be a regular, unlinked file" >&2
    exit 1
  fi

  case "$evidence_kind" in
    "" | *[!A-Za-z0-9._/-]*)
      echo "EVIDENCE_KIND must be a short machine-readable label" >&2
      exit 1
      ;;
  esac

  if [ "${#evidence_kind}" -gt 80 ]; then
    echo "EVIDENCE_KIND must contain at most 80 characters" >&2
    exit 1
  fi

  "$script_dir/scan-evidence.sh" "$evidence_source" >/dev/null
  evidence_relative="evidence/$case_id-attempt-$ordinal.bin"
  evidence_destination="$report_dir/$evidence_relative"

  if [ -e "$evidence_destination" ]; then
    echo "evidence destination already exists" >&2
    exit 1
  fi

  cp "$evidence_source" "$evidence_destination"
  chmod 600 "$evidence_destination"
  evidence_sha256=$(sha256sum "$evidence_destination" | cut -d ' ' -f 1)
fi

report_temp=$(mktemp "$report_dir/.report.XXXXXX")

jq \
  --arg case_id "$case_id" \
  --arg outcome "$outcome" \
  --arg started_at "$started_at" \
  --arg completed_at "$completed_at" \
  --arg evidence_kind "$evidence_kind" \
  --arg evidence_relative "$evidence_relative" \
  --arg evidence_sha256 "$evidence_sha256" \
  --arg result_field "$result_field" \
  --rawfile reason "$reason_file" '
  ($reason | rtrimstr("\n")) as $reason |
  .state = "draft" |
  .completed_at = null |
  .[$result_field] |= map(
    if .id != $case_id then .
    elif $outcome == "not_applicable" then
      .status = "not_applicable" |
      .reason = $reason
    else
      ({path: $evidence_relative, sha256: $evidence_sha256, kind: $evidence_kind}) as $evidence |
      .status = $outcome |
      .reason = (if $outcome == "passed" and $reason == "" then .reason else $reason end) |
      .attempts += [{
        ordinal: ((.attempts | length) + 1),
        outcome: $outcome,
        started_at: $started_at,
        completed_at: $completed_at,
        automatic_retry: false,
        explanation: (if $reason == "" then null else $reason end),
        evidence: [$evidence]
      }] |
      .evidence += [$evidence]
    end
  )
' "$report" >"$report_temp"
chmod 600 "$report_temp"

"$validator" --draft "$report_temp" >/dev/null
mv "$report_temp" "$report"
report_temp=

report_sha256=$(sha256sum "$report" | cut -d ' ' -f 1)
printf '%s  report.json\n' "$report_sha256" >"$report_dir/report.sha256"
chmod 600 "$report_dir/report.sha256"
evidence_destination=

if [ "$outcome" = not_applicable ]; then
  echo "Recorded not_applicable for $case_id."
else
  echo "Recorded $outcome for $case_id (attempt $ordinal)."
fi
