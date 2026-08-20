#!/bin/sh
set -eu
exec 2>/dev/null

mkdir -p "${CODEX_HOME}"
account_reads=0

while IFS= read -r line; do
  id=$(printf '%s' "${line}" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

  case "${line}" in
    *'"method":"initialize"'*)
      printf '{"id":%s,"result":{"userAgent":"fake-codex/0.147.0","codexHome":"%s","platformFamily":"unix","platformOs":"linux"}}\n' "${id}" "${CODEX_HOME}"
      ;;
    *'"method":"initialized"'*)
      ;;
    *'"method":"account/login/start"'*)
      printf '%s' '{"auth_mode":"chatgpt","tokens":{"access_token":"test-only","refresh_token":"test-only"}}' > "${CODEX_HOME}/auth.json"
      chmod 600 "${CODEX_HOME}/auth.json"
      printf '{"id":%s,"result":{"type":"chatgptDeviceCode","loginId":"fake-login-id","verificationUrl":"https://auth.openai.com/codex/device","userCode":"TEST-CODE"}}\n' "${id}"
      printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"fake-login-id","success":true,"error":null}}'
      printf '%s\n' '{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}'
      ;;
    *'"method":"account/read"'*)
      account_reads=$((account_reads + 1))

      if [ "${account_reads}" -eq 1 ]; then
        printf '{"id":%s,"result":{"account":null,"requiresOpenaiAuth":true}}\n' "${id}"
      else
        printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"operator@example.test","planType":"plus"},"requiresOpenaiAuth":true}}\n' "${id}"
      fi
      ;;
    *'"method":"model/list"'*)
      printf '{"id":%s,"result":{"data":[{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","supportedReasoningEfforts":[{"reasoningEffort":"none","description":"None"},{"reasoningEffort":"low","description":"Low"}]}],"nextCursor":null}}\n' "${id}"
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null,"rateLimitReachedType":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}\n' "${id}"
      ;;
    *'"method":"account/login/cancel"'*)
      printf '{"id":%s,"result":{"status":"canceled"}}\n' "${id}"
      ;;
    *)
      if [ -n "${id}" ]; then
        printf '{"id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "${id}"
      fi
      ;;
  esac
done
