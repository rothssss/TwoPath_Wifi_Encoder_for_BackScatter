# RFME Virtuoso Bridge New Computer Setup

Last verified: 2026-04-25

This is the end-to-end setup guide for bringing a brand-new Windows machine to
the current RFME Virtuoso workflow on `opus.ece.rice.edu`.

It covers:

- installing the local bridge client
- setting up SSH aliases and env files
- opening the Virtuoso VNC desktops
- starting the RAMIC bridge daemons inside each Virtuoso session
- using the current direct-connect method that does not rely on SSH port forwarding

## Current recommended method

Use the **direct-connect bridge** as the default workflow.

Why:

- TigerVNC access to `opus.ece.rice.edu` works reliably
- SSH port forwarding to `opus.ece.rice.edu:22` may be blocked on some networks
- the bridge daemon can listen on public `59xx` ports, and the local helper can
  connect to those ports directly

The current direct port map is:

| Display | Session | Direct bridge port |
|---|---|---:|
| `:96` | default | `5950` |
| `:95` | `V95` | `5951` |
| `:23` | `V23` | `5952` |
| `:21` | `V21` | `5953` |

## What to install locally

On the new Windows machine, install:

1. Python `3.9+`
2. Git
3. OpenSSH client
4. TigerVNC Viewer

Recommended local paths:

- bridge repo: `C:\Users\<you>\Documents\virtuoso-bridge-lite`
- RFME workspace: `C:\Users\<you>\Box\Student-Naveed\Paper\RFME`
- bridge env file: `C:\Users\<you>\.virtuoso-bridge\.env`
- SSH config file: `C:\Users\<you>\.ssh\config`

## Step 1: Clone and install the bridge repo

In PowerShell:

```powershell
cd $HOME\Documents
git clone https://github.com/Arcadia-1/virtuoso-bridge-lite.git
cd .\virtuoso-bridge-lite
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -e .
```

Quick sanity check:

```powershell
.\.venv\Scripts\virtuoso-bridge.exe --help
```

## Step 2: Set up SSH alias and key

Create `C:\Users\<you>\.ssh\config` with:

```sshconfig
Host opus-vb
    HostName opus.ece.rice.edu
    User na73
    IdentityFile C:\Users\<you>\.ssh\id_ed25519_opus
```

Notes:

- Replace `<you>` with the local Windows username.
- Put your private key at the path you reference in `IdentityFile`.
- This SSH alias is still useful even though direct-connect is the preferred method.

Optional quick test:

```powershell
ssh -G opus-vb
```

If your network allows SSH:

```powershell
ssh opus-vb "hostname"
```

## Step 3: Create the bridge env file

Create `C:\Users\<you>\.virtuoso-bridge\.env` with:

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

This is the same multi-profile layout used on the current machine. Even though
the direct-connect path does not use these local tunnel ports day-to-day, keep
this file because:

- the bridge repo expects it
- the old SSH-tunnel flow still works on networks where port `22` is open
- the profiles document the remote setup-file layout clearly

## Step 4: Make sure the RFME helper script exists locally

You want this helper in your RFME workspace:

`C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py`

It supports both:

- profile/tunnel mode
- direct `--host/--port` mode

Current direct-connect usage looks like:

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5950 "1+2"
```

## Step 5: Open the Virtuoso desktops in TigerVNC

Open these VNC sessions:

- `opus.ece.rice.edu:96`
- `opus.ece.rice.edu:95`
- `opus.ece.rice.edu:23`
- `opus.ece.rice.edu:21`

Log into each desktop and bring up the intended Virtuoso session.

## Step 6: Start the bridge in each Virtuoso CIW

This is the important part.

Do **not** use `RBStopAll()` for normal bring-up.

Why:

- `RBStopAll()` is a global kill
- it can kill every bridge daemon for your user
- that makes one session coming up tear the others down

Use `RBStop()` only.

### `:96`

```skill
load("/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5950
RBStart()
```

### `:95`

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5951
RBStart()
```

### `:23`

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V23/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5952
RBStart()
```

### `:21`

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5953
RBStart()
```

### `:21` fallback if the `V21` setup file is missing

If the `V21` setup file has not been deployed on the server yet, use any already
working setup file just to define `RBStart`, `RBStop`, and friends, then switch
to the `:21` port:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5953
RBStart()
```

## Step 7: Verify each bridge from the new computer

Run these in PowerShell.

### Check `:96`

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5950 "1+2"
```

### Check `:95`

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5951 "1+2"
```

### Check `:23`

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5952 "1+2"
```

### Check `:21`

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5953 "1+2"
```

Healthy output is:

- `3`

If you want a stronger check:

```powershell
C:\Users\<you>\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py --host opus.ece.rice.edu --port 5952 "getVersion(t)"
```

Healthy output looks like:

- `"sub-version  IC6.1.8-64b.500.33 "`

## Step 8: Optional legacy SSH-tunnel mode

If the new computer is on a network where `ssh opus-vb` works, you can still use
the older tunnel-based mode.

Combined tunnel command:

```powershell
ssh -N `
  -L 65082:127.0.0.1:65081 `
  -L 65092:127.0.0.1:65091 `
  -L 65112:127.0.0.1:65111 `
  -L 65122:127.0.0.1:65121 `
  opus-vb
```

But the current recommendation is still:

- use VNC for desktop access
- use direct bridge ports `5950` to `5953`

## Server-side helper file

There is also a plain-text command sheet on the server:

`/home/na73/Downloads/RFME_bridge_direct_commands.txt`

That file contains the corrected CIW bring-up snippets for all four sessions and
the `:21` fallback.

## Common failure modes

### `Connection refused` to `5950`/`5951`/`5952`/`5953`

Meaning:

- the daemon is not listening on that public port yet
- or the CIW commands did not actually change the port

Fix:

1. Re-run the CIW snippet for that session.
2. Make sure you used `RBStop()`, not `RBStopAll()`.
3. Re-run the local `1+2` probe.

### `unbound variable - then`

Meaning:

- you used an invalid SKILL expression like `when(... then ...)`

Fix:

- use `RBStop()` directly
- do not wrap it in a `when(... then ...)` expression

### Only one session stays up at a time

Meaning:

- `RBStopAll()` was used

Fix:

- restart the sessions using the corrected snippets
- each session must keep its own port
- use only `RBStop()`

### `:21` says the setup file is missing

Meaning:

- `/home/na73/.cache/virtuoso_bridge_na73_V21/virtuoso_bridge/virtuoso_setup.il`
  does not exist on the server yet

Fix:

- use the `:21` fallback snippet above

## Files to keep handy

- local new-computer setup: `C:\Users\<you>\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_NEW_COMPUTER_SETUP_README.md`
- current direct workflow: `C:\Users\<you>\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md`
- older tunnel workflow: `C:\Users\<you>\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_ACCESS_README.md`
- helper script: `C:\Users\<you>\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py`
- server copy sheet: `/home/na73/Downloads/RFME_bridge_direct_commands.txt`

## Final expected state

When the machine is fully set up:

- TigerVNC can open `:96`, `:95`, `:23`, and `:21`
- each CIW has a bridge daemon listening on `5950`, `5951`, `5952`, or `5953`
- local verification commands return `3`
- you can drive Virtuoso from the new computer without relying on SSH forwarding
