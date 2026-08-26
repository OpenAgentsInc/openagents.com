#!/bin/bash
set -euo pipefail

PROJECT="openagentsgemini"
IMAGE="us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents@__IMAGE_DIGEST__"
IMAGE_DIGEST="__IMAGE_DIGEST__"
BUILDER_IMAGE="us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents-builder@sha256:a22efc993ab6a60c0d1c1069f6f07bc33f262662ce8f22d13cbcac0ef83aa0c2"
META="http://metadata.google.internal/computeMetadata/v1"
HEADER="Metadata-Flavor: Google"

export DOCKER_CONFIG=/tmp/dockercfg
mkdir -p "$DOCKER_CONFIG"

TOKEN=$(curl -fsS -H "$HEADER" "$META/instance/service-accounts/default/token" | sed -n 's/.*"access_token": *"\([^"]*\)".*/\1/p')
IP=$(curl -fsS -H "$HEADER" "$META/instance/network-interfaces/0/ip")

for range in 10.128.0.0/9 130.211.0.0/22 35.191.0.0/16; do
  if [ "$range" = "10.128.0.0/9" ]; then
    iptables -C INPUT -s "$range" -p tcp -m multiport --dports 4369,8080,9100:9115 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$range" -p tcp -m multiport --dports 4369,8080,9100:9115 -j ACCEPT
  else
    iptables -C INPUT -s "$range" -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$range" -p tcp --dport 8080 -j ACCEPT
  fi
done

printf '%s' "$TOKEN" | docker login -u oauth2accesstoken --password-stdin https://us-central1-docker.pkg.dev >/dev/null

secret() {
  curl -fsS -H "Authorization: Bearer $TOKEN" \
    "https://secretmanager.googleapis.com/v1/projects/$PROJECT/secrets/$1/versions/latest:access" |
    sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d
}

export SECRET_KEY_BASE="$(secret sarah-secret-key-base)"
DB_PASSWORD="$(secret sarah-postgres-password)"
export OPENAI_API_KEY="$(secret sarah-openai-api-key)"
export GITHUB_CLIENT_ID="$(secret sarah-production-github-client-id)"
export GITHUB_CLIENT_SECRET="$(secret sarah-production-github-client-secret)"
export GITHUB_TOKEN_ENCRYPTION_KEY="$(secret sarah-production-github-token-encryption-key-reserved)"
export VOICE_RECORDING_ENCRYPTION_KEY="$(secret sarah-production-voice-recording-key)"
# The pairing vault's own key (VAULT-001, issues #192 and #253). Until this
# was set, runtime.exs bridged the pairing vault to the GitHub vault's key,
# so two vaults sealed under one key and a GitHub rotation silently moved
# the pairing vault too. The bridge was meant to last one deploy.
export MACHINE_TOKEN_ENCRYPTION_KEY="$(secret openagents-machine-token-encryption-key)"
# The content vault's own key (VAULT-001, issue #193). It seals voice
# transcripts, in-call compaction summaries, preference observations, and
# project notes. Nothing bridges to it and nothing bridges from it: an
# unset value refuses the boot rather than borrowing another vault's key.
export CONTENT_ENCRYPTION_KEY="$(secret openagents-content-encryption-key)"
export RELEASE_COOKIE="$(secret sarah-release-cookie)"
export OPENAGENTS_FORGE_OPERATOR_TOKEN="$(secret sarah-forge-operator-token)"
export OPENAGENTS_POSTHOG_PROJECT_TOKEN="$(secret openagents-posthog-project-token)"
export OPENROUTER_API_KEY="$(secret openagents-openrouter-api-key)"
export BOX_API_KEY="$(secret openagents-box-api-key)"
export GEMINI_API_KEY="$(secret openagents-gemini-api-key)"
export AI_GATEWAY_API_KEY="$(secret openagents-vercel-gateway-api-key)"

