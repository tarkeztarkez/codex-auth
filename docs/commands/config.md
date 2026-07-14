# `codex-auth config`

## Usage

```shell
codex-auth config auto enable [--5h <percent>] [--weekly <percent>] [--interval <seconds>]
codex-auth config auto disable
codex-auth config live --interval <seconds>
```

## Background Auto Switch

`config auto enable` installs, enables, and starts the per-user background
watcher. The default thresholds are 2% remaining for both the 5-hour and
weekly windows, with a 60-second refresh interval. A candidate is selected
only after a successful current API refresh and only when it remains above
both configured thresholds.

On Linux the watcher is installed as
`codex-auth-autoswitch.service` under `systemd --user`.

`config auto disable` stops and removes the watcher.

## Live Refresh Config

`config live --interval <seconds>` sets the live TUI refresh interval.

- Allowed range: `5` to `3600`.
- Stored in `registry.json` as top-level `interval_seconds`.

## API Refresh

API-backed refresh is the default for supported foreground paths. Use per-command `--skip-api` to run a foreground command with local data only. Older `registry.json` files may contain an `api` object; current builds ignore it and omit it on the next registry save.

API behavior and endpoint details live in [docs/api.md](../api.md).
