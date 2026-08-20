#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
terraform_root="$repo_root/infra/staging"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required for the staging infrastructure gate" >&2
  exit 1
fi

terraform -chdir="$terraform_root" fmt -check -recursive
terraform -chdir="$terraform_root" init -backend=false -input=false -no-color
terraform -chdir="$terraform_root" validate -no-color
terraform -chdir="$terraform_root" test -no-color