export DATABASE_URL="ecto://sarah_app:${DB_PASSWORD}@127.0.0.1:5432/sarah"
export DNS_CLUSTER_QUERY="sarah.fleet.internal"
export GITHUB_OAUTH_SCOPES="repo,read:org"
export GITHUB_REDIRECT_URI="https://openagents.com/auth/github/callback"
export GITHUB_TOKEN_DECRYPTION_KEYS_JSON="{}"
export GITHUB_TOKEN_ENCRYPTION_KEY_ID="production-legacy-v1"
export OPENAGENTS_ADMIN_GITHUB_IDS="14167547"
export OPENAGENTS_ALLOWED_ORIGINS="https://openagents.com,https://www.openagents.com,https://fleet.openagents.com"
export OPENAGENTS_CODING_JOBS_DIR="/var/lib/openagents/workspace/coding-jobs"
export OPENAGENTS_DATABASE_IPV6="false"
export OPENAGENTS_DATABASE_MODE="url"
export OPENAGENTS_DIST_PORT_MAX="9115"
export OPENAGENTS_DIST_PORT_MIN="9100"
export OPENAGENTS_ENVIRONMENT="production"
export OPENAGENTS_FEATURE_BOOT_CONVERGENCE="true"
export OPENAGENTS_FEATURE_COMPUTERS="true"
export OPENAGENTS_FEATURE_CONVERSATION_RESET="false"
export OPENAGENTS_FEATURE_DEPLOYMENT_CONTROL_PLANE="false"
export OPENAGENTS_FEATURE_EXPERIENCE_MEMORY="true"
export OPENAGENTS_FEATURE_FORGE="true"
export OPENAGENTS_FEATURE_FORGE_DEPLOY="true"
export OPENAGENTS_FEATURE_GRAPH_MEMORY="true"
export OPENAGENTS_FEATURE_HORDE="true"
export OPENAGENTS_FEATURE_INCIDENT_FIXER="false"
# The embedding rail for cloud memories (MEMORY-010). Off for this first
# deploy: recall falls back to the lexical stand-in, which keeps the plane
# working without putting a provider call on the responses hot path before
# anyone has watched it under load. Flip it once that's observed.
export OPENAGENTS_FEATURE_MEMORY_EMBEDDINGS="false"
export OPENAGENTS_FEATURE_MEMORY_PORTABILITY="true"
export OPENAGENTS_FEATURE_RA="false"
export OPENAGENTS_FEATURE_SCV_CODEX="false"
export OPENAGENTS_FEATURE_SCV_DEPLOY="true"
export OPENAGENTS_FEATURE_SEMANTIC_MEMORY="true"
export OPENAGENTS_FEATURE_SHADOW_PROGRAMS="true"
# Cross-account recall of the system bucket (MEMORY-001, MEMORY-011). Off in
# production: an admitted system memory is written by one account and read by
# every account, which is the one place recall crosses the account boundary,
# and it ships dark until an operator turns it on deliberately. With it off,
# recall reads the `user` and `learned` buckets and nothing else.
export OPENAGENTS_FEATURE_SYSTEM_MEMORY_RECALL="false"
export OPENAGENTS_FEATURE_TOOL_EMBEDDINGS="true"
export OPENAGENTS_FEATURE_TOOLS="true"
export OPENAGENTS_FEATURE_TURN_RECOVERY="true"
export OPENAGENTS_FEATURE_VOICE="true"
export OPENAGENTS_FEATURE_VOICE_RECORDING="true"
export OPENAGENTS_FEATURE_VOICE_RETENTION="true"
export OPENAGENTS_FEATURE_WORK="true"
export OPENAGENTS_FORGE_ARTIFACT_DIR="/var/lib/openagents/forge/beams"
export OPENAGENTS_FORGE_ARTIFACT_STORE="local"
export OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS="30000"
export OPENAGENTS_FORGE_BOOT_RETRY_MIN_MS="1000"
export OPENAGENTS_FORGE_BUILD_DIR="/var/lib/openagents/workspace/build"
export OPENAGENTS_FORGE_BUILD_EXECUTOR="sidecar"
export OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS="604800000"
export OPENAGENTS_FORGE_BUILD_QUEUE_DIR="/var/lib/openagents/workspace/build-queue"
export OPENAGENTS_FORGE_BUILD_TIMEOUT_MS="900000"
export OPENAGENTS_FORGE_DATA_DIR="/var/lib/openagents/forge"
export OPENAGENTS_FORGE_DEPLOY_TIMEOUT_MS="15000"
export OPENAGENTS_FORGE_DEPLOY_TOKEN_TTL_MS="120000"
export OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE="3"
export OPENAGENTS_FORGE_INTERNAL_GIT_URL="http://127.0.0.1:8080/OpenAgentsInc"
export OPENAGENTS_FORGE_OWNER="OpenAgentsInc"
export OPENAGENTS_FORGE_REPOSITORIES="openagents.com"
export OPENAGENTS_FORGE_MIRROR_URLS_JSON='{"openagents.com":"ssh://github.com/OpenAgentsInc/openagents.com.git"}'
export OPENAGENTS_FORGE_WAL_ADAPTER="gcs"
export OPENAGENTS_FORGE_WAL_BUCKET="sarah-forge-wal"
export OPENAGENTS_FORGE_WAL_DIR="/var/lib/openagents/forge-wal"
export OPENAGENTS_GCP_COMPUTE_TIMEOUT_MS="300000"
export OPENAGENTS_GCP_ROLLING_RPC_TIMEOUT_MS="5000"
export OPENAGENTS_HTTPS_ALIASES="www.openagents.com,fleet.openagents.com"
export OPENAGENTS_IMAGE_DIGEST="$IMAGE_DIGEST"
export OPENAGENTS_INFERENCE_PROXY_URL="https://openagents.com/api/inference/proxy"
export OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS="2592000"
export OPENAGENTS_MIGRATE_ON_BOOT="true"
export OPENAGENTS_RELEASES_BUCKET="openagentsgemini-cli-releases"
export OPENAGENTS_PRODUCTION_DEPLOY_ENABLED="true"
export OPENAGENTS_RA_DATA_DIR="/var/lib/openagents/ra"
export OPENAGENTS_RA_EXPECTED_SIZE="3"
export OPENAGENTS_SECURE_COOKIES="true"
export OPENAGENTS_STAGING_CLEANUP_ENABLED="false"
export OPENAGENTS_SCV_DEPLOY_OUTPUT_ROOT="/var/lib/openagents/workspace/scv-runs"
export OPENAGENTS_SCV_TEMPORARY_ROOT="/var/lib/openagents/workspace/scv-clones"
export OPENAGENTS_STAGING_GATE="16"
export PHX_HOST="openagents.com"
export PHX_SERVER="true"
export POOL_SIZE="2"
export PORT="8080"
export GIT_SSH_COMMAND="ssh -l git -i /app/.mirror/id_ed25519 -o UserKnownHostsFile=/app/.mirror/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes"

