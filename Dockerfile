# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.3-erlang-29.0.5-debian-trixie-20260803-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260803-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260803-slim

ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=trixie-20260803-slim
ARG DEBIAN_SNAPSHOT=20260803T000000Z
ARG HEX_VERSION=2.5.1
ARG REBAR3_VERSION=3.25.1
ARG REBAR3_SHA512=69073f6ad163f74971545015238614c327893960c1b3f26df5377df135c773a0716b48b65c2a48cef878f185dd92805abc69894adfa3fd27a90c62a64ba371e2
ARG TAILWIND_VERSION=4.3.0
ARG TAILWIND_SHA256=73f0e5459054e5cfaa8ab6f3b940f3fbe0f13cc7fd83bc24e7c655033c203400
ARG ESBUILD_VERSION=0.25.4
ARG ESBUILD_SHA256=93433b456cac3a454ee27403d3de9adce88d83e5439ba37e1471af54730c9ca7
ARG NODE_VERSION=24.15.0
ARG CODEX_VERSION=0.147.0
ARG OPENCODE_VERSION=1.18.5

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}@sha256:ae38be7cb19bffa78adedb04732d9e6ba83a507b4cfb06983cbe711edb49da54"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258"

FROM ${BUILDER_IMAGE} AS builder

ARG OPENAGENTS_BUILD_REVISION="image"
ARG SOURCE_DATE_EPOCH=0
ARG DEBIAN_SNAPSHOT
ARG HEX_VERSION
ARG REBAR3_VERSION
ARG REBAR3_SHA512
ARG TAILWIND_VERSION
ARG TAILWIND_SHA256
ARG ESBUILD_VERSION
ARG ESBUILD_SHA256
ARG NODE_VERSION
ARG TARGETARCH
ENV OPENAGENTS_BUILD_REVISION=${OPENAGENTS_BUILD_REVISION}
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

# install build dependencies
RUN sed -i \
      "s|URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && sed -i \
      "s|URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
  && apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl git xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Install a checksum-pinned Node.js toolchain for JavaScript asset dependencies.
RUN set -eu; \
  case "${TARGETARCH:-amd64}" in \
    amd64) node_arch=x64; checksum=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6 ;; \
    arm64) node_arch=arm64; checksum=f3d5a797b5d210ce8e2cb265544c8e482eaedcb8aa409a8b46da7e8595d0dda0 ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" "https://nodejs.org/dist/v${NODE_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  tar -xJf "/tmp/${archive}" -C /usr/local --strip-components=1; \
  rm "/tmp/${archive}"; \
  node --version; \
  npm --version

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex "${HEX_VERSION}" --force \
  && mix local.rebar rebar3 \
      "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
      --sha512 "${REBAR3_SHA512}" \
      --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Install JavaScript dependencies before copying the rest of the asset tree so
# dependency downloads remain cached when application assets change.
COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix assets --ignore-scripts --no-audit --no-fund

# Install Tailwind and esbuild so assets can be built
RUN mix assets.setup \
  && printf '%s  %s\n' \
      "${TAILWIND_SHA256}" "/app/_build/tailwind-linux-x64-${TAILWIND_VERSION}" \
      "${ESBUILD_SHA256}" "/app/_build/esbuild-linux-x64" \
    | sha256sum --check --strict

COPY priv priv

COPY lib lib
COPY rel rel

# Compile the release
RUN mix compile --warnings-as-errors

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

RUN mix release

# Isolated compiler target. Deploy this target as the forge builder sidecar;
# it retains the pinned production Elixir/OTP toolchain and source for the
# versioned queue worker, but is never used as the public web image.
FROM builder AS forge-builder

COPY ops/forge ops/forge

ENV OPENAGENTS_RUNTIME_ROLE=builder
CMD ["mix", "run", "--no-compile", "--no-start", "ops/forge/build-worker.exs"]

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# BuildKit sets TARGETARCH automatically; Cloud Build's classic docker builder
# does not, and the `set -eu` below turns an unset value into a failed build.
# The consumer falls back to the builder's own architecture, so both paths
# resolve and the checksum still guards the result.
ARG TARGETARCH
ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG DEBIAN_SNAPSHOT
ARG SOURCE_DATE_EPOCH=0

# Geist TTFs for server-side image rendering (Open Graph cards). The web
# ships the same faces as woff2; librsvg reads system fonts through
# fontconfig, so the release image carries the pinned release's static weights.
ARG GEIST_FONT_VERSION=1.7.2
ARG GEIST_FONT_SHA256=7fc800d2ac6b92844895196e5041aca55d814c15db70c44f79b3b83ab82b04e2
ARG GEIST_REGULAR_SHA256=5c8968eafb98a4c4f47033daf29e38e284a6f2a82eb017d171ab040fe7c4b615
ARG GEIST_MEDIUM_SHA256=0090e004725f6f64b841715b4167920580f883fcf9b67fc6d744089103fec101
ARG GEIST_SEMIBOLD_SHA256=612ec98df33935354f39e81e54101656961ab6e5549f64b63eb57868ba7bab8d
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

