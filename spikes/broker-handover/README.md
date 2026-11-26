# Spike C: broker handover and reconnect

Fork-only spike for `docs/fork/PLAN.md` (Phase 0, Spike C; the plan lives on
`feat/loginwindow-phase0`). Branch `spike/broker-handover`, off `feat/access-credential`.
Never part of an upstream PR as is.

## What's here

- `src/broker_source.rs` + two hidden flags in `src/main.rs`:
  `--listen-from-broker <socket>` and `--broker-instance <name>`. macrdp then takes
  connections from the broker through IronRDP's `RdpServer::serve(ConnectionSource)` instead
  of binding `--bind`, and moves its live session when the broker says so: a Server
  Redirection PDU (`redirect`), a plain drop (`drop`), or Set Error Info "disconnected by
  another connection" (`errinfo`). No IronRDP change.
- `broker.py`: a toy broker (Python stdlib). It accepts TCP, passes each socket to the
  current instance over a Unix socket (SCM_RIGHTS), and never reads RDP. A control socket
  switches instances; `--follow-console` switches when `/dev/console` changes owner
  (root = the login window).
- `run-local.sh`: broker on 127.0.0.1:3392, instances `a` and `b` (same user, same access
  credential under the throwaway Keychain account `lwtest-probe`, removed on exit), FreeRDP 3
  through each method. Needs `cargo build` first. Instance `b` runs from a copy of the binary
  re-signed with its own ad-hoc identifier (see the first finding below).

## Results (2026-11-26, macOS 27.2.1, FreeRDP 3.33.1, Mac unlocked)

Handover works: both instances register, and FreeRDP authenticates over NLA through the
broker to whichever instance is current, with one shared access credential. Moving a live
session from `a` to `b`, timed from the broker's switch command:

| Method | What FreeRDP did | New connection on `b` |
|---|---|---|
| `redirect` (Server Redirection PDU, `TARGET_NET_ADDRESS` = 127.0.0.1 only) | Followed it: reconnected to the same port, authenticated with its own credentials, and `b` sent frames | 17 ms |
| `drop` (`ServerEvent::Quit`, a plain close) | Auto-reconnected at once (`+auto-reconnect`), authenticated from cached credentials, and `b` sent frames | 32 ms |
| `errinfo` (Set Error Info, then Disconnect Provider Ultimatum) | Showed "ERRINFO_RPC_INITIATED_DISCONNECT … initiated by an administrative tool" and stayed disconnected | none |

Details:

- `redirect`: the PDU went out 6 ms after instance `a` read the broker's MOVE, and its session ended
  `Ok(Redirected)` 4 ms later. The redirected session authenticated on `b` 3 ms after it
  connected and got a new auto-reconnect cookie. The PDU carried no credentials, no load
  balancing info and no port; FreeRDP reused its own.
- `errinfo`: IronRDP logged "client did not opt into Set Error Info PDUs; disconnecting
  without the reason", so only the ultimatum went out; FreeRDP names that "RPC initiated
  disconnect" itself and doesn't auto-reconnect after a server-initiated disconnect. Useful
  for ending a session with a reason, not for moving one.
- Only FreeRDP so far. mstsc, Windows App and Transom still need the same three runs; a
  redirect to a different host name may make them prompt for credentials.
- Superseded: the 2026-11-25 runs (Mac locked) stalled every session at capture start and
  measured `drop` at 4.25 s. That stall was the `replayd` eviction below, not the lock;
  locked-Mac behaviour hasn't been re-run since.

## Findings for Phase 2

- **Two macrdp processes with the same code identity in one login session break each
  other's capture.** From the moment the second one starts, both log
  `RPDaemonProxy: connection INTERRUPTED` about 1,400–2,400 times a second, in lockstep:
  `replayd` (ScreenCaptureKit's daemon, which stays up) keeps dropping one connection for the
  other, and `SCStream` `startCapture` never returns, so the session stops at "Starting
  client loop" with nothing sent. Re-signing one copy with another ad-hoc identifier (`codesign
  -s - -i org.macrdp.spike-b -f`) stopped it: zero interruptions, frames on both. That changes
  the signing identifier and the cdhash, so which one `replayd` keys on isn't known. Phase 2
  must never run two capturing instances of one build in the same user's GUI session (an
  overlapping hand-off or restart, two copies of the app). Whether the login-window instance
  shares `replayd` with a user's instance is for the B1/B2 probe run.
- `IncomingConnection`'s accept-time RTT (macrdp divergence 15) is crate-private, so a
  brokered connection reaches blank recovery as RTT 0, which counts as LAN: the slow-link
  disarm (the ZeroTier false-drop fix) is lost. Phase 2 needs a public setter in the IronRDP
  fork; the source can sample the RTT itself (`TCP_CONNECTION_INFO`, as divergence 15 does).
- macOS has no `MSG_CMSG_CLOEXEC`: received sockets must be marked close-on-exec at once,
  since macrdp spawns helpers (caffeinate, the HUD and shield helpers).
- AF_UNIX paths are capped at 104 bytes: the broker's socket directory must be short
  (`/var/run/...` for the root broker).
- A root broker must check who connects to its instance socket (peer credentials,
  `LOCAL_PEERCRED`), or any local process could register as the console user's instance
  and receive their connections. The toy broker relies on a 0700 directory only.
- Two instances started at once with one `--cert-dir`: one stalled right after generating
  the certificate (2026-11-25). Separate cert dirs plus a staggered start fixed it. On
  2026-11-26 two instances with separate cert dirs started at the same moment without
  stalling, same identity or not, so the cause is still unexplained; the script keeps both.