ENV_NAMES=(
  SECRET_KEY_BASE OPENAI_API_KEY OPENROUTER_API_KEY BOX_API_KEY GEMINI_API_KEY
  AI_GATEWAY_API_KEY
  GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
  GITHUB_TOKEN_ENCRYPTION_KEY VOICE_RECORDING_ENCRYPTION_KEY RELEASE_COOKIE
  MACHINE_TOKEN_ENCRYPTION_KEY CONTENT_ENCRYPTION_KEY
  OPENAGENTS_FORGE_OPERATOR_TOKEN OPENAGENTS_POSTHOG_PROJECT_TOKEN
  DATABASE_URL DNS_CLUSTER_QUERY
  GITHUB_OAUTH_SCOPES GITHUB_REDIRECT_URI GITHUB_TOKEN_DECRYPTION_KEYS_JSON
  GITHUB_TOKEN_ENCRYPTION_KEY_ID OPENAGENTS_ADMIN_GITHUB_IDS
  OPENAGENTS_ALLOWED_ORIGINS OPENAGENTS_CODING_JOBS_DIR
  OPENAGENTS_DATABASE_IPV6 OPENAGENTS_DATABASE_MODE OPENAGENTS_DIST_PORT_MAX
  OPENAGENTS_DIST_PORT_MIN OPENAGENTS_ENVIRONMENT
  OPENAGENTS_FEATURE_BOOT_CONVERGENCE OPENAGENTS_FEATURE_COMPUTERS
  OPENAGENTS_FEATURE_CONVERSATION_RESET OPENAGENTS_FEATURE_DEPLOYMENT_CONTROL_PLANE
  OPENAGENTS_FEATURE_EXPERIENCE_MEMORY
  OPENAGENTS_FEATURE_FORGE OPENAGENTS_FEATURE_FORGE_DEPLOY
  OPENAGENTS_FEATURE_GRAPH_MEMORY OPENAGENTS_FEATURE_HORDE
  OPENAGENTS_FEATURE_INCIDENT_FIXER OPENAGENTS_FEATURE_MEMORY_EMBEDDINGS
  OPENAGENTS_FEATURE_MEMORY_PORTABILITY
  OPENAGENTS_FEATURE_RA OPENAGENTS_FEATURE_SCV_CODEX
  OPENAGENTS_FEATURE_SCV_DEPLOY OPENAGENTS_SCV_DEPLOY_OUTPUT_ROOT
  OPENAGENTS_SCV_TEMPORARY_ROOT
  OPENAGENTS_FEATURE_SEMANTIC_MEMORY OPENAGENTS_FEATURE_SHADOW_PROGRAMS
  OPENAGENTS_FEATURE_SYSTEM_MEMORY_RECALL
  OPENAGENTS_FEATURE_TOOL_EMBEDDINGS OPENAGENTS_FEATURE_TOOLS
  OPENAGENTS_FEATURE_TURN_RECOVERY OPENAGENTS_FEATURE_VOICE
  OPENAGENTS_FEATURE_VOICE_RECORDING OPENAGENTS_FEATURE_VOICE_RETENTION
  OPENAGENTS_FEATURE_WORK OPENAGENTS_FORGE_ARTIFACT_DIR
  OPENAGENTS_FORGE_ARTIFACT_STORE OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS
  OPENAGENTS_FORGE_BOOT_RETRY_MIN_MS OPENAGENTS_FORGE_BUILD_DIR
  OPENAGENTS_FORGE_BUILD_EXECUTOR OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS
  OPENAGENTS_FORGE_BUILD_QUEUE_DIR OPENAGENTS_FORGE_BUILD_TIMEOUT_MS
  OPENAGENTS_FORGE_DATA_DIR OPENAGENTS_FORGE_DEPLOY_TIMEOUT_MS
  OPENAGENTS_FORGE_DEPLOY_TOKEN_TTL_MS OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE
  OPENAGENTS_FORGE_INTERNAL_GIT_URL OPENAGENTS_FORGE_OWNER
  OPENAGENTS_FORGE_REPOSITORIES OPENAGENTS_FORGE_MIRROR_URLS_JSON
  OPENAGENTS_FORGE_WAL_ADAPTER
  OPENAGENTS_FORGE_WAL_BUCKET OPENAGENTS_FORGE_WAL_DIR
  OPENAGENTS_GCP_COMPUTE_TIMEOUT_MS OPENAGENTS_GCP_ROLLING_RPC_TIMEOUT_MS
  OPENAGENTS_HTTPS_ALIASES OPENAGENTS_IMAGE_DIGEST
  OPENAGENTS_INFERENCE_PROXY_URL OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS
  OPENAGENTS_MIGRATE_ON_BOOT OPENAGENTS_PRODUCTION_DEPLOY_ENABLED
  OPENAGENTS_RA_DATA_DIR OPENAGENTS_RA_EXPECTED_SIZE
  OPENAGENTS_RELEASES_BUCKET
  OPENAGENTS_SECURE_COOKIES OPENAGENTS_STAGING_CLEANUP_ENABLED
  OPENAGENTS_STAGING_GATE PHX_HOST PHX_SERVER POOL_SIZE PORT GIT_SSH_COMMAND
)

