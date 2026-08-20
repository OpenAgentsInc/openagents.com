#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
terraform_dir="$repo_root/infra/staging"
command_name=${1:-validate}
confirmation=${2:-}
staging_project=${OPENAGENTS_STAGING_PROJECT_ID:-}
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
state_bucket=${OPENAGENTS_STAGING_TF_STATE_BUCKET:-}
git_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
plan_root="$repo_root/.git/openagents/staging-plans"
plan_path="$plan_root/$git_sha.tfplan"

require_boundary() {
  : "${staging_project:?OPENAGENTS_STAGING_PROJECT_ID is required}"
  : "${production_project:?OPENAGENTS_PRODUCTION_PROJECT_ID is required}"
  : "${state_bucket:?OPENAGENTS_STAGING_TF_STATE_BUCKET is required}"
  : "${TF_VAR_database_password:?TF_VAR_database_password is required and remains write-only}"

  case "$staging_project" in
    *stag*) ;;
    *) echo "staging project ID must contain 'stag'" >&2; exit 1 ;;
  esac

  if [ "$staging_project" = "$production_project" ]; then
    echo "staging and production project IDs must differ" >&2
    exit 1
  fi

  gcloud auth application-default print-access-token >/dev/null
  export TF_VAR_staging_project_id="$staging_project"
  export TF_VAR_production_project_id="$production_project"
}

initialize_backend() {
  terraform -chdir="$terraform_dir" init \
    -input=false \
    -reconfigure \
    -backend-config="bucket=$state_bucket"
}

case "$command_name" in
  validate)
    terraform -chdir="$terraform_dir" fmt -check -recursive
    terraform -chdir="$terraform_dir" init -backend=false -input=false
    terraform -chdir="$terraform_dir" validate
    ;;

  plan)
    require_boundary

    if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
      echo "staging plan requires a clean worktree" >&2
      exit 1
    fi

    initialize_backend
    mkdir -p "$plan_root"
    terraform -chdir="$terraform_dir" plan -input=false -out="$plan_path"
    echo "Saved exact-SHA staging plan: .git/openagents/staging-plans/$git_sha.tfplan"
    ;;

  apply)
    require_boundary

    if [ "$confirmation" != "--apply" ]; then
      echo "staging apply requires the explicit --apply argument" >&2
      exit 64
    fi

    if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]; then
      echo "staging apply requires a clean worktree" >&2
      exit 1
    fi

    if [ ! -f "$plan_path" ]; then
      echo "no Terraform plan exists for exact SHA $git_sha" >&2
      exit 1
    fi

    initialize_backend
    terraform -chdir="$terraform_dir" apply -input=false "$plan_path"
    ;;

  output)
    require_boundary
    initialize_backend
    terraform -chdir="$terraform_dir" output -json
    ;;

  *)
    echo "usage: ops/staging/terraform.sh [validate|plan|apply --apply|output]" >&2
    exit 64
    ;;
esac
