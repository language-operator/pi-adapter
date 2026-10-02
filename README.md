# pi-adapter

The **[pi](https://pi.dev)** coding-agent runtime for the [Language Operator](https://github.com/language-operator/language-operator),
running as a native Kubernetes workload.

It builds the runtime image and the Helm chart that registers the `pi`
`LanguageAgentRuntime`. The pi TUI runs inside tmux and is fronted by an
xterm.js / WebSocket terminal in the browser, so working with the agent feels like
a real terminal session.

## Architecture

The image is [`coding-runtime`](https://github.com/language-operator/coding-runtime)
plus the pi CLI (`@earendil-works/pi-coding-agent`) and `fd`, which pi's find tool
needs. The base owns the OS layer, the web terminal (xterm.js over a node-pty
WebSocket bridge, with a cross-origin guard and a 25s keepalive), `tini`, and the ETL
that turns the operator's `/etc/agent/config.yaml` into a normalized config. What
lives here is the three files that describe pi to it:

- **`runtime.json`**: the manifest. pi's agent directory is `$STATE_DIR/pi` (via
  `PI_CODING_AGENT_DIR`), `PI_OFFLINE=1` stops startup update checks and telemetry,
  and tmux runs `launch-pi`.
- **`emit.mjs`**: the emitter. It turns the normalized config into four files in the agent
  directory:
  - `models.json` registers the cluster gateway as the `langop` provider
    (OpenAI-compatible) with every model the agent has.
  - `settings.json` sets `defaultProvider` / `defaultModel` to the primary model.
  - `mcp.json` lists the agent's tools as remote MCP servers.
  - `AGENTS.md` holds the persona and instructions, loaded as global context in every
    session.

  pi itself writes `settings.json` and `mcp.json` too, so only the keys the emitter
  owns are managed there. Credentials are written as pi's `${NAME}` references, never
  values.
- **`launch-pi.sh`**: what tmux runs. The base has already set the working
  directory (the cloned repo when the agent sets `spec.repository`, else
  `/workspace`). It runs `pi --continue`, so an agent that is put to sleep and woken
  (a new pod, and with it a new tmux server) resumes its last conversation. With no
  session to resume, pi starts a new one.

One container, running the base entrypoint: resolve the environment, seed config,
serve. Seeding runs in the agent container rather than an init container because
the operator mounts `/tmp` there only, so the two would share no writable path.
tmux keeps the session alive across browser reconnects.

The siblings [`claude-code-adapter`](https://github.com/language-operator/claude-code-adapter)
and [`opencode-adapter`](https://github.com/language-operator/opencode-adapter) are the
same shape on the same base, swapping the CLI and the three files.

## Install

Prerequisite: the [`language-operator`](https://github.com/language-operator/language-operator)
chart must be installed first. It provides the `LanguageAgentRuntime` CRD.

```bash
helm install pi oci://ghcr.io/language-operator/charts/pi \
  --namespace language-operator
```

Then reference it from a `LanguageAgent`:

```yaml
apiVersion: langop.io/v1alpha1
kind: LanguageAgent
metadata:
  name: my-agent
spec:
  runtime: pi
```

## Authentication

The runtime sets `auth.enabled: true`, so access is gated entirely by the cluster's
OIDC proxy: when the `LanguageCluster` has auth enabled the operator injects an
oauth2-proxy sidecar in front of the terminal. There is no built-in password. If
the cluster does not enable auth, the terminal is exposed unauthenticated on its
ingress. pi itself reaches the model gateway via the `langop` provider in
`models.json`, so no interactive login is needed. `/login` still works for adding other
providers.

## Known limitations

- **Shift+Enter submits instead of inserting a newline.** pi needs tmux
  `extended-keys`, which the base's `/etc/tmux.conf` does not enable yet, and pi
  warns about this at startup. It has to be fixed in `coding-runtime`.
- **No task mode.** `runtime.json` declares no `task.exec`, so `spec.execution.mode: task`
  fails immediately with a message naming it.

## Development

```bash
make build      # docker build -t ghcr.io/language-operator/pi-adapter:latest .
make test       # build, then run the coding-runtime conformance suite
make publish    # build and push the image to ghcr.io
make dev        # build, import into k3s, and upgrade the runtime release (inner loop)

helm lint chart
helm template pi chart
```

## CI

- `build-image.yaml` builds and pushes the image to `ghcr.io` on push to `main` and `v*` tags.
- `release-chart.yaml` packages `chart/` and pushes it to `oci://ghcr.io/language-operator/charts`
  on `v*` tags.
- `test.yaml` builds the image, runs the `coding-runtime` conformance suite against
  it under the operator's posture (read-only root, uid 1000, all capabilities dropped),
  and lints/templates the chart on every PR. The suite is taken out of the image rather
  than fetched, so the checks always match the runtime being checked, and no failures are
  tolerated.
