#!/bin/sh
# Roll one revision onto the production fleet, one node at a time.
#
# Promotion needs an operator, not a browser: there is no button on
# /admin/forge that does it, and telling someone to look for one wastes their
# time. This drives the same operator API a console would, through `rpc` on a
# node, so the whole release runs from a terminal.
#
# It refuses rather than guesses. A revision with no passing gate receipt, an
# image whose embedded revision is not the Git SHA, or a node that comes back
# on the wrong revision each stop the release where it stands, because a
# half-rolled fleet that reports success is worse than one that stops.
#
# Usage: ops/deploy/release-to-production.sh <git-sha>

set -eu

sha=${1:-}
[ -n "$sha" ] || { echo "usage: $0 <git-sha>" >&2; exit 2; }

project=openagentsgemini
registry=us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents
# The automation service account: the interactive account hits Workspace
# reauthentication and cannot refresh in a headless run.
CLOUDSDK_CONFIG=${CLOUDSDK_CONFIG:-/Users/christopherdavid/work/.secrets/gcloud-sa-config}
export CLOUDSDK_CONFIG

# Zone is part of a node's identity here, so the three are named together.
nodes='sarah-fleet-1:us-central1-a sarah-fleet-2:us-central1-b sarah-fleet-3:us-central1-c'

on_node() {
  instance=$1
  zone=$2
  shift 2
  gcloud compute ssh "$instance" --zone="$zone" --project="$project" \
    --tunnel-through-iap --command="$*"
}

# Inline `rpc` quoting does not survive the trip through ssh and docker, so
# every remote evaluation goes as a file.
rpc_file() {
  instance=$1
  zone=$2
  script=$3
  gcloud compute scp "$script" "$instance:/tmp/rpc.exs" --zone="$zone" \
    --project="$project" >/dev/null
  on_node "$instance" "$zone" \
    "chmod 644 /tmp/rpc.exs && docker cp /tmp/rpc.exs openagents:/tmp/rpc.exs && docker exec openagents /app/bin/openagents rpc 'Code.eval_file(\"/tmp/rpc.exs\")'"
}

health_of() {
  on_node "$1" "$2" 'curl -s http://127.0.0.1:8080/health' 2>/dev/null |
    grep -o '"revision":"[0-9a-f]*"' | head -1 | cut -d'"' -f4
}

echo "==> release $sha"

# 1. The gate receipt. Read it rather than re-running the gate, so a release
#    cannot be talked into trusting a run nobody kept.
receipt="$(git rev-parse --path-format=absolute --git-common-dir)/openagents/release-gate-receipts/$sha.json"
[ -f "$receipt" ] || { echo "no gate receipt for $sha; run ops/ci/gate.sh first" >&2; exit 1; }
jq -e '.status == "passed"' "$receipt" >/dev/null ||
  { echo "gate receipt for $sha is not passed" >&2; exit 1; }
echo "gate receipt: passed"

# 2. The image, identified by digest from here on. A tag can be moved; a
#    digest names the bytes the fleet will actually run.
digest=$(gcloud artifacts docker images describe "$registry:$sha" \
  --format='value(image_summary.digest)' --project="$project" 2>/dev/null || true)
[ -n "$digest" ] || { echo "no image for $sha; build it first" >&2; exit 1; }
echo "image digest: $digest"

echo "==> promote"
promote=$(mktemp)
cat > "$promote" <<ELIXIR
live = OpenAgents.Forge.Targets.live("openagents.com")
previous_sha = (live && live.sha) || "$sha"
previous_image_digest = (live && live.details["image_digest"]) || "$digest"
expected_nodes = Enum.sort(["openagents@10.128.0.4", "openagents@10.128.0.110", "openagents@10.128.0.111"])

target =
  case OpenAgents.Forge.Targets.current("openagents.com") do
    %{sha: "$sha", status: status} = t when status in ["promoted", "building", "built", "needs_rolling_replace"] ->
      t
    _ ->
      {:ok, t} = OpenAgents.Forge.Targets.promote("openagents.com", "$sha", "operator:14167547", details: %{"source" => "operator_console"})
      t
  end

