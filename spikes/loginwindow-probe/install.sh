#!/bin/bash
# Installs the Phase 0 LoginWindow probe (fork-only spike). Run from your own account:
#
#   sudo spikes/loginwindow-probe/install.sh [--no-aqua]
#
# Installs:
#   /Library/PrivilegedHelperTools/macrdp-lwprobe                 the probe (root-owned)
#   /Library/LaunchAgents/com.github.jm2.macrdp-lwprobe.loginwindow.plist
#       LimitLoadToSessionType=LoginWindow: launchd starts it in every login-window
#       session (after a logout, or Fast User Switching to "Login Window…").
#   /Library/LaunchAgents/com.github.jm2.macrdp-lwprobe.aqua.plist  (unless --no-aqua)
#       Aqua control instance: runs in each user session, asks for Screen Recording +
#       Accessibility (so the binary appears in System Settings) and records the same
#       measurements for comparison. Never runs the input sequence.
#   /Users/Shared/macrdp-lwprobe/                                  results (mode 1777)
#
# Undo with uninstall.sh. Rebuilding changes an ad-hoc signature's cdhash, so re-run
# this script and re-grant the permissions after every build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/build/macrdp-lwprobe"
PREFIX="com.github.jm2.macrdp-lwprobe"
DEST="/Library/PrivilegedHelperTools/macrdp-lwprobe"
OUT="/Users/Shared/macrdp-lwprobe"
AQUA=1

for arg in "$@"; do
    case "$arg" in
    --no-aqua) AQUA=0 ;;
    *)
        echo "unknown argument: $arg" >&2
        exit 2
        ;;
    esac
done
if [[ $EUID -ne 0 ]]; then
    echo "run with sudo: sudo $0 $*" >&2
    exit 1
fi
OWNER_UID="${SUDO_UID:-}"
if [[ -z "$OWNER_UID" || "$OWNER_UID" == 0 ]]; then
    echo "run via sudo from your own account (results are chowned to SUDO_UID)" >&2
    exit 1
fi
if [[ ! -x "$SRC" ]]; then
    echo "build first: $HERE/build.sh" >&2
    exit 1
fi

install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools
install -m 0755 -o root -g wheel "$SRC" "$DEST"
install -d -m 1777 -o "$OWNER_UID" "$OUT"

# write_plist <session> <LimitLoadToSessionType> [extra args...]
write_plist() {
    local session="$1" type="$2"
    shift 2
    local plist="/Library/LaunchAgents/$PREFIX.$session.plist"
    local extra=""
    for a in "$@"; do extra+="        <string>$a</string>"$'\n'; done
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PREFIX.$session</string>
    <key>LimitLoadToSessionType</key>
    <string>$type</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST</string>
        <string>--session</string>
        <string>$session</string>
        <string>--owner-uid</string>
        <string>$OWNER_UID</string>
$extra    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$OUT/launchd-$session.log</string>
    <key>StandardErrorPath</key>
    <string>$OUT/launchd-$session.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$plist"
    chmod 0644 "$plist"
    plutil -lint "$plist" >/dev/null
    echo "installed $plist"
}

write_plist loginwindow LoginWindow
if ((AQUA)); then
    write_plist aqua Aqua --request
    # Load the control instance into the current GUI session now; the LoginWindow one
    # is loaded by launchd whenever a login-window session starts.
    launchctl bootout "gui/$OWNER_UID/$PREFIX.aqua" 2>/dev/null || true
    launchctl bootstrap "gui/$OWNER_UID" "/Library/LaunchAgents/$PREFIX.aqua.plist"
    echo "started the Aqua control instance (results: $OUT/latest-aqua/)"
else
    rm -f "/Library/LaunchAgents/$PREFIX.aqua.plist"
fi

cat <<EOF

Installed $DEST
  $(codesign -dv "$DEST" 2>&1 | grep -E '^(Identifier|CDHash)=' | tr '\n' ' ')

Next: grant Screen Recording and Accessibility to $DEST in System Settings ›
Privacy & Security (use + and Cmd-Shift-G if it isn't listed), then follow the
README's test procedure.
EOF
