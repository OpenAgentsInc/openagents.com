#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: ops/staging/scan-evidence.sh FILE..." >&2
  exit 64
fi

for command_name in grep strings; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to scan staging evidence" >&2
    exit 1
  fi
done

scan_file() {
  file=$1

  if [ ! -f "$file" ]; then
    echo "evidence path is not a regular file: $file" >&2
    return 1
  fi

  size=$(wc -c <"$file" | tr -d ' ')
  if [ "$size" -gt 52428800 ]; then
    echo "evidence file exceeds the 50 MiB review bound: $file" >&2
    return 1
  fi

  scan_root=$(mktemp -d /tmp/openagents-evidence-scan.XXXXXX)
  scan_text="$scan_root/content"

  cleanup_scan() {
    find "$scan_root" -depth -delete 2>/dev/null || true
  }
  trap cleanup_scan EXIT INT TERM

  if grep -Iq . "$file" 2>/dev/null; then
    cp "$file" "$scan_text"
  else
    strings -a "$file" >"$scan_text"
  fi

  refuse_pattern() {
    label=$1
    pattern=$2

    if LC_ALL=C grep -Eiq -- "$pattern" "$scan_text"; then
      echo "evidence safety scan found $label in $file" >&2
      return 1
    fi
  }

  refuse_pattern "a private key" '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
  refuse_pattern "an OpenAI-style credential" '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}'
  refuse_pattern "a GitHub credential" '(^|[^A-Za-z0-9])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
  refuse_pattern "a bearer credential" '(^|[^A-Za-z0-9])Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}'
  refuse_pattern "a machine credential" '(^|[^A-Za-z0-9])smct_[A-Za-z0-9_-]{16,}'
  refuse_pattern "an authenticated database URL" '(ecto|postgres|postgresql)://[^/@[:space:]]+:[^/@[:space:]]+@'
  refuse_pattern "a browser session value" '(_openagents[^=[:space:]]*|_csrf_token|session(_id)?)[[:space:]]*=[[:space:]]*[^;[:space:]]{12,}'
  refuse_pattern "a credential-bearing URL query" '[?&](code|token|access_token|refresh_token|key|secret)=[^&[:space:]]{8,}'
  refuse_pattern "a private product payload key" '"(prompt|transcript|memory_value|memory_content|audio_base64|sdp|oauth_code|access_token|refresh_token|database_password|release_cookie)"[[:space:]]*:'

  cleanup_scan
  trap - EXIT INT TERM
}

for evidence_file in "$@"; do
  scan_file "$evidence_file"
done

echo "Staging evidence safety scan passed ($# files)."
