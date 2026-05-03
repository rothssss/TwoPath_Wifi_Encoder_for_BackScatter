# RFME Virtuoso Bridge Direct-Connect Fallback

Last verified: 2026-04-21

This note is the no-SSH fallback when TigerVNC works but SSH port forwarding does not.

## Why this exists

From this machine:

- `opus.ece.rice.edu:22` was timing out, so SSH forwarding could not be used.
- The usual bridge ports `65081`, `65091`, `65111`, and `65121` were not reachable directly.
- VNC-facing ports such as `5921`, `5923`, `5995`, and `5996` were reachable.

That strongly suggests the bridge can still work if the Virtuoso daemon is moved onto an unused public `59xx` port that the server firewall already allows.

The RAMIC bridge already supports this:

- it binds to `0.0.0.0` when `RBLocal=nil`
- the local helper can now connect directly to a host and port without SSH

## Proposed port map

Use a separate public port for each session:

| Display | Session | Direct bridge port |
|---|---|---:|
| `:96` | default | `5950` |
| `:95` | `V95` | `5951` |
| `:23` | `V23` | `5952` |
| `:21` | `V21` | `5953` |

These are intentionally different from the VNC ports themselves.

## Important bring-up rule

Do **not** use `RBStopAll()` for normal multi-session bring-up.

`RBStopAll()` is a global emergency kill. It kills every `ramic_bridge_daemon`
process it can find for your user, so bringing up one session that way can tear
down the others.

For normal use:

- use `RBStop()` only for the current Virtuoso session
- keep a unique `RBPort` per session
- reserve `RBStopAll()` for recovery when a port is wedged and you are okay
  restarting every bridge afterward

## CIW commands

Run the matching setup file in the target CIW first, then stop the just-loaded
session daemon, change the port, and restart it.

For `:96`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5950
RBStart()
```

For `:95`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5951
RBStart()
```

For `:23`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V23/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5952
RBStart()
```

For `:21`:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5953
RBStart()
```

If Virtuoso reports the port is already in use, pick another unused `59xx` port for that session and retry.

If the `:21` setup file is missing on the server, load any already-deployed
working setup file first so `RBStart`, `RBStop`, and friends are defined, then
override `RBPort` for `:21`.

## Server copy sheet

There is also a plain-text copy/paste helper on the server at:

`/home/na73/Downloads/RFME_bridge_direct_commands.txt`

It contains the corrected CIW bring-up snippets for all four sessions plus the
`:21` fallback.

## Local test commands

Use the helper script in direct mode:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5950 "1+2"
```

Other sessions:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5951 "1+2"
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5952 "1+2"
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5953 "1+2"
```

Healthy output is:

- `3`

## Important limitations

- This bypasses the existing SSH tunnel/watchdog flow entirely.
- `virtuoso-bridge.exe status` will not reflect these direct connections.
- Each CIW needs to be loaded manually because there is no SSH control path.
- Keep the chosen ports unique and avoid the actual VNC session ports.
