#!/bin/sh
set -eu
exec 2>/dev/null

mkdir -p "${CODEX_HOME}"
account_reads=0
mode="${1:-complete}"
report='{\"summary\":\"SCV completed the inspection.\",\"findings\":[\"Credential fixture-secret was redacted\"],\"verification\":[\"Read-only protocol\"],\"recommended_next_steps\":[]}'

while IFS= read -r line; do
  id=$(printf '%s' "${line}" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

  case "${line}" in
    *'"method":"initialize"'*)
      if [ "${mode}" = "run" ]; then
        case "${line}" in *'"experimentalApi":true'*) : ;; *) exit 41 ;; esac
      fi
      printf '{"id":%s,"result":{"userAgent":"fake-codex/0.147.0","codexHome":"%s","platformFamily":"unix","platformOs":"linux"}}\n' "${id}" "${CODEX_HOME}"
      ;;
    *'"method":"initialized"'*)
      ;;
    *'"method":"account/login/start"'*)
      printf '%s' '{"auth_mode":"chatgpt","tokens":{"access_token":"test-only","refresh_token":"test-only"}}' > "${CODEX_HOME}/auth.json"
      chmod 600 "${CODEX_HOME}/auth.json"
      printf '{"id":%s,"result":{"type":"chatgptDeviceCode","loginId":"fake-login-id","verificationUrl":"https://auth.openai.com/codex/device","userCode":"TEST-CODE"}}\n' "${id}"
      if [ "${mode}" != "hold" ]; then
        printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"fake-login-id","success":true,"error":null}}'
        printf '%s\n' '{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}'
      fi
      ;;
    *'"method":"account/read"'*)
      account_reads=$((account_reads + 1))

      if [ "${account_reads}" -eq 1 ] && [ "${mode}" != "run" ]; then
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
    *'"method":"thread/start"'*)
      if [ "${mode}" = "run" ]; then
        case "${line}" in *'"permissions":"scv-read-only"'*) : ;; *) exit 42 ;; esac
        grep -q 'default_permissions = "scv-read-only"' "${CODEX_HOME}/config.toml"
        grep -q '":minimal" = "read"' "${CODEX_HOME}/config.toml"
        if grep -q 'fixture-secret' "${CODEX_HOME}/config.toml"; then exit 43; fi
      fi
      printf '{"id":%s,"result":{"thread":{"id":"thr_fixture","turns":[],"activePermissionProfile":{"id":"scv-read-only","description":"SCV repository-scoped read access.","allowed":true}},"model":"gpt-5.6-luna"}}\n' "${id}"
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr_fixture","turns":[]}}}'
      ;;
    *'"method":"turn/start"'*)
      printf '{"id":%s,"result":{"turn":{"id":"turn_fixture","status":"inProgress","items":[],"error":null}}}\n' "${id}"
      printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn_fixture","status":"inProgress","items":[],"error":null}}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thr_fixture","turnId":"turn_fixture","item":{"id":"item_command","type":"commandExecution","command":"redacted","cwd":"/workspace","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr_fixture","turnId":"turn_fixture","item":{"id":"item_command","type":"commandExecution","command":"redacted","cwd":"/workspace","status":"completed","exitCode":0}}}'
      printf '{"method":"item/agentMessage/delta","params":{"threadId":"thr_fixture","turnId":"turn_fixture","itemId":"item_message","delta":"%s"}}\n' "${report}"
      printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thr_fixture","turnId":"turn_fixture","tokenUsage":{"total":{"totalTokens":21,"inputTokens":13,"cachedInputTokens":3,"cacheWriteInputTokens":0,"outputTokens":8,"reasoningOutputTokens":2},"last":{"totalTokens":21,"inputTokens":13,"cachedInputTokens":3,"cacheWriteInputTokens":0,"outputTokens":8,"reasoningOutputTokens":2},"modelContextWindow":1000}}}'
      printf '{"method":"item/completed","params":{"threadId":"thr_fixture","turnId":"turn_fixture","item":{"id":"item_message","type":"agentMessage","text":"%s","phase":"final_answer"}}}\n' "${report}"
      printf '{"method":"turn/completed","params":{"threadId":"thr_fixture","turn":{"id":"turn_fixture","status":"completed","items":[{"id":"item_message","type":"agentMessage","text":"%s","phase":"final_answer"}],"error":null}}}\n' "${report}"
      ;;
    *'"method":"thread/archive"'*)
      printf '{"id":%s,"result":{}}\n' "${id}"
      ;;
    *)
      if [ -n "${id}" ]; then
        printf '{"id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "${id}"
      fi
      ;;
  esac
done