docker_env_args=()
for name in "${ENV_NAMES[@]}"; do
  docker_env_args+=(--env "$name")
done

run_release() {
  docker run --rm --network host "${docker_env_args[@]}" "$IMAGE" "$@"
}

run_eval() {
  export OPENAGENTS_EVAL="$1"
  docker run --rm --network host "${docker_env_args[@]}" --env OPENAGENTS_EVAL \
    --entrypoint /bin/sh "$IMAGE" -c '
      export RELEASE_ROOT=/app
      export RELEASE_NAME=openagents
      export RELEASE_VSN=$(awk '\''{print $2}'\'' /app/releases/start_erl.data)
      export RELEASE_COMMAND=eval
      export RELEASE_PROG=openagents
      /app/releases/$RELEASE_VSN/elixir \
        --cookie "$RELEASE_COOKIE" \
        --erl-config /app/releases/$RELEASE_VSN/build \
        --boot /app/releases/$RELEASE_VSN/preboot \
        --boot-var RELEASE_LIB /app/lib \
        --vm-args /app/releases/$RELEASE_VSN/vm.args \
        --eval "Castle.generate(~s($RELEASE_VSN));Castle.make_releases()" &&
      exec /app/bin/openagents eval "$OPENAGENTS_EVAL"
    '
}

