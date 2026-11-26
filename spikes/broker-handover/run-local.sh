#!/bin/bash
# Spike C, local run: broker on 127.0.0.1:3392, macrdp instances "a" and "b" fed by it,
# FreeRDP 3 as the client. Access credential under the throwaway account lwtest-probe.
# Usage: spikes/broker-handover/run-local.sh [method...]   (methods: redirect drop errinfo; default all three)
set -u
cd "$(dirname "$0")/../.."

W="${SPIKEC_DIR:-${TMPDIR%/}/spikec-run}"; rm -rf "$W"; mkdir -p "$W"
B=target/debug/macrdp
ACCT=lwtest-probe
# Two processes with the same code identity in one login session evict each
# other from replayd (ScreenCaptureKit's daemon) in a tight loop, and
# SCStream startCapture never returns. Instance b gets a copy of the binary
# with its own ad-hoc signing identifier.
BB="$W/macrdp-b"; cp "$B" "$BB" && codesign -s - -i org.macrdp.spike-b -f "$BB" 2>/dev/null
# AF_UNIX paths are capped at 104 bytes, so the broker sockets get a short
# per-user temp dir of their own, removed on exit.
BDIR="${TMPDIR%/}/mrb-spikec"
METHODS=("$@"); [ ${#METHODS[@]} -eq 0 ] && METHODS=(redirect drop errinfo)

mkcfg() { # mkcfg <name> <unused-bind-port>
    mkdir -p "$W/$1/log"
    cat >"$W/$1/config.env" <<EOF
BIND=127.0.0.1:$2
USERNAME=$ACCT
AUTH_MODE=access-credential
EXTRA_FLAGS="--allow-sleep --log-dir $W/$1/log --cert-dir $W/$1/certs --width 1280 --height 800 --listen-from-broker $BDIR/instances.sock --broker-instance $1"
EOF
}
ctl() { printf '%s\n' "$*" | nc -U "$BDIR/control.sock"; }
cleanup() {
    kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
    rm -rf "$BDIR"
    security delete-generic-password -s macrdp-access -a "$ACCT" >/dev/null 2>&1 && echo "cleaned up the test Keychain item"
}
trap cleanup EXIT

python3 -I spikes/broker-handover/broker.py --listen 127.0.0.1:3392 --dir "$BDIR" >"$W/broker.log" 2>&1 &
mkcfg a 3393; mkcfg b 3394
for _ in $(seq 20); do [ -S "$BDIR/control.sock" ] && break; sleep 0.25; done
S=$($B --config "$W/a/config.env" credential rotate 2>/dev/null)
caffeinate -d -u -t 180 & sleep 2  # keep the display on: capture stalls while it sleeps
for n in a b; do
    BIN=$B; [ "$n" = b ] && BIN=$BB
    $BIN --config "$W/$n/config.env" >"$W/$n/stdout" 2>&1 &
    for _ in $(seq 60); do grep -q "instance '$n' registered" "$W/broker.log" && break; sleep 0.5; done
    grep -q "instance '$n' registered" "$W/broker.log" || { echo "instance $n did not register:"; tail -2 "$W/$n/log/macrdp.log" | cut -c1-200; }
done
ctl status

auth() { # FreeRDP's own verdict over NLA through the broker
    sdl-freerdp /v:127.0.0.1:3392 /u:"$ACCT" /p:"$S" /cert:ignore /auth-only >"$W/auth.out" 2>&1
    grep -q 'Authentication only, ERRBASE_SUCCESS' "$W/auth.out" && echo OK || echo REFUSED
}
ctl switch a none >/dev/null
echo "auth-only via broker, routed to a: $(auth)"
ctl switch b none >/dev/null
echo "auth-only via broker, routed to b: $(auth)"

for m in "${METHODS[@]}"; do
    ctl switch a none >/dev/null
    echo "=== method: $m (session on a, then switch to b)"
    sdl-freerdp /v:127.0.0.1:3392 /u:"$ACCT" /p:"$S" /cert:ignore /size:800x600 +auto-reconnect \
        /auto-reconnect-max-retries:5 ${FRDP_LOG:-/log-level:INFO} >"$W/frdp-$m.log" 2>&1 &
    FP=$!
    sleep 6
    echo "   $(ctl switch b "$m")"
    sleep 12
    if kill -0 "$FP" 2>/dev/null; then echo "   FreeRDP still running after 12 s"; kill "$FP"; else echo "   FreeRDP exited"; fi
    wait "$FP" 2>/dev/null
    grep -iE 'redirect|reconnect|disconnect|ERRINFO|error_info|errinfo|connection (established|closed)|BIO_read' "$W/frdp-$m.log" \
        | grep -v backtrace | sed -e 's/^\[[^]]*\] //' -e 's/^\[[0-9:a-f]*\] //' | cut -c1-180 | head -25 | sed 's/^/   frdp: /'
done
echo "=== broker log"; cat "$W/broker.log"
for n in a b; do
    echo "=== instance $n (broker/redirect/auth lines)"
    grep -E 'broker|redirect|Redirect|event="auth"|Quit|errinfo|disconnect' "$W/$n/log/macrdp.log" \
        | sed -e 's/^.*Z //' -e 's/schema_version=1 macrdp_version="[^"]*" host="[^"]*" //' | cut -c1-170
done
for f in "$W"/*/log/macrdp.log "$W"/frdp-*.log; do grep -qF "$S" "$f" && echo "LEAK: secret in $f"; done
