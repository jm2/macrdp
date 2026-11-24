# LoginWindow probe (Phase 0 spikes B1 + B2)

Fork-only spike for `docs/fork/PLAN.md` §6, Phase 0. It is **not** part of macrdp's build
and is not meant for upstream. It answers two questions for a process that launchd starts
in the **login-window** session (`/Library/LaunchAgents`, `LimitLoadToSessionType =
LoginWindow`):

- **B1, capture:** which uid and security session does it run in, what does TCC report,
  and which screen-capture paths return real pixels? It tries ScreenCaptureKit (shareable
  content, `SCScreenshotManager`, and `SCStream`, which is what macrdp uses),
  `CGDisplayStream`, `CGDisplayCreateImage`, `CGWindowListCreateImage` and
  `/usr/sbin/screencapture`. The pre-SCK calls are looked up with `dlsym`, because the
  macOS 15+ SDK marks them obsolete.
- **B2, input:** does `CGEventPost` reach the login window? On start, the login-window
  instance waits 5 s, then for each event tap (HID, then session) types `lwprobe` and
  erases it with exactly 7 backspaces, so the net effect is zero wherever the events land.
  It takes a screenshot and an AX snapshot of the focused element after every step. It
  **never presses Return**. Interactive tests (Return, a test account, other taps and
  sources) go through a token-gated loopback command socket (`ctl.sh`).

Nothing typed is logged: `type` logs a length, and AX values are reported as lengths only.

## Files

| File | What |
|---|---|
| `main.swift` | the probe (single file, `swiftc`, no Xcode project) |
| `build.sh` | builds `build/macrdp-lwprobe`, ad-hoc signed (or `SIGN_ID=<identity>`) |
| `install.sh` / `uninstall.sh` | `sudo`; install the binary, the LoginWindow agent and an optional Aqua control agent |
| `ctl.sh` | sends commands to a running probe: `ctl.sh loginwindow ax 'shot x'` |

Results go to `/Users/Shared/macrdp-lwprobe/<timestamp>-<session>-pid<pid>/`:
`probe.log` (readable), `report.json` (everything), and one PNG per capture method and
step. `latest-<session>` links to the newest run, `runs.log` has one line per run, and
`launchd-<session>.log` holds anything printed before logging starts (crashes included).

## Test procedure

Do this at the Mac or over Screen Sharing (VNC works at the login window). Fast User
Switching keeps your session (and this repo's Claude Code session) running while the
console shows the login window, so nothing needs a logout.

1. **Build and install** (needs your admin password):
   ```sh
   spikes/loginwindow-probe/build.sh
   sudo spikes/loginwindow-probe/install.sh
   ```
2. **Grant permissions.** The Aqua control instance asks for Screen Recording and
   Accessibility. Turn on `macrdp-lwprobe` under System Settings › Privacy & Security ›
   **Screen & System Audio Recording** and **Accessibility**. If it isn't listed, add
   `/Library/PrivilegedHelperTools/macrdp-lwprobe` with **+** (Cmd-Shift-G to type the
   path). Whether a grant made in your session also covers the binary running as
   whatever uid the login window uses is one of the questions; record what you granted.
3. **Baseline (optional):** `launchctl kickstart -k gui/$(id -u)/com.github.jm2.macrdp-lwprobe.aqua`
   re-runs the control instance after granting; check `latest-aqua/probe.log`.
4. **Switch to the login window:** Control Center › your name › **Login Window…** (turn
   on Control Center › Fast User Switching in System Settings if the menu isn't there),
   or **Switch User** on the lock screen. Leave it there for at least 60 s. If you can't
   watch the screen, that's fine: everything is recorded.
5. **Interactive tests (optional, while still at the login window):** from another
   device, ask the Claude Code session to drive the probe (`ctl.sh loginwindow …`). It
   runs in your background session, so it can reach the probe on loopback.
6. **Log back in** as yourself and look at `/Users/Shared/macrdp-lwprobe/latest-loginwindow/`.
7. **Repeat after a real logout** (Apple menu › Log Out) and, separately, on macOS 15 /
   26 if available. A logout kills your session, including Claude Code, so read the
   results afterwards.

### Return and a real login (B2's last step)

Use a throwaway **standard** account (e.g. `lwprobe`, with a password you don't use
anywhere else), never your own password. Starting at the login window:

```sh
ctl.sh loginwindow 'shot pick' ax          # what's focused?
ctl.sh loginwindow wake 'type lwprobe' 'key return'   # username, if in name+password mode
ctl.sh loginwindow 'type <test password>' 'shot filled' 'key return'
ctl.sh loginwindow console                  # did the console user change? (the probe exits
                                            # when the login-window session ends)
```

A wrong password and Return is also a valid test (the field shakes and empties), and it
costs one of that account's failed attempts.

## Safety

- The probe runs (probably as root) in the login-window session and can inject input
  there. Its socket listens on 127.0.0.1 only and needs the token in `control.json`
  (mode 0600, owned by you). It exits after 30 minutes.
- Remove it when Phase 0 is done: `sudo spikes/loginwindow-probe/uninstall.sh`.
- Screen Sharing and Remote Login are your way back in if the console ever gets stuck at
  the login window.
