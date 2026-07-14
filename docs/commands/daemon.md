# `codex-auth daemon`

## Usage

```shell
codex-auth daemon --watch [--5h <percent>] [--weekly <percent>] [--interval <seconds>]
codex-auth daemon --once [--5h <percent>] [--weekly <percent>]
```

`--watch` runs the persistent worker used by the managed user service.
`--once` runs one refresh and switch cycle. Normal users should manage the
worker with `codex-auth config auto enable|disable`.

The defaults are 2% remaining for each limit and a 60-second watch interval.