case "${1:-start}" in
  check-lineage)
    # The reviewed bridge command is intentionally admitted through the
    # staging operator lane; it still connects only to the explicit DB URL.
    export OPENAGENTS_ENVIRONMENT="staging"
    run_eval 'OpenAgents.Release.migration_lineage("check") |> IO.inspect()'
    ;;
  migrate)
    # The reviewed bridge command is intentionally admitted through the
    # staging operator lane; the production web runtime starts separately.
    export OPENAGENTS_ENVIRONMENT="staging"
    export OPENAGENTS_STAGING_SNAPSHOT_ID="${2:?backup ID is required}"
    docker_env_args+=(--env OPENAGENTS_STAGING_SNAPSHOT_ID)
    run_eval 'OpenAgents.Release.migration_lineage("apply", System.fetch_env!("OPENAGENTS_STAGING_SNAPSHOT_ID")) |> IO.inspect()'
    run_eval 'OpenAgents.Release.migrate() |> IO.inspect()'
    run_eval 'OpenAgents.Release.migration_lineage("check") |> IO.inspect()'
    ;;
  migrate-now)
    run_eval 'OpenAgents.Release.migrate() |> IO.inspect()'
    ;;
  start)
    export OPENAGENTS_NODE_HOST="$IP"
    export RELEASE_DISTRIBUTION="name"
    export RELEASE_NODE="openagents@$IP"
    docker_env_args+=(--env OPENAGENTS_NODE_HOST --env RELEASE_DISTRIBUTION --env RELEASE_NODE)

    # The OpenAgents runtime and builder supersede the legacy Sarah builder
    # and break-glass Git daemon. Remove them before pruning so their image
    # cannot exhaust the small fleet boot disks during a fallback rollout.
    docker rm -f openagents sarah sarah-builder sarah-breakglass 2>/dev/null || true

    # Artifact Registry keeps immutable rollback images. Reclaim only images
    # that no running container uses before pulling the next release.
    docker image prune --all --force

    docker pull "$IMAGE" >/dev/null
    docker rm -f sqlproxy 2>/dev/null || true
    docker run -d --name sqlproxy --restart always --network host \
      gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1 \
      --address 127.0.0.1 --port 5432 openagentsgemini:us-central1:sarah-postgres

    for _attempt in $(seq 1 30); do
      python3 -c 'import socket; socket.create_connection(("127.0.0.1", 5432), 1).close()' \
        2>/dev/null && break
      sleep 2
    done

    mkdir -p /var/lib/sarah-ra /var/lib/sarah-forge/beams \
      /var/lib/sarah-forge-wal /var/lib/sarah-workspace/build \
      /var/lib/sarah-workspace/build-queue /var/lib/sarah-workspace/coding-jobs \
      /var/lib/sarah-workspace/scv-runs /var/lib/sarah-workspace/scv-clones
    chmod 0777 /var/lib/sarah-ra /var/lib/sarah-forge /var/lib/sarah-forge/beams \
      /var/lib/sarah-forge-wal /var/lib/sarah-workspace \
      /var/lib/sarah-workspace/build /var/lib/sarah-workspace/build-queue \
      /var/lib/sarah-workspace/coding-jobs /var/lib/sarah-workspace/scv-runs \
      /var/lib/sarah-workspace/scv-clones
    mount --bind /var/lib/sarah-workspace /var/lib/sarah-workspace 2>/dev/null || true
    mount -o remount,exec /var/lib/sarah-workspace || true

    cat > /var/lib/sarah-workspace/forge-git-askpass <<'EOF'
