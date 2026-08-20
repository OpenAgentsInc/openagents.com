ARG RUNTIME_IMAGE=docker.io/debian:trixie-20260803-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
ARG ELIXIR_IMAGE=docker.io/hexpm/elixir:1.20.3-erlang-29.0.5-debian-trixie-20260803-slim@sha256:ae38be7cb19bffa78adedb04732d9e6ba83a507b4cfb06983cbe711edb49da54

FROM ${ELIXIR_IMAGE} AS scv-release-builder

ARG DEBIAN_SNAPSHOT=20260803T000000Z
ARG HEX_VERSION=2.5.1
ARG REBAR3_VERSION=3.25.1
ARG REBAR3_SHA512=69073f6ad163f74971545015238614c327893960c1b3f26df5377df135c773a0716b48b65c2a48cef878f185dd92805abc69894adfa3fd27a90c62a64ba371e2
ARG OPENAGENTS_BUILD_REVISION=image
ARG SOURCE_DATE_EPOCH=0

ENV HEX_HTTP_CONCURRENCY=2
ENV HEX_HTTP_TIMEOUT=120
ENV MIX_ENV=prod
ENV OPENAGENTS_BUILD_REVISION=${OPENAGENTS_BUILD_REVISION}
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

RUN sed -i \
      "s|URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && sed -i \
      "s|URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
  && apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex "${HEX_VERSION}" --force \
  && mix local.rebar rebar3 \
      "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
      --sha512 "${REBAR3_SHA512}" \
      --force

COPY mix.exs mix.lock ./
RUN for attempt in 1 2 3; do \
      if mix deps.get --only prod; then \
        mkdir config; \
        exit 0; \
      fi; \
      echo "Dependency fetch attempt ${attempt} failed" >&2; \
    done; \
    exit 1

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY rel rel
RUN mix compile --warnings-as-errors

COPY config/runtime.exs config/
RUN mix release

FROM ${RUNTIME_IMAGE} AS opencode-toolchain

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_SNAPSHOT=20260803T000000Z
ARG NODE_VERSION=24.15.0
ARG BUN_VERSION=1.3.14
ARG OPENCODE_VERSION=1.18.5
ARG OPENAGENTS_BUILD_REVISION=image

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN sed -i \
      "s|URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && sed -i \
      "s|URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    jq \
    libsctp1 \
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
ENV ELIXIR_ERL_OPTIONS=+fnu
ENV OPENAGENTS_BUILD_REVISION=${OPENAGENTS_BUILD_REVISION}
ENV OPENAGENTS_ENVIRONMENT=staging
ENV OPENAGENTS_RUNTIME_ROLE=scv
ENV OPENCODE_BIN=/opt/scv/opencode/bin/opencode
ENV SCV_DRIVER=opencode
ENV SCV_ENVIRONMENT=opencode-core
ENV SCV_OUTPUT_ROOT=/workspace/runs
ENV SCV_PERMISSION_PROFILE=read_only
ENV SCV_REPOSITORY=/workspace/openagents
ENV SCV_REPOSITORY_REVISION=${OPENAGENTS_BUILD_REVISION}

COPY --from=scv-release-builder --chown=scv:scv /app/_build/prod/rel/openagents /opt/scv/openagents
COPY --chown=scv:scv . /workspace/openagents

USER scv
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/scv/openagents/bin/openagents", "start"]
