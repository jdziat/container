# Running the live behavioral gate in CI

`make parity-behavioral` boots real VMs, so it cannot run on GitHub-hosted runners (no nested
virtualization). It runs from `.github/workflows/common.yml` on a self-hosted runner. The hosted
`static-parity.yml` workflow is separate and is **not** evidence that behavior works; it only
checks build, unit tests, that every command's `--help` parses, and compose doc drift.

## Enable it on a fork

1. Register a self-hosted runner on the repository: **macOS 26, Apple silicon**, with Xcode 26.4+
   and the labels `self-hosted, macos, goldengate, ARM64` (the labels `common.yml` requests).
2. Set a repository variable (Settings, Secrets and variables, Actions, Variables):
   `LIVE_GATE_ENABLED = true`.
3. Open or update a pull request. `Build and test the project` now runs, including the
   `Docker parity (behavioral)` step.

Until step 2, the jobs are skipped on forks exactly as before (they run only for `apple/container`).

## Safety

The gate stops any running system and starts its own on an isolated app root (`APP_ROOT`, default
`./.test-data`). The live harnesses also verify the running apiserver's `paths.appRoot` matches
and refuse otherwise, so they never touch a developer's real containers, volumes or networks.
**Do not register the runner on a machine you use interactively** with containers you care about:
the gate runs `container system stop` first, as `make integration` does.

## What a green run establishes

Cite a green run of this gate as "live harnesses run in CI on an isolated root". Do not cite the
hosted static workflow for that.