#!/bin/sh
case "${1:-}" in
  *Username*) printf '%s\n' operator ;;
  *Password*) printf '%s\n' "$OPENAGENTS_FORGE_OPERATOR_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
    chmod 0755 /var/lib/sarah-workspace/forge-git-askpass

    mkdir -p /var/lib/openagents-mirror
    chmod 0755 /var/lib/openagents-mirror
    secret openagents-github-mirror-deploy-key > /var/lib/openagents-mirror/id_ed25519
    chmod 0600 /var/lib/openagents-mirror/id_ed25519
    chown 65534:65534 /var/lib/openagents-mirror/id_ed25519
    printf '%s\n' \
      'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
      > /var/lib/openagents-mirror/known_hosts
    chmod 0644 /var/lib/openagents-mirror/known_hosts

    docker run -d --name openagents --restart always --network host \
      -v /var/lib/sarah-ra:/var/lib/openagents/ra \
      -v /var/lib/sarah-forge:/var/lib/openagents/forge \
      -v /var/lib/sarah-forge-wal:/var/lib/openagents/forge-wal \
      -v /var/lib/sarah-workspace:/var/lib/openagents/workspace \
      -v /var/lib/openagents-mirror:/app/.mirror:ro \
      "${docker_env_args[@]}" "$IMAGE"

    docker rm -f openagents-builder 2>/dev/null || true
    docker image prune --all --force
    docker pull "$BUILDER_IMAGE" >/dev/null
    docker run -d --name openagents-builder --restart always --network host \
      --user 0:65534 \
      -v /var/lib/sarah-forge:/var/lib/openagents/forge \
      -v /var/lib/sarah-workspace:/var/lib/openagents/workspace \
      --env OPENAGENTS_FORGE_OPERATOR_TOKEN \
      --env OPENAGENTS_FORGE_GIT_ASKPASS=/var/lib/openagents/workspace/forge-git-askpass \
      --env OPENAGENTS_FORGE_ARTIFACT_DIR=/var/lib/openagents/forge/beams \
      --env OPENAGENTS_FORGE_BUILD_DIR=/var/lib/openagents/workspace/build \
      --env OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS=604800000 \
      --env OPENAGENTS_FORGE_BUILD_QUEUE_DIR=/var/lib/openagents/workspace/build-queue \
      "$BUILDER_IMAGE"

    (
      for _attempt in $(seq 1 30); do
        if docker exec openagents /app/bin/openagents rpc 'IO.puts(:ok)' >/dev/null 2>&1; then
          docker exec openagents /app/bin/openagents rpc \
            'Enum.each([:"openagents@10.128.0.4", :"openagents@10.128.0.110", :"openagents@10.128.0.111"], &Node.connect/1)' >/dev/null 2>&1 || true
        fi
        sleep 10
      done
    ) &
    ;;
  *)
    echo "usage: $0 {check-lineage|migrate BACKUP_ID|start}" >&2
    exit 2
    ;;
esac




