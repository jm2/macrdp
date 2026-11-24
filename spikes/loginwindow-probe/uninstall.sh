#!/bin/bash
# Removes the Phase 0 LoginWindow probe. Results in /Users/Shared/macrdp-lwprobe are
# kept unless --purge is given.
#
#   sudo spikes/loginwindow-probe/uninstall.sh [--purge]
set -euo pipefail
PREFIX="com.github.jm2.macrdp-lwprobe"
OUT="/Users/Shared/macrdp-lwprobe"
PURGE=0
for arg in "$@"; do
    case "$arg" in
    --purge) PURGE=1 ;;
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
if [[ -n "${SUDO_UID:-}" ]]; then
    launchctl bootout "gui/$SUDO_UID/$PREFIX.aqua" 2>/dev/null || true
fi
pkill -f /Library/PrivilegedHelperTools/macrdp-lwprobe 2>/dev/null || true
rm -f "/Library/LaunchAgents/$PREFIX.loginwindow.plist" "/Library/LaunchAgents/$PREFIX.aqua.plist"
rm -f /Library/PrivilegedHelperTools/macrdp-lwprobe
if ((PURGE)); then rm -rf "$OUT"; fi
echo "removed the probe$( ((PURGE)) && echo ' and its results')."
echo "Also remove 'macrdp-lwprobe' from System Settings › Privacy & Security ›"
echo "Screen & System Audio Recording and Accessibility."
