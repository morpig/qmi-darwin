#!/bin/sh
# Runs the debug qmid under launchd (system domain) until unload or reboot.
# Nothing is copied into /Library/LaunchDaemons. Needs root.
#
#   scripts/dev-daemon.sh load     build, then bootstrap .build/debug/qmid as com.qmi-darwin.qmid
#   scripts/dev-daemon.sh unload   bootout (qmid shuts down cleanly on SIGTERM)
#   scripts/dev-daemon.sh log      follow qmid's unified log (add --level debug for the QMI trace)
set -eu

label=com.qmi-darwin.qmid
root=$(cd "$(dirname "$0")/.." && pwd)
plist="$root/.build/$label.dev.plist"

case "${1:-}" in
load)
    swift build --package-path "$root"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$root/.build/debug/qmid</string></array>
    <key>MachServices</key><dict><key>$label</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
    # launchd only loads system-domain plists owned by root and not group/world-writable.
    chown root:wheel "$plist"
    chmod 644 "$plist"
    if launchctl print system/$label >/dev/null 2>&1; then
        launchctl bootout system/$label || true
        # bootout returns before the job is gone; bootstrap fails with EIO until it is.
        i=0
        while launchctl print system/$label >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    fi
    # The old qmid may still be stopping its calls; bootstrap fails with EIO until it exits.
    i=0
    while pgrep -x qmid >/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    i=0
    until launchctl bootstrap system "$plist" 2>/dev/null; do
        i=$((i + 1))
        [ $i -ge 10 ] && { launchctl bootstrap system "$plist"; exit 1; }
        sleep 0.5
    done
    echo "loaded $label from $root/.build/debug/qmid"
    ;;
unload)
    launchctl bootout system/$label
    echo "unloaded $label"
    ;;
log)
    shift
    [ $# -gt 0 ] || set -- --level info
    exec log stream --style compact --predicate 'subsystem == "com.qmi-darwin.qmid"' "$@"
    ;;
*)
    echo "usage: $0 load|unload|log" >&2
    exit 2
    ;;
esac
