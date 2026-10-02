#!/bin/sh
# Config — gateway provider, default model, MCP servers, standing instructions —
# is read from $PI_CODING_AGENT_DIR (models.json, settings.json, mcp.json,
# AGENTS.md), written by `coding-runtime seed`. The base already starts tmux in
# the working directory, which is the project pi opens on.
#
# Sessions live under $PI_CODING_AGENT_DIR/sessions on the workspace PVC, which
# outlives the pod. Sleeping an agent destroys the pod and waking it makes a new
# one, and this exec is the only moment a resume decision can be made — tmux is
# started with `new-session -A`, so on a reconnect to a live pod the launcher is
# never re-run. Without --continue a woken agent always opens blank on a
# conversation the user can still see the history of.
#
# Unlike opencode, pi needs no guard here: with no session to resume, --continue
# simply starts a new one.
set -eu

exec pi --continue
