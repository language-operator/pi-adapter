---
description: Bring every pinned upstream dependency up to date, with an audit trail
argument-hint: "[all|base|pi|actions] (default: all)"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(npm:*), Bash(curl:*), Bash(jq:*), Bash(docker:*), Bash(helm:*), Bash(make:*), Bash(diff:*), Read, Edit, Grep
---

Update the upstream dependencies of `pi-adapter`. Scope: **$ARGUMENTS** (empty means `all`).

This runs for security and compliance: the point is not only that versions move, but that
the move is **recorded** — old version, new version, digest, and what changed — so the PR
is the audit trail. A bump with no evidence behind it is worse than no bump, because it
looks reviewed.

## The dependency surface

This repo vendors almost nothing of its own; it is a thin layer over a base image. There
are four groups.

**1. The `coding-runtime` base image** — the OS layer, the web terminal, `tini`, and the
config ETL all come from here, so this is the security-relevant one.

| Location | Form |
|---|---|
| `Dockerfile` `ARG BASE` | `ghcr.io/language-operator/coding-runtime:X.Y.Z@sha256:…` — tag **and** digest |

`ARG BASE` is now the only place the base version appears: since base `0.1.1` the
conformance suite ships inside the image and CI extracts it from the build, so there is no
separate suite version to keep in step.

**2. The pi CLI** — `Dockerfile` `ARG PI_VERSION`, installed as the npm package
`@earendil-works/pi-coding-agent` (formerly `@mariozechner/pi-coding-agent`, deprecated
since 0.74 — never go back to it).

**3. GitHub Actions** — across `.github/workflows/{test,build-image,release-chart}.yaml`:
`actions/checkout`, `docker/setup-buildx-action`, `docker/login-action`,
`docker/metadata-action`, `docker/build-push-action`, `azure/setup-helm`.

**4. Vendored upstream files** — `runtime.json` and `emit.mjs` are meant to be **verbatim
copies** of `examples/pi/` in `coding-runtime`. Nothing fails here when they drift from
upstream, which is exactly why they get missed. Re-copy and diff them whenever the base
moves. If the base tag has no `examples/pi/` yet, this repo is the source of truth: say so
in the PR and skip the re-copy rather than inventing one.

## Rules that must not be broken

- **Pin the base by tag *and* digest.** Never `:latest`.
- **Never pin a `main` or `sha-` build of the base.** `metadata-action` stamps those with
  the version literal `main`, which no `requires.codingRuntime` range in `runtime.json` can
  satisfy — every boot warns about a mismatch that is not real — and which also fails the
  conformance suite's own `reports a version` check, since that asserts semver. Only
  released semver tags.
- **pi: take the `latest` dist-tag only.** The package also publishes `legacy-node20`,
  a maintenance line for an older Node; the base ships Node 24, so it never belongs here.
- **Do not unpin anything to make an update easier.** If a pin is in the way, that is the
  finding — report it rather than loosening it.

## Steps

Stop and report if any precondition fails; do not continue past a failure.

**1. Preconditions.**
- On `main`, working tree clean (`git status --porcelain` empty), `git fetch origin` and
  confirm `main` is not behind `origin/main`.
- Create a branch, with something distinctive in the name —
  `git checkout -b chore/deps-<what-moved>`. Never work on `main`, and do not reuse a
  bare `chore/update-dependencies`: PRs here are squash-merged, so the old branch survives
  on the remote and its commits are not ancestors of `main`, which makes the next run's
  push a non-fast-forward rejection.

**2. Record the current state.** Read every pin listed above and write them down — this is
the "before" column of the audit trail.

```bash
grep -nE 'ARG (BASE|PI_VERSION)' Dockerfile
grep -rn 'uses: .*@' .github/workflows/
```

**3. Discover the latest versions.** These commands are known to work here.

Base image — released semver tags only, then resolve the digest of the one you pick:

```bash
T=$(curl -s "https://ghcr.io/token?scope=repository:language-operator/coding-runtime:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $T" \
  "https://ghcr.io/v2/language-operator/coding-runtime/tags/list?n=1000" \
  | jq -r '.tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -5

curl -sI -H "Authorization: Bearer $T" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/language-operator/coding-runtime/manifests/<X.Y.Z>" \
  | grep -i docker-content-digest
```

