# -----------------------------------------------------------------------------
# pi adapter.
#
# The OS layer, the web terminal, tini, and the /etc/agent/config.yaml ETL all
# live in coding-runtime. What is left here is the pi CLI plus the three files
# that describe it to the base: a manifest, an emitter, and a launcher.
#
# The base is pinned by tag *and* digest. Never :latest, and never a `main`
# build — metadata-action stamps those with the version literal `main`, which no
# `requires.codingRuntime` range can satisfy, so every boot would warn about a
# version mismatch that is not real.
# -----------------------------------------------------------------------------
ARG BASE=ghcr.io/language-operator/coding-runtime:0.1.6@sha256:318a540d9d062689d3ed6c0de34fb353ff076bb16c5770bcf296398c6e5a5412
ARG PI_VERSION=1.0.0

FROM ${BASE}
ARG PI_VERSION

USER root

# pi's find tool shells out to fd, and its grep tool to rg (the base has rg).
# Missing either, pi tries to download it at startup — into a read-only root,
# with PI_OFFLINE set — and the tool is simply unavailable. Debian names the
# binary `fdfind`, which pi looks for too.
RUN apt-get update && apt-get install -y --no-install-recommends fd-find \
    && rm -rf /var/lib/apt/lists/*

# pi CLI (TUI). Pinned — do not track `latest`, so runtime behaviour is
# reproducible. The package moved from @mariozechner/ to @earendil-works/ at
# 0.74; the old name is deprecated.
RUN npm install -g --no-audit --no-fund "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && npm cache clean --force

# runtime.json — what this adapter is: config dir, serving surface, tmux launch.
# emit.mjs     — normalized operator config -> pi's models/settings/mcp/AGENTS.md.
# launch-pi    — what tmux runs inside the terminal.
COPY runtime.json /etc/coding-runtime/runtime.json
COPY emit.mjs /opt/adapter/emit.mjs
COPY --chmod=755 launch-pi.sh /usr/local/bin/launch-pi

# The operator pins the agent container to uid 1000 with no override, and the
# base already has a matching passwd entry. Do not create a user here.
USER node
