#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base_url=https://staging.openagents.com
mode=${1:-}

usage() {
  echo "usage: ops/staging/run-public-smoke.sh check" >&2
  echo "       ops/staging/run-public-smoke.sh --run CANDIDATE_DIRECTORY OUTPUT" >&2
  exit 64
}

for command_name in curl jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to run the public staging smoke" >&2
    exit 1
  fi
done

if [ "$mode" = "check" ]; then
  [ "$#" -eq 1 ] || usage
  echo "Public staging smoke preflight passed (no network requests sent)."
  exit 0
fi

[ "$mode" = "--run" ] && [ "$#" -eq 3 ] || usage
candidate_dir=$2
output=$3
candidate_manifest="$candidate_dir/candidate-manifest.json"
candidate_checksum="$candidate_dir/candidate-manifest.sha256"

if [ -e "$output" ]; then
  echo "public smoke output already exists" >&2
  exit 1
fi

if [ ! -f "$candidate_manifest" ] || [ ! -f "$candidate_checksum" ]; then
  echo "candidate directory must contain the manifest and its checksum" >&2
  exit 1
fi

(cd "$candidate_dir" && sha256sum --check --strict candidate-manifest.sha256 >/dev/null)

jq -e --arg base_url "$base_url" '
  . as $manifest |
  .schema == "openagents.staging-candidate.v1" and
  (.git_sha | test("^[0-9a-f]{40}$")) and
  .branch == "main" and
  .target.environment == "staging" and
  (.target.project | test("stag"; "i")) and
  (.images.application.manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
  (.images.application.reference | endswith("@" + $manifest.images.application.manifest_digest)) and
  $base_url == "https://staging.openagents.com"
' "$candidate_manifest" >/dev/null || {
  echo "candidate manifest does not satisfy the public staging smoke contract" >&2
  exit 1
}

git_sha=$(jq -r '.git_sha' "$candidate_manifest")
image_digest=$(jq -r '.images.application.manifest_digest' "$candidate_manifest")
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
output_parent=$(dirname -- "$output")

if [ ! -d "$output_parent" ]; then
  echo "public smoke output directory does not exist" >&2
  exit 1
fi

umask 077
smoke_root=$(mktemp -d /tmp/openagents-public-smoke.XXXXXX)
checks="$smoke_root/checks.jsonl"
: >"$checks"
overall=passed

