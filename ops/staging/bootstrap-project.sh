#!/bin/sh
set -eu

mode=${1:-check}
staging_project=${OPENAGENTS_STAGING_PROJECT_ID:-}
production_project=${OPENAGENTS_PRODUCTION_PROJECT_ID:-}
billing_account=${OPENAGENTS_STAGING_BILLING_ACCOUNT:-}
state_bucket=${OPENAGENTS_STAGING_TF_STATE_BUCKET:-${staging_project}-openagents-tfstate}
location=${OPENAGENTS_STAGING_STATE_LOCATION:-US-CENTRAL1}

require_inputs() {
  : "${staging_project:?OPENAGENTS_STAGING_PROJECT_ID is required}"
  : "${production_project:?OPENAGENTS_PRODUCTION_PROJECT_ID is required}"
  : "${billing_account:?OPENAGENTS_STAGING_BILLING_ACCOUNT is required}"

  case "$staging_project" in
    *stag*) ;;
    *) echo "staging project ID must contain 'stag'" >&2; exit 1 ;;
  esac

  if [ "$staging_project" = "$production_project" ]; then
    echo "staging and production project IDs must differ" >&2
    exit 1
  fi
}

describe_actions() {
  echo "Staging project: $staging_project"
  echo "Production comparison project: $production_project"
  echo "Billing account: $billing_account"
  echo "Terraform state bucket: gs://$state_bucket"
  echo "Mode: $mode"
}

apply_bootstrap() {
  gcloud auth print-access-token >/dev/null

  if ! gcloud projects describe "$staging_project" >/dev/null 2>&1; then
    gcloud projects create "$staging_project" --name="OpenAgents staging"
  fi

  gcloud billing projects link "$staging_project" --billing-account="$billing_account"
  gcloud services enable serviceusage.googleapis.com storage.googleapis.com \
    --project="$staging_project"

  if ! gcloud storage buckets describe "gs://$state_bucket" \
    --project="$staging_project" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://$state_bucket" \
      --project="$staging_project" \
      --location="$location" \
      --uniform-bucket-level-access \
      --public-access-prevention \
      --soft-delete-duration=7d
  fi

  gcloud storage buckets update "gs://$state_bucket" --versioning
}

require_inputs

case "$mode" in
  check)
    describe_actions
    ;;

  --apply)
    describe_actions
    apply_bootstrap
    ;;

  *)
    echo "usage: ops/staging/bootstrap-project.sh [check|--apply]" >&2
    exit 64
    ;;
esac
