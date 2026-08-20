ARG UBUNTU_IMAGE=ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
FROM ${UBUNTU_IMAGE}

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=24.15.0
ARG BUN_VERSION=1.3.14
ARG OPENCODE_VERSION=1.18.5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    pkg-config \
    procps \
    python3 \
    python3-setuptools \
    ripgrep \
    tini \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/*

RUN set -euo pipefail; \
  case "${TARGETARCH}" in \
    amd64) node_arch=x64; checksum=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6 ;; \
    arm64) node_arch=arm64; checksum=f3d5a797b5d210ce8e2cb265544c8e482eaedcb8aa409a8b46da7e8595d0dda0 ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" "https://nodejs.org/dist/v${NODE_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  tar -xJf "/tmp/${archive}" -C /usr/local --strip-components=1; \
  rm "/tmp/${archive}"; \
  corepack enable; \
  node --version; \
  npm --version

RUN set -euo pipefail; \
  case "${TARGETARCH}" in \
    amd64) bun_arch=x64; checksum=951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f ;; \
    arm64) bun_arch=aarch64; checksum=a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="bun-linux-${bun_arch}.zip"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  unzip -q "/tmp/${archive}" -d /tmp/bun; \
  install -D -m 0755 "/tmp/bun/bun-linux-${bun_arch}/bun" /opt/bun/bin/bun; \
  ln -s /opt/bun/bin/bun /opt/bun/bin/bunx; \
  rm -rf "/tmp/${archive}" /tmp/bun; \
  /opt/bun/bin/bun --version

RUN set -euo pipefail; \
  case "${TARGETARCH}" in \
    amd64) opencode_arch=x64; checksum=cd4a2557a3d6550f27cb5c0257ebe8d73388bb34beda8b6121e6428a74c1eae2 ;; \
    arm64) opencode_arch=arm64; checksum=18b643362fdf0b8d5b8711b3e160dafb4e68d0bfc00288f56fd1298fd72da69d ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="opencode-linux-${opencode_arch}.tar.gz"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" \
    "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  tar -xzf "/tmp/${archive}" -C /tmp; \
  install -D -m 0755 /tmp/opencode /opt/scv/opencode/bin/opencode; \
  rm "/tmp/${archive}" /tmp/opencode; \
  /opt/scv/opencode/bin/opencode --version

RUN groupadd --gid 10001 scv \
  && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/scv --shell /bin/bash scv \
  && install -d -o scv -g scv -m 0700 \
    /workspace \
    /home/scv/.cache \
    /home/scv/.config \
    /home/scv/.local/share \
    /home/scv/.local/state \
  && chown -R scv:scv /home/scv

ENV BUN_INSTALL=/opt/bun
ENV HOME=/home/scv
ENV PATH=/opt/scv/opencode/bin:/opt/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV XDG_CACHE_HOME=/home/scv/.cache
ENV XDG_CONFIG_HOME=/home/scv/.config
ENV XDG_DATA_HOME=/home/scv/.local/share
ENV XDG_STATE_HOME=/home/scv/.local/state

USER scv
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["opencode", "--version"]
