# jm2/macrdp — login-window (CRD-equivalent) access for macrdp

Handoff plan for coding-agent sessions working in **jm2/macrdp**, a development fork of
[clintcan/macrdp](https://github.com/clintcan/macrdp). Read this whole file, then upstream's
`CLAUDE.md`, `docs/architecture.md`, `docs/conventions.md` and `docs/macos-gotchas.md`, before
writing code.

This replaces the earlier from-scratch `macrdp-PLAN.md`.

> Fork-only file: `docs/fork/` and `spikes/` live on the fork's `feat/*` branches and are
> never part of an upstream PR.
>
> **Target platform (decided 2026-11-24):** macOS **27.2.1 on Apple silicon** (mbp16-m1max)
> is the real-world target. Spikes and live verification run there; behaviour on macOS 26
> and 15 is *inferred* from it (API availability, Apple's release notes), not tested, unless
> a spike turns up a version-specific dependency. Where this plan says "macOS 15 and 26",
> read "macOS 27, with 26/15 inferred".

---

## 0. Handoff prompt (paste into the first session)

> You are working in `~/macrdp`, a fork of clintcan/macrdp (a Rust + IronRDP RDP server for
> macOS). The goal is **Chrome Remote Desktop-equivalent access**: an RDP client can reach the
> Mac at the **login window after a reboot or logout**, and the user authenticates to macOS
> **only through Apple's own login window and lock screen**, never through a macrdp password
> prompt. The fork is a **staging area for upstream PRs, not a hard fork**: every change must
> be opt-in, byte-identical when off, and follow upstream's `docs/conventions.md`. Start at
> the first unchecked item in §6. Phase 0 is a feasibility gate: do not start Phase 2 until
> Phase 0's results are written up and discussed upstream on issue #237. Update §11 at the
> end of each session.

---

## 1. Goals and non-goals

**Goals, in priority order**
1. **No macOS account password stored or prompted for by macrdp.** NLA gates the network with
   a separate RDP access credential, and macOS authentication happens only in Apple's UI.
2. **Login-window access:** connect after a reboot (once FileVault is unlocked) or logout,
   see the real login window, and log in from the client.
3. **Follow the console:** login, logout and fast user switching move the client to the
   right session with at most a quick automatic reconnect.
4. *(Lower priority)* **Multi-monitor**, by fixing IronRDP upstream.

**Non-goals**
- Pre-boot FileVault access *from macrdp itself*: nothing of macrdp runs before the data
  volume is unlocked. Reboots with FileVault on are handled by the paths in §3a (Apple's SSH
  unlock on macOS 26 + Apple silicon; `authrestart` elsewhere), never by macrdp handling
  the FileVault password.
- Separate concurrent GUI sessions (a macOS limit, as upstream already notes).
- Replacing upstream's default "authenticate against your Mac account" mode. The new mode
  is an alternative alongside it.

## 2. What upstream does today (verified 2026-11-24, upstream f46bfd9 / v0.10.10)

| Area | Current behaviour | Where |
|---|---|---|
| Auth | PAM `checkpw` validates the Mac password at startup; that same password becomes IronRDP's static `Credentials`, which every client must match through CredSSP/NLA | `src/auth.rs` |
| Password prompt | The tray app prompts for the macOS account password in its own dialog and stores it in the login Keychain | `gui/Sources/macrdptray/main.swift` (`promptAndStorePassword`), `gui/README.md` |
| Auto-unlock | `--auto-unlock` types the stored password into the lock screen as per-keycode events | `src/main.rs` (`attempt_auto_unlock`), `docs/known-quirks.md` |
| Lock screen input | **Works:** the in-session lock screen accepts `CGEventPost` from a process holding the Accessibility grant (live-verified upstream) | `docs/known-quirks.md` |
| Login window input | **Documented as blocked**, but only from a *user-session* process: "no Accessibility grant exists yet to attach to" | `docs/macos-gotchas.md`, `docs/known-quirks.md` |
| Process model | Single process; one user LaunchAgent; `--fork-workers` was removed | `docs/architecture.md` |
| Reconnect | Server Auto-Reconnect Cookie is sent, and mstsc auto-reconnects | IronRDP divergence (13), upstreamed |

Two consequences:
- **Goal 1 is mostly achievable inside the user session today.** Lock screen typing already
  works, so a remote user can type their own password at the real lock screen. The stored
  password exists only because CredSSP needs a known credential, and for auto-unlock.
- **Goal 2 needs a process in the LoginWindow context.** Upstream's "blocked" finding doesn't
  cover that case, and that's what Phase 0 tests.

**Upstream since then (checked 2026-11-25, upstream 132ebdf / v0.11.2):** multi-monitor
sessions (`--multi-monitor`, experimental: one virtual display and one H.264 stream per client
monitor; refused with the headless modes, `VD_HIDPI` and `--no-client-resolution`), network
auto-detect on by default, `--restore-windows-on-disconnect` in plain `--virtual-display` mode,
a USB redirection fix, and an IronRDP fork pin of `f2c42733` (multi-monitor and USB commits
only; nothing in credentials, NLA or takeover). The table above still holds. Upstream's agreed
next steps (TODO, 2026-11-26) include making the virtual display main only while a client is
connected (a per-session `--make-primary`); see §10a for why that matters here.

## 3. Target UX: the "front door" model

1. **Network gate:** the client authenticates with NLA using an **RDP access credential**: a
   username plus a random secret generated by `macrdp credential rotate`, shown once, stored
   in a dedicated Keychain item. It is never the Mac password, so leaking it gives an attacker
   a lock screen, not your account.
2. **macOS authentication:** the client then sees whatever the console shows, and macOS's own
   UI does the authentication:
   - **Logged in:** the desktop.
   - **Locked:** the real lock screen; the remote user types their password.
   - **Logged out or rebooted:** the real login window.
3. **Never:** a macrdp dialog asking for the Mac password, a stored Mac password, or
   auto-unlock. `--auto-unlock` refuses to start in this mode.

This mirrors CRD on macOS (a PIN, then the OS's own login).

## 3a. Reboots and FileVault

The RDP session itself never survives a reboot; the client reconnects to the login window
afterwards, as with Windows.

| Setup | After a reboot | How |
|---|---|---|
| FileVault off | RDP straight to the login window, nobody logged in | The broker (LaunchDaemon) and the LoginWindow instance start at boot (Phase 2) |
| **FileVault on, macOS 26+, Apple silicon** | **Two steps, fully remote** | (1) SSH in and unlock FileVault with Apple's built-in pre-boot SSH unlock (System Settings › General › Sharing › Remote Login on); (2) the Mac finishes booting, the broker and LoginWindow instance start, and you RDP to the login window and log in |
| FileVault on, macOS 15 or Intel | Planned reboots only | `sudo fdesetup authrestart` before rebooting; after an unplanned reboot (power loss) someone must unlock at the Mac |

Rules for the macOS 26 path:
- **The Mac password still goes only to Apple:** to Apple's SSH unlock, then to Apple's
  login window (typed over RDP). macrdp must not automate, script or store either step.
  At most, docs and `macrdp doctor` explain the flow.
- **Network before unlock:** Apple supports Ethernet, or Wi-Fi only on a previously joined
  open or WPA2-Personal (PSK) network. Recommend Ethernet for headless Macs; WPA2/3-Enterprise
  and WPA3-only networks won't work pre-unlock.
- **Remote Login stays on** after unlock. It's an Apple service and has its own attack
  surface, so document reaching both SSH and RDP only over a VPN or Tailscale.
- **Known risk to check:** some users report Tahoe with FileVault not bringing the network up
  until a user logs in. Phase 0 must confirm the network stays up between the SSH unlock and
  the login window, so the broker can accept the RDP connection.
- **Unknown to check:** whether the SSH unlock lands at the login window or logs the
  unlocking user straight in. Either is fine (the broker routes to whichever instance owns
  the console), but the docs must say which.

## 4. Architecture: two options, light preferred

### Option L (preferred): a root broker that hands over connections, plus macrdp instances per session

```
client ──TCP──▶ macrdp-broker (root LaunchDaemon; accept() only, never parses RDP)
                   │ hands over the accepted socket (SCM_RIGHTS) to the console owner's instance
     ┌─────────────┴──────────────┐
     ▼                            ▼
 macrdp (LoginWindow context)   macrdp (user Aqua session — today's process)
 /Library/LaunchAgents plist    same plist, LimitLoadToSessionType = [LoginWindow, Aqua]
```

- **Broker:** watches `State:/Users/ConsoleUser` and passes each accepted TCP connection to
  the registered instance for the current console session.
- **Console switch (login, logout, fast user switch):** the broker tells the old instance to
  end its session with a reconnect-friendly disconnect. The client auto-reconnects and the new
  connection goes to the new session's instance. That's one brief reconnect, the same UX CRD has.
- **The root process never parses untrusted input.** It only accepts connections and passes
  them on. TLS, CredSSP and RDP stay in the unprivileged instances.
- **Each instance stays single-process,** matching upstream's architecture.

**Upstream changes Option L needs (each a small, opt-in PR):**
1. `--auth access-credential` (Phase 1; useful without the broker).
2. `--listen-from-broker <socket>`: receive accepted sockets from the broker instead of binding
   a port. Similar in spirit to launchd socket activation.
3. `--loginwindow-mode`: no tray app, no login Keychain, no PAM; capture and input paths that
   work in the LoginWindow context (whatever Phase 0 proves).
4. "Session moving": a graceful disconnect that clients treat as a reconnect.

**Finding (2026-11-24): IronRDP already has the seams for hooks 2 and 4.** Upstream
`ironrdp-server` (and the clintcan fork macrdp pins) has `RdpServer::serve(&mut impl
ConnectionSource)`, documented for "an embedder that accepts connections itself … sockets
handed over by the service manager"; `run` is just `serve` over a bound TCP socket. So
`--listen-from-broker` is a macrdp-only `ConnectionSource` that receives fds over a Unix
socket (SCM_RIGHTS), with no IronRDP divergence. It also has `ServerRedirectionHandle::redirect
(ServerRedirectionPdu)` ("the client reconnects to the target the PDU describes, as it would for
an RD Connection Broker"), plus `ErrorInfoDisconnectHandle`. Session moving can therefore try a
Server Redirection PDU pointing back at the broker's address before falling back to a plain
disconnect + auto-reconnect. Spike C should measure both with each client. macrdp uses none of
these today.

The broker, its launchd plists and the installer changes are a separate package: either
`packaging/system-mode/` upstream, or a companion repo `jm2/macrdp-system` if upstream
prefers to keep root code out of tree.

### Option H (not recommended): the broker owns the RDP connection

The broker keeps the client connection across switches and the instances become media/input
providers; my earlier from-scratch design. It avoids the reconnect, but it reverses upstream's
single-process model and puts protocol parsing in a root process. It would likely be rejected
upstream and turn into a hard fork. Consider it only if Option L's reconnect proves unusable
with real clients.

## 5. Security requirements

- **Broker:** no TLS, no PDU parsing, no Keychain access. It accepts only from configured bind
  addresses, keeps a per-IP connection rate limit, and passes sockets only to instances whose
  audit token matches macrdp's code-signing requirement.
- **Access credential:** generated with ≥128 bits of entropy, stored so both instances can
  read it (Phase 0 decides how: a System-keychain item, or a root-owned file whose contents the
  broker hands over at instance registration). Rotatable; old one invalid immediately.
- **Upstream protections stay on:** the existing `auth_guard` (rate limit, lockout, audit log)
  applies to access-credential failures too.
- **Passwords typed at the lock screen or login window are never logged.** Input logging must
  stay off for those surfaces. Audit `RUST_LOG=debug` paths.
- **The access credential plus a console that's left logged in** means the desktop is
  reachable without the Mac password, exactly as in upstream's default mode. Document that
  `--lock-on-disconnect` is the recommended pairing.

## 6. Phases

### Phase 0 — Fork setup and feasibility gate (≈1–1.5 weeks)
- [x] Fork to `jm2/macrdp`; `upstream` remote; keep `main` == upstream `main`; work on
      `feat/*` branches rebased on upstream at least weekly. CI as upstream.
      *(2026-11-24: fork and `upstream` remote in place, `main` == upstream f46bfd9, Actions
      enabled on the fork with upstream's workflows unchanged.)*
- [ ] **Spike B1 — LoginWindow capture:** a minimal signed binary launched by a
      `/Library/LaunchAgents` plist with `LimitLoadToSessionType = LoginWindow`, on macOS 27
      (26/15 inferred). Which capture path works there: ScreenCaptureKit, `CGDisplayStream`, or
      `CGWindowListCreateImage`? Record the running uid and how TCC treats it.
      *(Probe built: `spikes/loginwindow-probe/`. Not yet run in a login-window session.)*
- [ ] **Spike B2 — LoginWindow input:** from the same agent, can `CGEventPost` type into the
      login window's username/password fields and press Return? Also test after a fast user
      switch to the login window.
      *(Same probe: automatic net-zero type/erase per tap, plus `ctl.sh` for Return.)*
- [ ] **Spike B3 — fallback input,** only if B2 fails: a virtual HID keyboard (the
      Karabiner-DriverKit-VirtualHIDDevice approach). Does it reach the login window? Record
      the entitlement and distribution implications. Its own DriverKit extension needs an Apple
      entitlement; reusing pqrs's signed one means users install it separately.
- [ ] **Spike C — handover and reconnect:** a root daemon passes an accepted socket to the user
      instance and to the LoginWindow instance. Measure the server-initiated reconnect on a
      console switch with mstsc (antec-win), Windows App (macOS), FreeRDP 3, and Transom.
      *(2026-11-25, in progress: branch `spike/broker-handover` (72bf255), see its
      `spikes/broker-handover/README.md`. User-space prototype: `--listen-from-broker` over
      `serve(ConnectionSource)` with no IronRDP change, a toy stdlib broker, two instances.
      Handover works and shares one access credential; on a `drop` move FreeRDP 3.33
      reconnected in 4.25 s to the new instance and authenticated from cached credentials.
      Redirect and error-info moves not yet measured: with the Mac locked the session stalls
      before IronRDP sends them. Next: re-run unlocked, then mstsc, Windows App, Transom.)*
- [ ] **Spike D — FileVault on macOS 27 (Apple silicon):** on mbp16-m1max (FileVault on,
      Remote Login on) or a FileVault-on guest, reboot, then SSH-unlock. Record: (1) whether the network
      stays up after unlock with nobody logged in, on Ethernet and on WPA2-Personal Wi-Fi;
      (2) whether the Mac lands at the login window or logs the unlocking user in; (3) whether
      the LoginWindow agent starts and can capture and inject input; (4) time from SSH unlock
      to "broker accepting connections". Note: Virtualization.framework guests may not support
      the pre-boot SSH unlock; confirm, and fall back to real hardware if not.
- [ ] **Spike E — permissions across reboots:** do the LoginWindow binary's Screen Recording and
      Accessibility grants survive reboots and a macOS point update? Does macOS 15+'s periodic
      screen-recording re-approval prompt apply to it? Nobody can click that prompt at the login
      window. If it applies, document the MDM `forceBypassScreenCaptureAlert` key as a
      requirement for headless use, and make `macrdp doctor` warn about it.
- [ ] Write `docs/fork/0001-loginwindow-feasibility.md` with results, the exact plists and
      install paths, and per-macOS-version notes.
- [ ] **Talk to upstream:** post the results and Option L on issue #237 (or a discussion) and
      get the maintainer's view before Phase 2.
- **Go/no-go:** Phase 2 proceeds only if B1 works and either B2 or B3 works. If neither, the
  login window really is out of reach: stop after Phase 1 and say so on #237.

### Phase 1 — Access-credential mode (≈1–2 weeks; independent of Phase 0's outcome)
- [x] `--auth access-credential` (config `AUTH_MODE=access-credential`): skip the PAM check;
      IronRDP `Credentials` come from the access credential. Default stays `account`.
      *(Branch `feat/access-credential` e461812, rebased 2026-11-25 onto upstream 132ebdf
      (v0.11.2); first cut 033b5ad off f46bfd9. Plus a
      `CredentialValidator` against the current secret: see §11, session 2.)*
- [x] `macrdp credential rotate|show-username|status`; random secret shown once; Keychain item
      separate from anything the account-password flow uses. *(Service `macrdp-access`;
      140-bit secret; stored via `security -i` on stdin; rotation applies within ~2 s through
      a stamp file, no restart.)*
- [x] Tray: in this mode, replace "Set Account Password…" with "Access credential…" (rotate,
      copy once). No Mac-password prompt anywhere in this mode. *(Written and type-checked;
      not yet built or clicked through: the build needs `sudo xcodebuild -license`.)*
- [x] `--auto-unlock` hard-errors in this mode, with a message explaining why.
- [ ] Live-verify: lock, reconnect, and type the password at the lock screen from mstsc and
      Transom (non-US layout too, given upstream's keymap notes).
- [x] Docs: README section, `docs/configuration.md`, security trade-offs; the README "Recent
      releases" convention from upstream's `CLAUDE.md`. *(README, configuration, cli,
      features, architecture, gotchas, known-quirks, config.env.example. "Recent releases" is
      updated at a release cut, so not in this PR.)*
- [ ] Open the upstream PR.
- **DoD:** a fresh install in this mode never asks for or stores the Mac password, and a remote
  user unlocks via the real lock screen.

### Phase 2 — Broker and LoginWindow instance (≈3–5 weeks; after the go decision)
- [ ] `macrdp-broker`: a small binary that accepts connections and hands them over with
      audit-token validation; console tracking; instance registry.
- [ ] Upstream hooks: `--listen-from-broker`, `--loginwindow-mode`, and the session-moving
      disconnect, each a separate PR.
- [ ] Packaging: a signed `.pkg` "system mode" that installs the LaunchDaemon and the
      `/Library/LaunchAgents` plist (LoginWindow + Aqua), migrates from the existing per-user
      LaunchAgent install, and ships an uninstaller. TCC onboarding for the LoginWindow binary.
- [ ] Scenario test: reboot (FileVault off, or `authrestart`) → connect → log in at the login
      window → land in the user session after one reconnect → lock → unlock at the lock screen
      → log out → back at the login window. All from the client.
- [ ] Scenario test, **FileVault on (macOS 26, Apple silicon):** cold reboot (also simulate
      power loss) → SSH-unlock FileVault → RDP to the login window (or the user session, per
      Spike D) → continue as in the scenario above. Run on Ethernet and on WPA2-Personal Wi-Fi.
- [ ] `macrdp doctor` (system mode) reports FileVault state, Remote Login state, the network
      type (with a warning for unsupported pre-unlock Wi-Fi), and the screen-recording approval
      state. Docs: a "Headless Macs and reboots" page covering §3a.
- **DoD:** both scenarios pass with mstsc and Transom, with nobody at the Mac, on macOS 27
  Apple silicon (26/15 inferred; see the target note at the top).

### Phase 3 — Console following and polish (≈1–2 weeks)
- [ ] Fast user switching (user A → login window → user B), each with its own instance.
- [ ] Interplay with `--lock-on-disconnect`, `--virtual-display` / `--shield-primary` (the
      login window must be visible; see upstream's capture-primary lock caveat).
- [ ] Health and watchdog integration for the LoginWindow instance; logs in a root-readable
      location.

### Phase 4 — Multi-monitor (lower priority)
*Rewritten 2026-11-25: upstream built this itself.* v0.11.0 shipped multi-monitor sessions
(`--multi-monitor`): one virtual display per client monitor, one EGFX surface and encoder per
monitor, live layout changes on mstsc and Windows App for Windows. The acceptor change is
clintcan/IronRDP divergence (8) plus server (36), marked as a candidate for Devolutions; that
PR is the maintainer's to send, not ours. Design: upstream `docs/multi-monitor-design.md`.
What's left is testing and filling upstream's own gaps, coordinated with the maintainer:
- [ ] Live-test `--multi-monitor` with Transom (the reference client here) and Windows App for
      macOS, which upstream hasn't covered; report results upstream.
- [ ] Headless modes with multi-monitor, `--shield-primary` first (the lockable one): upstream
      lists it as unsupported for now and not planned soon. Only if the maintainer wants it.
- [ ] The login-window instance (Phase 2) serves one monitor; check that a multi-monitor client
      falls back cleanly when its connection lands there.

## 7. Upstreaming rules (from upstream `docs/conventions.md`)
- One concern per module, gated behind a flag; byte-identical when off.
- `ironrdp` is the only code that touches the RDP wire format.
- Private or undocumented APIs and new FFI go behind one boundary file.
- Prefer landing reusable seams upstream (in IronRDP or macrdp) over fork-only code.
- Every PR includes live-test evidence (client, macOS version, scenario) and updated docs.
- Don't refactor working hot paths for style.

## 8. Test setup
- **Server:** mbp16-m1max (macOS 26) for daily work, plus macOS 15 and 26 guests via
  Virtualization.framework (UTM or tart) for login-window and reboot testing without
  rebooting the main machine. Confirm in Phase 0 that capture and input behave the same in a
  VM guest. macmini-m1 runs Fedora, so it's not a server target. The FileVault-on macOS 26
  path may need real Apple silicon hardware if guests can't do the pre-boot SSH unlock
  (Spike D); re-imaging macmini-m1 to macOS 26 is one option.
  *(2026-11-24: mbp16-m1max actually runs **macOS 27.2.1** (build 26B131), with FileVault on
  and Remote Login + Screen Sharing enabled, and that is now the target (see the note at the
  top). No VM tooling (UTM, tart) is installed and there is no code-signing identity in the
  keychain, so the probe is ad-hoc signed. `xcode-select` points at the Command Line Tools,
  which lack SwiftUI's macro plugins, and Xcode.app's license isn't accepted, so the GUI
  can't be built here until someone runs `sudo xcodebuild -license`. The local Rust is 1.98;
  CI pins 1.95.0 (installed via rustup for parity: run fmt/clippy with `+1.95.0`).)*
- **Clients:** Transom and FreeRDP 3 on antec; mstsc on antec-win; Windows App on macOS.

## 9. Fallbacks if upstream says no
1. **Phase 1 rejected:** keep it as a small fork patch; it's isolated and cheap to rebase.
2. **The broker or system mode rejected, but the hooks accepted:** ship `jm2/macrdp-system`
   (broker + plists + installer) that runs unmodified upstream macrdp binaries.
3. **The hooks rejected too:** only then consider a hard fork. Weigh it against upstream's pace
   (releases every few days): a hard fork falls behind within weeks, so prefer (2) even at some
   cost.

## 10. Open decisions (for John-Michael)
1. Where the access credential lives so both instances can read it (decided by Phase 0).
2. Whether to accept a virtual-HID dependency if Spike B2 fails.
3. Developer ID / notarization for fork builds before upstream releases them.
4. Whether system mode should also be offered for the default account mode (it can't
   auto-unlock at the login window either way).

## 10a. Findings worth carrying forward

- **macrdp can't start while the Mac is locked with its displays asleep** (mirror-primary
  mode). `capture::primary_display_size` asks ScreenCaptureKit for the display size at startup
  even with `--width`/`--height`, SCK lists no displays then (as upstream's #231 note says),
  and startup fails with `no displays available`. Under launchd that's a KeepAlive restart
  loop until the display wakes. The LoginWindow instance (Phase 2) will start at boot with the
  display possibly asleep, so it needs the size query to tolerate this (fall back to
  `--width/--height`, or wake the display first as `display_awake.rs` does for clients). Found
  2026-11-24 while live-testing Phase 1; worth an upstream issue. **Still present in v0.11.2**
  (2026-11-25): #232 wakes the displays when a client authenticates and at capture start, both
  after startup's size query.
- **IronRDP authenticates takeover candidates against the credentials captured when the live
  session began** (`RdpServerHandle::set_credentials` docs; its own comment says "UNTESTED").
  After a credential change the old password can still evict the session unless a
  `CredentialValidator` checks the current one, and the new password can't take it over until
  it ends. Pinned in `src/conn_test.rs` on `feat/access-credential`. This matters again in
  Phase 2: a console switch is exactly a "credential context changed under a live session"
  event. Possibly worth an upstream IronRDP test/doc PR.
- **The validator needs delegated credentials.** With a validator set, IronRDP refuses a client
  that completes NLA without delegating credentials (Restricted Admin / Remote Credential
  Guard). FreeRDP 3.33 delegates; mstsc, Windows App and Transom are still to be checked.
- **What the remote client sees of the lock screen depends on the display arrangement.**
  `loginwindow` draws the lock screen on the main display. Upstream's notes on `--shield-primary`
  (default keep-physical-main) record two different outcomes: locked *during* a session, the
  client kept showing the virtual display's desktop while its keystrokes went to the (unseen)
  password field; locked by `--lock-on-disconnect` and then *reconnected*, the client saw the
  login screen and unlocked by typing. Phase 1's DoD ("a remote user unlocks via the real lock
  screen") needs both cases checked live, per primary mode. Upstream plans to make the virtual
  display main while a client is connected (TODO, 2026-11-26), which would change the first
  case; re-check when it lands.
- **Rebasing onto upstream can merge new password uses silently.** v0.11.x added a fourth
  `spawn_primary_overlay_watcher` call taking `Arc::clone(&password)`; git merged it cleanly,
  but in access-credential mode that value is the access secret. Fixed in e461812 (it takes
  `unlock_password`, empty in this mode). After each rebase, grep upstream's diff for new
  `password`/`Credentials` uses.
- **FreeRDP `/auth-only`** is a good scripted NLA probe, but `sdl-freerdp` exits 1 even on
  success: read its `Authentication only, ERRBASE_SUCCESS` log line instead.

## 11. Progress log

| Date | Session | Phase | Summary | Next |
|---|---|---|---|---|
| 2026-11-24 | 1 | 0 | Fork setup done (`upstream` remote added; `main` == upstream f46bfd9; branch `feat/loginwindow-phase0`). Built the B1/B2 probe (`spikes/loginwindow-probe/`): a Swift LaunchAgent that records uid, security session, CGSession, TCC preflights and code signature, tries six capture paths (SCK content/screenshot/stream, CGDisplayStream, CGDisplayCreateImage, CGWindowListCreateImage, `screencapture`), runs a net-zero type/erase per event tap at the login window, and exposes a token-gated loopback command socket (`ctl.sh`). Smoke-tested from the user session while the Mac was locked with its display asleep: SCK lists no displays, and the CoreGraphics paths return black frames (as upstream's #231 note says), so the capture code is only validated end to end once it runs against an awake screen. Found that upstream IronRDP already provides `ConnectionSource`/`serve` and `ServerRedirectionHandle` (see §4), which shrinks Option L's hooks 2 and 4. | User: `build.sh`, `sudo install.sh`, grant Screen Recording + Accessibility, Fast-User-Switch to the login window for ≥60 s, log back in. Then analyse `latest-loginwindow/`, drive Return with a throwaway test account, and write up B1/B2. |
| 2026-11-24 | 2 | 1 | Target set to macOS 27.2.1 (26/15 inferred). Phase 1 implemented on `feat/access-credential` (033b5ad, off upstream f46bfd9, pushed to the fork): `--auth access-credential` / `AUTH_MODE`, `macrdp credential rotate\|status\|show-username`, Keychain item `macrdp-access` written through `security -i` on stdin, stamp-file rotation with no restart and no Keychain polling, a validator against the current secret (closes the takeover gap in §10a), `--auto-unlock`/`--password`/`--password-file`/`--skip-auth` refused, the new `no-access-credential` status, controller sign-in picker + show-once dialog, and docs. 459 tests pass, including NLA rotation/takeover tests (mutation-checked); fmt + clippy clean on 1.95.0. Live on this Mac with FreeRDP 3.33 over NLA: the current secret is accepted; wrong, rotated-out and removed ones are refused; rotation applies within 3 s via `config.env`. | User: accept the Xcode license (`sudo xcodebuild -license`) so the controller can be built and clicked through; live-verify with mstsc, Windows App and Transom (sign in, lock, unlock at the lock screen, rotate); decide on a fork-internal draft PR to run CI (Linux job included). Then open the upstream PR. Phase 0 B1/B2 still waits on the probe run (`sudo spikes/loginwindow-probe/install.sh`, grant, Fast-User-Switch). |
| 2026-11-25 | 3 | 1, 4 | Checked upstream: 12 commits to v0.11.2, then 3 TODO-only commits (132ebdf). Multi-monitor shipped upstream, so Phase 4 is rewritten around testing it. Fast-forwarded the fork's `main` to 132ebdf; rebased `feat/access-credential` onto it (two keep-both conflicts in `conn_test.rs` and `SettingsModel.swift`, plus a silent merge of upstream's new watcher call that received the secret, fixed) and force-pushed it as e461812; 483 tests pass, fmt + clippy clean on 1.95.0, the controller type-check matches upstream's (11 diagnostics, all missing SwiftUI macros). Rebased this branch onto 132ebdf too. The startup display-asleep bug is still present upstream. #237 has a new maintainer comment (multi-user sessions are out of scope); login-screen support is still an open enhancement with no timeline. Then started Spike C on `spike/broker-handover` (72bf255): handover works, FreeRDP reconnects in 4.25 s after a drop, redirect not yet measured (sessions stall while the Mac is locked); four Phase 2 findings in that README (brokered connections lose the RTT that gates blank recovery, close-on-exec, AF_UNIX path length, broker peer checks). | Same as session 2 (Xcode license, live client tests, probe run for B1/B2). Spike C: re-run `spikes/broker-handover/run-local.sh` with the Mac unlocked, then the real clients. |
