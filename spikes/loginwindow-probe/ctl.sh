#!/bin/bash
# Sends commands to a running probe over its loopback command socket.
#
#   ctl.sh <session> <command> [command ...]     e.g.  ctl.sh loginwindow ax 'shot x' 'type abc'
#   ctl.sh <session> < commands.txt
#
# <session> is the probe's --session label (loginwindow | aqua | manual). The port and
# token come from <out>/latest-<session>/control.json, which is mode 0600 and owned by
# the installing user. Set MACRDP_LWPROBE_OUT if the probe used a non-default --out.
set -euo pipefail
SESSION="${1:?usage: ctl.sh <loginwindow|aqua|manual> [command ...]}"
shift
OUT="${MACRDP_LWPROBE_OUT:-/Users/Shared/macrdp-lwprobe}"
CTL="$OUT/latest-$SESSION/control.json"
if [[ ! -r "$CTL" ]]; then
    echo "no readable $CTL: is a '$SESSION' probe running, with its command socket on?" >&2
    exit 1
fi
PORT=$(plutil -extract port raw -o - "$CTL")
TOKEN=$(plutil -extract token raw -o - "$CTL")
{
    printf '%s\n' "$TOKEN"
    if (($#)); then printf '%s\n' "$@"; else cat; fi
    printf 'bye\n'
} | nc -w 120 127.0.0.1 "$PORT"