pi CLI — the `latest` dist-tag, and its Node requirement (must be satisfied by the base):

```bash
npm view @earendil-works/pi-coding-agent dist-tags engines --json
```

If npm fails with `ENOENT … mkdir '/home/node/.npm'`, the cache directory is read-only in
this environment; re-run with `npm_config_cache="$(mktemp -d)"` prefixed.

GitHub Actions — latest release per action:

```bash
for a in actions/checkout docker/setup-buildx-action docker/login-action \
         docker/metadata-action docker/build-push-action azure/setup-helm; do
  printf '%s: %s\n' "$a" "$(gh api "repos/$a/releases/latest" --jq .tag_name)"
done
```

**4. Read what changed, before editing anything.** For each dependency that has moved,
fetch the release notes and check for advisories. This is the compliance half of the task
and it is not optional:

```bash
gh release view <tag> --repo <owner>/<repo>            # release notes
gh api repos/<owner>/<repo>/security-advisories --jq '.[] | "\(.ghsa_id) \(.severity) \(.summary)"'
```

Note anything that reads as a security fix, and anything that reads as a breaking change.
A major-version jump in an action is a deliberate decision, not a routine bump — if the
notes describe a breaking change, either handle it in this PR or leave that pin alone and
record why.

**5. Apply the updates** for the requested scope.

- **Base:** update `ARG BASE` with the new tag **and** its digest.
- **Vendored files:** re-copy from the new base tag and diff before committing, so an
  upstream change to the emitter or manifest is seen rather than silently kept or silently
  clobbered:

  ```bash
  gh api repos/language-operator/coding-runtime/contents/examples/pi/runtime.json?ref=<vX.Y.Z> --jq .content | base64 -d > /tmp/runtime.json
  gh api repos/language-operator/coding-runtime/contents/examples/pi/emit.mjs?ref=<vX.Y.Z>   --jq .content | base64 -d > /tmp/emit.mjs
  diff -u runtime.json /tmp/runtime.json; diff -u emit.mjs /tmp/emit.mjs
  ```

  If either differs, take the upstream copy and describe the change in the PR. If
  `runtime.json` gained a field this adapter should set, that is a real decision — surface
  it rather than copying past it.
- **pi:** update `ARG PI_VERSION`. pi rewrites its own config schema between releases
  (models.json, settings.json, mcp.json), and nothing here tests the emitter against the
  new CLI: install it locally, seed a config with the emitter, and run
  `pi --list-models` and `pi mcp list` against it before committing.
- **Actions:** update the `uses:` pins.

**6. Re-read how the suite is obtained.** CI and `make test` extract
`/opt/coding-runtime/test/conformance.sh` from the built image. If a future base moves or
renames it, that breaks loudly rather than silently — fix the extraction, do not go back to
fetching a tag, which is what let the suite drift from the runtime in the first place.

**7. Verify.**

```bash
helm lint chart && helm template pi chart >/dev/null
make test        # builds the image and runs the conformance suite; needs Docker
```

If Docker is unavailable in this environment, say so plainly rather than implying the suite
ran — CI runs it on the PR, and the PR is where the evidence should land.

**8. Commit and open a PR.** One commit per dependency group, so a bad bump reverts on its
own. Never push to `main`; never tag — releasing is `/release`, and it is a separate
decision from updating. Merging is safe: chart publishing is restricted to `v*` tags, so a
merge does not publish anything.

The PR body is the audit record. For each dependency:

| | |
|---|---|
| Dependency | `ghcr.io/language-operator/coding-runtime` |
| Before → after | `0.1.0` → `0.1.1` |
| Digest | `sha256:…` |
| Notes | link to the release, one line on what changed |
| Security | the advisory it addresses, or "no advisories in range" |

End with what you did **not** update and why — a held-back major, a pin with a breaking
change, a dependency with no newer release. An empty "not updated" section should be
written as such, not omitted.

**9. Report.** Summarize what moved, what did not, and anything that needs a human decision.
If a bump carries a breaking change that this repo has to absorb — the `HOME` relocation in
the `0.1.0` migration is the worked example — say so explicitly and do not bury it in the
diff.
