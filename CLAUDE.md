# CLAUDE.md

Guidance for working in the `pi-adapter` repository.

## What this is

A [Language Operator](https://github.com/language-operator) **runtime** that runs the
**pi** coding agent TUI (`@earendil-works/pi-coding-agent`) as a Kubernetes workload. The
TUI runs inside tmux and is fronted by an xterm.js / WebSocket terminal, so working with
the agent feels like a real terminal session.

It is a **thin layer over
[`coding-runtime`](https://github.com/language-operator/coding-runtime)**. The base owns
the OS layer, the web terminal (node-pty over a WebSocket, with a cross-origin guard and
a keepalive), `tini`, and the ETL that turns the operator's `/etc/agent/config.yaml` into
a normalized config. This repo adds the pi CLI plus three files that describe it to the
base.

One container, running the base entrypoint: resolve the environment, seed config, serve.
There is **no init container**. Seeding happens in the agent container, because the
operator mounts `/tmp` there only, so an init container would share no writable path with
it.

## Key files

- `Dockerfile`: `FROM ${BASE}`, plus `fd-find` (pi's find tool needs `fd`/`fdfind`; the
  base has `rg`) and `npm install -g @earendil-works/pi-coding-agent`. `ARG BASE` pins the
  base by **tag and digest**, and is the only place the base version appears.
- `runtime.json`: the manifest. It sets `PI_CODING_AGENT_DIR=${STATE_DIR}/pi`,
  `PI_OFFLINE=1` (no startup update checks or telemetry), the serving surface, and how
  tmux launches the TUI.
- `emit.mjs`: the emitter. Normalized config becomes four files in the agent directory:
  - `models.json` `providers`, owned in full: the gateway as provider `langop`. It is `{}`,
    never absent, because pi rejects a models.json without it.
  - `settings.json` `defaultProvider`/`defaultModel`/`enableInstallTelemetry`.
  - `mcp.json` `mcpServers`.
  - `AGENTS.md`, rewritten every run and empty when there is nothing to say, because the
    base never deletes a file an emitter stops mentioning.

  pi interpolates `$NAME`/`${NAME}`, and **runs any value starting with `!` as a shell
  command**. The emitter refuses such a header and falls back from such a gateway key;
  keep that guard.
- `runtime.json` and `emit.mjs` are **verbatim copies** of upstream
  `coding-runtime/examples/pi/`, like the other adapters, and coding-runtime's
  `example-drift.yaml` fails when they differ from this repo's `main`. Change both sides
  together: an emitter change here needs a matching PR there (goldens included), merged
  after this one, since the drift check compares against `main`.
- `launch-pi.sh`: what tmux runs, `pi --continue`. Unlike opencode it needs no "has a
  session store" guard. With nothing to resume, pi just starts a new session.
- `chart/`: the Helm chart registering the cluster-scoped `LanguageAgentRuntime` named
  `pi`.
- `.github/workflows/` — `test.yaml`, `build-image.yaml`, `release-chart.yaml`.

## Testing

- `make test` — builds the image and runs coding-runtime's conformance suite in `adapter`
  mode. The suite is **extracted from the image under test**, so the checks always match
  the runtime being checked; it runs the container the way the operator does (read-only
  root, uid 1000, all capabilities dropped). Needs Docker.
- `make lint-chart` — `helm lint chart` plus `helm template pi chart`.
- There is **no linter and no unit-test suite**. CI correctness is exactly the two
  `test.yaml` jobs: `image-test` and `chart-lint`.
- Changes to the terminal, the emitter or the manifest are mostly **not** covered by
  anything local — the conformance suite checks the runtime contract, not pi's
  behaviour. Say so plainly rather than implying a green build proves more than it does.
  To check the emitter against the real CLI, seed into a temp dir and run
  `pi --list-models` and `pi mcp list` with `PI_CODING_AGENT_DIR` pointed at it.
- The PR title must be a conventional commit (`feat:`, `fix:`, `chore:`, `docs:`).

## Build & dev deploy

- `make build` — build `ghcr.io/language-operator/pi-adapter:<git-sha>` + `:latest`.
- `make dev` — build, import into local k3s, and `helm upgrade` the runtime (requires the
  `language-operator` chart / `LanguageAgentRuntime` CRD installed first).
- `make publish` — push image tags to ghcr.io. `make uninstall` — remove the release.

## Releases

Cut a release with `/release major|minor|patch` (`.claude/commands/release.md`). Version
is kept in **lockstep**: `chart/Chart.yaml` `version` + `appVersion`, `chart/values.yaml`
`image.tag`, and the git tag `vX.Y.Z` all become the same `X.Y.Z`. Pushing a `v*` tag
triggers `build-image.yaml` and `release-chart.yaml`.

Two rules the hard way:

- **Chart publishing is restricted to `v*` tags.** It once ran on every push to `main`,
  which republished an already-published chart version in place — pairing a new template
  with the old image it names. `release-chart.yaml` also refuses to push a version that
  already exists.
- **Never pin a `main` or `sha-` build of the base.** Those record their version literal
  as `main`, which no `requires.codingRuntime` range can satisfy, and which fails the
  conformance suite's own semver check. Released tags only.

Bumping the base, the pi CLI or the GitHub Actions is `/update-dependencies`, not
`/release` — they are separate decisions.

## Issue-driven workflow

`/iterate [#issue] [--auto]` handles **one** issue, from selection to a merged PR and a
closed issue, then stops. For continuous work, use `/loop /iterate`. Work happens inside a
git worktree under `.claude/worktrees/`.

It comes from the shared `langop` plugin in
[`language-operator/skills`](https://github.com/language-operator/skills), pinned to a tag
in `.claude/settings.json` — not from a copy in this repo, which is what it replaced.
`/iterate` and `/langop:iterate` both invoke it. There is nothing per-repo in the skill
itself: it reads `## Testing` above to learn how to test a change here, so keep that section
accurate.

Interactive sessions need no install step — the plugin loads at the pinned tag once the folder
is trusted. Non-interactive ones (`claude -p`, scheduled or in-cluster agents) have no trust
dialog, so they need this once, with the tag the repo pins:

```bash
claude plugin marketplace add 'language-operator/skills#v0.1.0'
claude plugin install langop@language-operator --scope project
```

Two things to avoid: a marketplace add without `#<tag>` follows `main` rather than the pin,
and `--scope project` on the *marketplace* add rewrites `.claude/settings.json` and drops
its `ref`. To take a newer release, change `ref` there.
