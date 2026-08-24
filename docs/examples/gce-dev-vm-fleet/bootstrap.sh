#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install --yes ca-certificates curl gnupg lsb-release

install -d -m 0755 /etc/apt/keyrings

if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
  curl --fail --silent --show-error --location \
    https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor --output /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  . /etc/os-release
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list
fi

if [[ ! -s /etc/apt/keyrings/postgresql.gpg ]]; then
  curl --fail --silent --show-error --location \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc |
    gpg --dearmor --output /etc/apt/keyrings/postgresql.gpg
  chmod a+r /etc/apt/keyrings/postgresql.gpg
fi

if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  . /etc/os-release
  printf 'deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/pgdg.list
fi

if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
  curl --fail --silent --show-error --location https://deb.nodesource.com/setup_20.x |
    bash -
fi

apt-get update
apt-get install --yes \
  build-essential \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  git \
  jq \
  nodejs \
  openjdk-17-jdk \
  postgresql-client-16 \
  python3 \
  python3-pip \
  ripgrep

systemctl enable --now docker

if [[ ! -x /opt/cargo/bin/rustup ]]; then
  install -d -m 0755 /opt/cargo /opt/rustup
  curl --fail --silent --show-error --location https://sh.rustup.rs |
    RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo sh -s -- \
      -y --default-toolchain stable --no-modify-path
fi

cat > /etc/profile.d/rust.sh <<'EOF'
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export PATH="$CARGO_HOME/bin:$PATH"
EOF

chmod -R a+rX /opt/cargo /opt/rustup
