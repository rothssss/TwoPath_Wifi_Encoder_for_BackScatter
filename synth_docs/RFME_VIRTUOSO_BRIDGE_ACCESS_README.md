# RFME Virtuoso Bridge Access README

Last verified: 2026-04-21

This note is the current access guide for the RFME Virtuoso bridge setup on `opus.ece.rice.edu`.

## Current live layout

The four configured Virtuoso sessions are:

1. `:96` as the default bridge
2. `:95` as profile `V95`
3. `:23` as profile `V23`
4. `:21` as profile `V21`

The existing `:96`, `:95`, and `:23` profiles were previously checked by direct SKILL probe. `:21` was added to the local bridge config on 2026-04-21 for the new VNC desktop `opus.ece.rice.edu:21`.

## Host and local config

- Remote host alias: `opus-vb`
- Real host: `opus.ece.rice.edu`
- Remote user: `na73`
- Bridge repo: `C:\Users\nav\Documents\virtuoso-bridge-lite`
- RFME workspace: `C:\Users\nav\Box\Student-Naveed\Paper\RFME`
- Bridge env file: `C:\Users\nav\.virtuoso-bridge\.env`
- SSH config file: `C:\Users\nav\.ssh\config`

Current `.env` settings:

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

## Instance map

| Display | Profile | Local port | Remote daemon port | Remote setup file |
|---|---|---:|---:|---|
| `:96` | default | `65082` | `65081` | `/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il` |
| `:95` | `V95` | `65092` | `65091` | `/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge/virtuoso_setup.il` |
| `:23` | `V23` | `65112` | `65111` | `/home/na73/.cache/virtuoso_bridge_na73_V23/virtuoso_bridge/virtuoso_setup.il` |
| `:21` | `V21` | `65122` | `65121` | `/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge/virtuoso_setup.il` |

## Recommended way to bring the tunnels up

Use one combined SSH forward instead of four separate windows:

```powershell
ssh -N `
  -L 65082:127.0.0.1:65081 `
  -L 65092:127.0.0.1:65091 `
  -L 65112:127.0.0.1:65111 `
  -L 65122:127.0.0.1:65121 `
  opus-vb
```

Leave that window open.

If it dies, all four local tunnels go down together.

## CIW load commands

Run these in the matching Virtuoso CIWs when a daemon needs to be reloaded.

For `:96`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il")
```

For `:95`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge/virtuoso_setup.il")
```

For `:23`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V23/virtuoso_bridge/virtuoso_setup.il")
```

For `:21`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge/virtuoso_setup.il")
```

If the CIW prints `RAMIC Bridge ... is already running`, that is fine.

## How to check the bridges

### Direct daemon probe

This is the strongest check because it actually exercises the bridge.

```powershell
& 'C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe' -c "from virtuoso_bridge import VirtuosoClient; c=VirtuosoClient.from_env(); r=c.execute_skill('1+2'); print('DEFAULT', r.status, repr(r.output), r.errors); c=VirtuosoClient.from_env(profile='V95'); r=c.execute_skill('1+2'); print('V95', r.status, repr(r.output), r.errors); c=VirtuosoClient.from_env(profile='V23'); r=c.execute_skill('1+2'); print('V23', r.status, repr(r.output), r.errors); c=VirtuosoClient.from_env(profile='V21'); r=c.execute_skill('1+2'); print('V21', r.status, repr(r.output), r.errors)"
```

Healthy output is:

- `DEFAULT ExecutionStatus.SUCCESS '3' []`
- `V95 ExecutionStatus.SUCCESS '3' []`
- `V23 ExecutionStatus.SUCCESS '3' []`
- `V21 ExecutionStatus.SUCCESS '3' []`

### CLI status

These are still useful, but the direct probe above is the better truth source.

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\virtuoso-bridge.exe status
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\virtuoso-bridge.exe status -p V95
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\virtuoso-bridge.exe status -p V23
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\virtuoso-bridge.exe status -p V21
```

### Quick helper script

The helper script for one-off SKILL calls is:

`C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py`

Examples:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py "1+2"
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V95 "1+2"
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V23 "1+2"
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --profile V21 "1+2"
```

## What failures mean

### Tunnel down

Symptoms:

- `Connection refused` to `127.0.0.1:65082`, `65092`, `65112`, or `65122`
- no local listener on the port
- no live `ssh.exe -N -L ...` process

Fix:

1. Re-open the combined SSH forward command.
2. Re-check the direct daemon probe.

### Tunnel up, daemon down

Symptoms:

- local ports are listening
- but probes fail with socket close errors like `WinError 10054`

Fix:

1. Keep the tunnel alive.
2. Re-run the matching `load("...virtuoso_setup.il")` command in that CIW.
3. Re-test with the direct daemon probe.

## Watchdog

There is also a local watchdog script:

`C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1`

Useful modes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode status
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode once
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode start-hidden
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1 -Mode stop
```

Important limitation:

- it can restore local SSH forwards and state files
- it cannot force a dead bridge daemon inside Virtuoso to reload
- CIW `load(...)` is still the manual recovery step for daemon failures

## Related files

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_3_INSTANCE_README.md`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_watchdog.ps1`
- `C:\Users\nav\Documents\virtuoso-bridge-lite\src\virtuoso_bridge\transport\remote_paths.py`
- `C:\Users\nav\Documents\virtuoso-bridge-lite\src\virtuoso_bridge\transport\tunnel.py`
- `C:\Users\nav\Documents\virtuoso-bridge-lite\src\virtuoso_bridge\virtuoso\basic\bridge.py`
