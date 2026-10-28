# syntax=docker/dockerfile:1
ARG ELIXIR_BUILD_IMAGE
ARG DEBIAN_RUNTIME_IMAGE
# Builder and runtime must use the same Debian release/architecture and libc.
FROM ${ELIXIR_BUILD_IMAGE} AS build
ENV MIX_ENV=prod
WORKDIR /src
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile
# ItsmBackend.Contracts embeds these canonical schemas at compile time.
COPY contracts ./contracts
COPY lib ./lib
COPY priv ./priv
RUN mix compile --warnings-as-errors && mix release

FROM ${DEBIAN_RUNTIME_IMAGE} AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libstdc++6 openssl libncurses6 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 janus && useradd --uid 10001 --gid janus --create-home janus
WORKDIR /app
COPY --from=build --chown=10001:10001 /src/_build/prod/rel/itsm_backend ./
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/janus-backend
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/janus-backend-health
ENV PHX_SERVER=true PORT=4000 PHX_BIND_IP=0.0.0.0 \
    RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp/janus-release
USER 10001:10001
EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/janus-backend"]
CMD ["start"]
HEALTHCHECK --interval=30s --timeout=15s --start-period=30s --retries=3 CMD ["/usr/local/bin/janus-backend-health"]
