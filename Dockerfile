# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.3-erlang-29.0.5-debian-trixie-20260803-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260803-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260803-slim

ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=trixie-20260803-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

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

# Install Tailwind and esbuild so assets can be built
RUN mix assets.setup

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

CMD ["mix", "run", "--no-compile", "--no-start", "ops/forge/build-worker.exs"]

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

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