RUN sed -i \
      "s|URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && sed -i \
      "s|URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources \
  && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
  && apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl git openssh-client unzip fontconfig librsvg2-bin \
  && rm -rf /var/lib/apt/lists/*

# Server-side image rendering (Open Graph cards) reads system fonts through
# fontconfig. The CSS declares the family as "Geist Sans" while the TTFs'
# internal name is "Geist", so the alias below keeps librsvg on-brand without
# touching the web font stack. Zip and extracted-file digests are both checked.
RUN set -eu; \
  archive="geist-font-v${GEIST_FONT_VERSION}.zip"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" \
    "https://github.com/vercel/geist-font/releases/download/v${GEIST_FONT_VERSION}/${archive}"; \
  echo "${GEIST_FONT_SHA256}  /tmp/${archive}" | sha256sum --check --strict; \
  install -d -m 0755 /usr/local/share/fonts/geist; \
  unzip -q -j "/tmp/${archive}" \
    "geist-font/Geist/ttf/Geist-Regular.ttf" \
    "geist-font/Geist/ttf/Geist-Medium.ttf" \
    "geist-font/Geist/ttf/Geist-SemiBold.ttf" \
    -d /usr/local/share/fonts/geist; \
  rm "/tmp/${archive}"; \
  cd /usr/local/share/fonts/geist; \
  printf '%s  %s\n' \
    "${GEIST_REGULAR_SHA256}" "Geist-Regular.ttf" \
    "${GEIST_MEDIUM_SHA256}" "Geist-Medium.ttf" \
    "${GEIST_SEMIBOLD_SHA256}" "Geist-SemiBold.ttf" \
    | sha256sum --check --strict; \
  printf '%s\n' \
    '<?xml version="1.0"?>' \
    '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">' \
    '<fontconfig>' \
    '  <match target="pattern">' \
    '    <test qual="any" name="family"><string>Geist Sans</string></test>' \
    '    <edit name="family" mode="assign" binding="same"><string>Geist</string></edit>' \
    '  </match>' \
    '</fontconfig>' \
    > /etc/fonts/local.conf; \
  fc-cache -f >/dev/null; \
  fc-match --format '%{family}\n' 'Geist Sans' | grep -qx 'Geist'; \
  rsvg-convert --version

# Codex, for the SCV deployment lane (SCV-001), pinned by version and
# checksum like every other external artifact in this image.
RUN set -eu; \
  case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
    amd64) codex_arch=x86_64; checksum=bd758d53d56e41dc65e045f4589df79a038ed197a011adcb52a258e6ad64cfda ;; \
    arm64) codex_arch=aarch64; checksum=89cbf79bd5ae6f9c58da47e8079f311c84219350c9c43c070d42f3e9b2a81401 ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="codex-package-${codex_arch}-unknown-linux-musl.tar.gz"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" \
    "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  install -d -m 0755 /usr/local/lib/codex-package; \
  tar -xzf "/tmp/${archive}" -C /usr/local/lib/codex-package; \
  ln -s /usr/local/lib/codex-package/bin/codex /usr/local/bin/codex; \
  ln -s /usr/local/lib/codex-package/bin/codex-code-mode-host /usr/local/bin/codex-code-mode-host; \
  rm "/tmp/${archive}"; \
  test -x /usr/local/lib/codex-package/codex-resources/bwrap; \
  test -x /usr/local/lib/codex-package/codex-path/rg; \
  codex --version; \
  codex-code-mode-host --help >/dev/null

# OpenCode, for the SCV deployment lane (SCV-001). The Codex SCV lane already
# runs its binary as a child of this node; the OpenCode lane needs the same,
# pinned by version and checksum from the same release the SCV worker image
# uses, so both images run identical bytes.
RUN set -eu; \
  case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
    amd64) opencode_arch=x64; checksum=cd4a2557a3d6550f27cb5c0257ebe8d73388bb34beda8b6121e6428a74c1eae2 ;; \
    arm64) opencode_arch=arm64; checksum=18b643362fdf0b8d5b8711b3e160dafb4e68d0bfc00288f56fd1298fd72da69d ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  archive="opencode-linux-${opencode_arch}.tar.gz"; \
  curl -fsSL --retry 3 -o "/tmp/${archive}" \
    "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${archive}"; \
  echo "${checksum}  /tmp/${archive}" | sha256sum --check --strict; \
  tar -xzf "/tmp/${archive}" -C /tmp; \
  install -D -m 0755 /tmp/opencode /usr/local/bin/opencode; \
  rm "/tmp/${archive}" /tmp/opencode; \
  opencode --version

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/openagents ./

USER nobody

# Boot through the castle-managed bin/openagents. PHX_SERVER=true starts the
# web server; it is what the overlay bin/server also sets.
ENV PHX_SERVER=true
CMD ["/app/bin/openagents", "start"]