cleanup() {
  find "$smoke_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

record_check() {
  case_id=$1
  path=$2
  expected_kind=$3
  body="$smoke_root/body"
  headers="$smoke_root/headers"
  curl_error="$smoke_root/curl-error"
  : >"$body"
  : >"$headers"
  : >"$curl_error"

  request_ok=true
  if status_code=$(curl -q -sS \
      --proto '=https' \
      --tlsv1.2 \
      --connect-timeout 10 \
      --max-time 30 \
      --output "$body" \
      --dump-header "$headers" \
      --write-out '%{http_code}' \
      "$base_url$path" 2>"$curl_error"); then
    :
  else
    request_ok=false
    status_code=000
  fi

  content_type=$(grep -i '^content-type:' "$headers" 2>/dev/null | tail -n 1 | cut -d ':' -f 2- | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  body_size=$(wc -c <"$body" | tr -d ' ')
  body_sha256=$(sha256sum "$body" | cut -d ' ' -f 1)
  headers_sha256=$(sha256sum "$headers" | cut -d ' ' -f 1)
  semantic_ok=false

  if [ "$request_ok" = true ] && [ "$status_code" = 200 ]; then
    case "$expected_kind" in
      json)
        if printf '%s' "$content_type" | grep -Eiq '^application/json([[:space:]]*;|$)' &&
           jq -e --arg git_sha "$git_sha" '
             .status == "ok" and .revision == $git_sha
           ' "$body" >/dev/null 2>&1; then
          semantic_ok=true
        fi
        ;;
      html)
        if printf '%s' "$content_type" | grep -Eiq '^text/html([[:space:]]*;|$)' &&
           [ "$body_size" -gt 0 ]; then
          semantic_ok=true
        fi
        ;;
      binary)
        if [ "$body_size" -gt 0 ]; then
          semantic_ok=true
        fi
        ;;
    esac
  fi

  csp_present=false
  permissions_policy_present=false
  nonce_bound=false
  if [ "$path" = "/" ]; then
    if grep -Eiq '^content-security-policy:' "$headers" &&
       grep -Eiq "^content-security-policy:.*default-src 'self'.*script-src 'self' 'nonce-[A-Za-z0-9_-]+'" "$headers"; then
      csp_present=true
    fi
    if grep -Eiq '^permissions-policy:[[:space:]]*microphone=\(self\)' "$headers"; then
      permissions_policy_present=true
    fi

    header_nonce=$(sed -n "s/^content-security-policy:.*script-src 'self' 'nonce-\([A-Za-z0-9_-]*\)'.*/\1/ip" "$headers" | tail -n 1)
    if [ -n "$header_nonce" ] && grep -Fq "nonce=\"$header_nonce\"" "$body"; then
      nonce_bound=true
    fi

    if [ "$csp_present" != true ] || [ "$permissions_policy_present" != true ] || [ "$nonce_bound" != true ]; then
      semantic_ok=false
    fi
  fi

  if [ "$semantic_ok" != true ]; then
    overall=failed
  fi

  jq -cn \
    --arg case_id "$case_id" \
    --arg path "$path" \
    --arg expected_kind "$expected_kind" \
    --arg status_code "$status_code" \
    --arg content_type "$content_type" \
    --argjson body_size "$body_size" \
    --arg body_sha256 "$body_sha256" \
    --arg headers_sha256 "$headers_sha256" \
    --argjson request_ok "$request_ok" \
    --argjson semantic_ok "$semantic_ok" \
    --argjson csp_present "$csp_present" \
    --argjson permissions_policy_present "$permissions_policy_present" \
    --argjson nonce_bound "$nonce_bound" '
    {
      case_id: $case_id,
      path: $path,
      expected_kind: $expected_kind,
      status_code: ($status_code | tonumber),
      content_type: $content_type,
      body_bytes: $body_size,
      body_sha256: $body_sha256,
      response_headers_sha256: $headers_sha256,
      request_ok: $request_ok,
      semantic_ok: $semantic_ok,
      browser_policy: (if $path == "/" then {
        csp_present: $csp_present,
        permissions_policy_present: $permissions_policy_present,
        response_nonce_bound_to_theme_bootstrap: $nonce_bound
      } else null end)
    }
  ' >>"$checks"
}

record_check public-001 /healthz json
record_check public-001 /status json
record_check public-001 /api/status json
record_check public-001 /favicon.ico binary
record_check public-002 / html
record_check public-002 /leaderboard html
record_check public-002 /changelog html
record_check public-002 /docs html
record_check public-002 /components html

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
candidate_manifest_sha256=$(sha256sum "$candidate_manifest" | cut -d ' ' -f 1)
temporary_output="$smoke_root/public-smoke.json"

jq -s \
  --arg git_sha "$git_sha" \
  --arg image_digest "$image_digest" \
  --arg candidate_manifest_sha256 "$candidate_manifest_sha256" \
  --arg base_url "$base_url" \
  --arg started_at "$started_at" \
  --arg completed_at "$completed_at" \
  --arg outcome "$overall" '
  {
    schema: "openagents.staging-public-smoke.v1",
    target: {environment: "staging", base_url: $base_url},
    candidate: {
      git_sha: $git_sha,
      application_manifest_digest: $image_digest,
      candidate_manifest_sha256: $candidate_manifest_sha256
    },
    started_at: $started_at,
    completed_at: $completed_at,
    outcome: $outcome,
    content_retained: false,
    checks: .
  }
' "$checks" >"$temporary_output"

"$script_dir/scan-evidence.sh" "$temporary_output" >/dev/null
mv "$temporary_output" "$output"
chmod 600 "$output"

if [ "$overall" != passed ]; then
  echo "Public staging smoke failed; review the content-free receipt: $output" >&2
  exit 1
fi

echo "Public staging smoke passed: $output"
