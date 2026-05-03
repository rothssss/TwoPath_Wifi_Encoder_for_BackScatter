# RFME Virtuoso Bridge Multi-Instance README

This note documents the current multi-instance Virtuoso bridge layout for the RFME project on `opus.ece.rice.edu`.

## Overview

The configured layout is:

1. `:96` as the default bridge
2. `:95` as profile `V95`
3. `:23` as profile `V23`
4. `:21` as profile `V21`

The established bridges are `:96`, `:95`, and `:23`. The new `:21` bridge profile was added on 2026-04-21 for the new VNC desktop.

## Instance map

| Display | Bridge profile | Local port | Remote daemon port | Remote bridge directory | Intended use |
|---|---|---:|---:|---|---|
| `:96` | default | `65082` | `65081` | `/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge` | Main working bridge |
| `:95` | `V95` | `65092` | `65091` | `/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge` | Second parallel bridge |
| `:23` | `V23` | `65112` | `65111` | `/home/na73/.cache/virtuoso_bridge_na73_V23/virtuoso_bridge` | Third parallel bridge |
| `:21` | `V21` | `65122` | `65121` | `/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge` | Fourth parallel bridge |

## Current status

The established bridges report:

- tunnel running
- daemon OK
- spectre OK

They were verified both through `virtuoso-bridge status` and by direct SKILL calls returning `3` on the established local forwarded ports. `V21` was added afterward and should be loaded in the `:21` CIW before probing.

## Local env file

The active bridge config is:

- [C:\Users\nav\.virtuoso-bridge\.env](/C:/Users/nav/.virtuoso-bridge/.env)

Relevant entries:

```dotenv
VB_REMOTE_HOST=opus-vb
VB_REMOTE_USER=na73
VB_REMOTE_PORT=65081
VB_LOCAL_PORT=65082
VB_REMOTE_SCRATCH_ROOT=/home/na73/.cache
VB_CADENCE_CSHRC=/home/na73/.virtuoso_bridge_cadence.csh

VB_REMOTE_HOST_V95=opus-vb
VB_REMOTE_USER_V95=na73
VB_REMOTE_PORT_V95=65091
VB_LOCAL_PORT_V95=65092

VB_REMOTE_HOST_V23=opus-vb
VB_REMOTE_USER_V23=na73
VB_REMOTE_PORT_V23=65111
VB_LOCAL_PORT_V23=65112

VB_REMOTE_HOST_V21=opus-vb
VB_REMOTE_USER_V21=na73
VB_REMOTE_PORT_V21=65121
VB_LOCAL_PORT_V21=65122
```

## Commands to use each instance

### Status checks

```powershell
virtuoso-bridge status
virtuoso-bridge status -p V95
virtuoso-bridge status -p V23
virtuoso-bridge status -p V21
```

### Quick SKILL smoke test

Default `:96`:

```powershell
python C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py "1+2"
```

`V95` on `:95`:

```powershell
python C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V95 "1+2"
```

`V23` on `:23`:

```powershell
python C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V23 "1+2"
```

`V21` on `:21`:

```powershell
python C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V21 "1+2"
```

## Important distinctions

- The default bridge is `:96`, not `:95`, `:23`, or `:21`.
- `V95` must always be addressed explicitly with `-p V95` or `--profile V95`.
- `V23` must always be addressed explicitly with `-p V23` or `--profile V23`.
- `V21` must always be addressed explicitly with `-p V21` or `--profile V21`.
- The bridge repo was patched so profile-specific sessions use different remote staging directories. This prevents `:96`, `:95`, `:23`, and `:21` from overwriting each other's bridge files.

## Manual forward note

The current multi-session setup was recovered using manual SSH local forwards on Windows rather than only `virtuoso-bridge start`. To make the CLI reflect reality, local state files were restored for:

- default profile
- `V95`
- `V23`
- `V21`

This is why `virtuoso-bridge status` is accurate again even though the forwarding windows may have been started manually.

## Active restore watchdog

A local watchdog script now exists to actively keep the SSH forwards alive and restore bridge state if a tunnel drops:

- [rfme_virtuoso_bridge_watchdog.ps1](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_virtuoso_bridge_watchdog.ps1)

Supported modes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode status
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode once
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode start-hidden
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode stop
```

Current behavior:

- monitors `:96`, `:95`, `:23`, and `:21`
- checks local forwarded ports
- removes stale `ssh.exe` tunnel processes
- recreates missing SSH forwards
- refreshes the local `state.json`, `state_V95.json`, `state_V23.json`, and `state_V21.json` files so `virtuoso-bridge status` stays accurate

Current watchdog status:

- running hidden in the background
- PID file: `C:\Users\nav\.cache\virtuoso_bridge\rfme_bridge_watchdog.pid`
- log file: `C:\Users\nav\.cache\virtuoso_bridge\rfme_bridge_watchdog.log`

Important limitation:

- the watchdog restores tunnels and local bridge state
- it does not automatically reload a dead RAMIC daemon into a Virtuoso CIW
- if a daemon is unloaded inside Virtuoso, reload the matching `virtuoso_setup.il` in that CIW

## Related files

- [RFME_AUTONOMOUS_FLOW_HANDOFF.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_AUTONOMOUS_FLOW_HANDOFF.md)
- [rfme_virtuoso_bridge_exec.py](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/rfme_virtuoso_bridge_exec.py)
- [cli.py](/C:/Users/nav/Documents/virtuoso-bridge-lite/src/virtuoso_bridge/cli.py)
- [remote_paths.py](/C:/Users/nav/Documents/virtuoso-bridge-lite/src/virtuoso_bridge/transport/remote_paths.py)
- [tunnel.py](/C:/Users/nav/Documents/virtuoso-bridge-lite/src/virtuoso_bridge/transport/tunnel.py)
- [bridge.py](/C:/Users/nav/Documents/virtuoso-bridge-lite/src/virtuoso_bridge/virtuoso/basic/bridge.py)
