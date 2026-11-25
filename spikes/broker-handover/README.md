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
  through each method. Needs `cargo build` first; the Mac must be **unlocked** (see below).

## Results so far (2026-11-25, macOS 27.2.1, FreeRDP 3.33, Mac locked)

- Handover works: both instances register, and FreeRDP authenticates over NLA through the
  broker to whichever instance is current, with one shared access credential.
- `drop`: FreeRDP (`+auto-reconnect`) reconnected 4.25 s after the move (twice, 4254 and
  4259 ms), the broker routed it to the new instance, which authenticated it from FreeRDP's
  cached credentials and started the session.
- `redirect`: **not yet measured.** With the Mac locked, a session stalls right after
  "Starting client loop" (no events dispatched, apparently waiting on capture), and IronRDP
  sends the Server Redirection PDU from that loop, so it never went out and FreeRDP stayed
  connected. `drop` still ended the stalled session. Re-run with the Mac unlocked.
- `errinfo`: FreeRDP also reconnected after 4.25 s, but it logged a connection reset, not the
  error info, so this run doesn't show how FreeRDP treats "disconnected by another
  connection". Re-run with the Mac unlocked too.

## Findings for Phase 2

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
  the certificate. Separate cert dirs plus a staggered start fixed it; which of the two
  mattered wasn't isolated.