{:ok, authorized} =
  OpenAgents.Forge.Targets.authorize_rolling_replacement(target.id, %{
    "sha" => "$sha",
    "image_digest" => "$digest",
    "previous_sha" => previous_sha,
    "previous_image_digest" => previous_image_digest,
    "expected_nodes" => expected_nodes,
    "authorized_by" => "operator:14167547"
  })

IO.puts("target=#{authorized.id} status=#{authorized.status}")
ELIXIR
rpc_file sarah-fleet-1 us-central1-a "$promote"
rm -f "$promote"

echo "==> roll"

# The startup script pins the image by digest, so it is generated per release
# rather than edited by hand. A stale digest here is how a "rolled" node comes
# back running the previous release while every check reports success.
startup=$(mktemp)
sed "s|__IMAGE_DIGEST__|$digest|g" "$(dirname "$0")/fleet-startup.template.sh" > "$startup"
grep -q '__IMAGE_DIGEST__' "$startup" && { echo "startup template not fully filled" >&2; exit 1; }

for entry in $nodes; do
  instance=${entry%%:*}
  zone=${entry##*:}
  echo "--> $instance ($zone)"

  gcloud compute instances add-metadata "$instance" --zone="$zone" \
    --project="$project" --metadata-from-file=startup-script="$startup" >/dev/null
  on_node "$instance" "$zone" 'sudo google_metadata_script_runner startup >/tmp/roll.log 2>&1 &'

  # Wait for the node to come back on the revision it was asked for. A node
  # that answers on the OLD revision is not "still starting" — it is a node
  # that did not take the release, and continuing past it would leave the
  # fleet split while reporting success.
  ok=
  i=0
  while [ "$i" -lt 30 ]; do
    sleep 20
    if [ "$(health_of "$instance" "$zone")" = "$sha" ]; then ok=1; break; fi
    i=$((i + 1))
  done
  [ -n "$ok" ] || { echo "$instance did not reach $sha; stopping with the fleet split" >&2; exit 1; }
  echo "    healthy on $sha"
done
rm -f "$startup"

echo "==> settle"
settle=$(mktemp)
cat > "$settle" <<ELIXIR
target = OpenAgents.Forge.Targets.current("openagents.com")
sha = "$sha"
image_digest = "$digest"
authority = OpenAgents.Forge.Targets.rolling_authority("openagents.com")
expected = authority["expected_nodes"]

# Ask each node what it is running. Recording an assumed identity would make
# the log say something nobody checked, which is the one thing settlement
# exists to prevent.
observed =
  Map.new(expected, fn name ->
    {name, :rpc.call(String.to_atom(name), OpenAgents.BuildInfo, :revision, [])}
  end)

wrong = for {name, revision} <- observed, revision != sha, do: {name, revision}

if wrong != [] do
  IO.inspect(wrong, label: :refused_nodes_not_on_this_revision)
else
  for {name, _revision} <- observed do
    {:ok, _} =
      OpenAgents.Forge.Targets.record_rolling_node(target.id, name, %{
        sha: sha,
        image_digest: image_digest
      })
  end

  result = %{
    schema: "openagents.rolling-replacement.v1",
    sha: sha,
    previous_sha: authority["previous_sha"],
    image_digest: image_digest,
    previous_image_digest: authority["previous_image_digest"],
    expected_nodes: expected,
    status: "live",
    node_results: Map.new(expected, &{&1, "ready"})
  }

  IO.inspect(OpenAgents.Forge.Targets.finish_rolling_replacement(target.id, result) |> elem(0),
    label: :finish
  )

  settled = OpenAgents.Forge.Targets.current("openagents.com")
  IO.puts("status=#{settled.status} sha=#{String.slice(settled.sha || "", 0, 12)}")
end
ELIXIR
rpc_file sarah-fleet-1 us-central1-a "$settle"
rm -f "$settle"

curl -s -o /dev/null -w 'openagents.com: %{http_code}\n' https://openagents.com/
