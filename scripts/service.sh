#!/bin/zsh
# Run Orbit in the background on this Mac, as a launchd service for your user account.
# It restarts by itself if it stops unexpectedly, and keeps the Mac awake while it's
# plugged in (on battery it sleeps as usual). It does NOT start when you log in: start it
# with `start` below or from the Orbit Mac app. Add --login to start it at login too.
#
#   scripts/service.sh install [--lan] [--login]   set it up and start it
#                                        --lan: phones on your Wi-Fi can open it
#                                        --login: also start it by itself whenever you log in
#   scripts/service.sh status            is it running, and is it recording?
#   scripts/service.sh logs              follow its log (Ctrl+C stops following, not Orbit)
#   scripts/service.sh restart           restart it, for example after updating Orbit's code
#   scripts/service.sh stop              stop it until you start it again
#   scripts/service.sh start             start it again after a stop
#   scripts/service.sh uninstall         stop it and remove the background service
set -euo pipefail

LABEL=local.orbit.dashboard
ROOT=${0:A:h:h}
# macOS starts every service file in LaunchAgents at login, so the file lives there only with --login.
# Otherwise it sits in Orbit's own folder, and the app and this script start it by path.
PLIST_LOGIN=$HOME/Library/LaunchAgents/$LABEL.plist
PLIST_HOME="$HOME/Library/Application Support/Orbit/$LABEL.plist"
if [[ -f "$PLIST_LOGIN" ]]; then PLIST=$PLIST_LOGIN; else PLIST=$PLIST_HOME; fi
LOG=$HOME/Library/Logs/Orbit/orbit.log
DOMAIN=gui/$(id -u)
PY=$ROOT/.venv/bin/python

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 }

# Stopping takes a few seconds: Orbit saves what it has first, and macOS lists the service until it has gone.
unload() {
  launchctl bootout "$DOMAIN/$LABEL" || true
  local i
  for i in {1..60}; do loaded || return 0; sleep 0.5; done
  echo "Orbit is still saving. Give it a moment, then try again."; return 1
}

write_plist() {
  local lan=""
  [[ "$1" == *--lan* ]] && lan="<string>--lan</string>"
  mkdir -p "${PLIST:h}" "${LOG:h}"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string><string>-m</string><string>orbit</string><string>--keep-awake</string><string>--wait</string>$lan
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
}

summary() {
  local json
  json=$(curl -s --max-time 3 http://127.0.0.1:8787/api/state) || json=""
  if [[ -z "$json" ]]; then
    echo "  Not answering at http://localhost:8787 yet. Check: scripts/service.sh logs"
    return 0
  fi
  ORBIT_STATE=$json "$PY" - <<'PYEOF'
import json, os
s = json.loads(os.environ["ORBIT_STATE"])
d, r = s["dish"], s["router"]
up = (s["now"] - s["started"]) / 1000
dish = "online" if d["online"] else ("not reachable" if d["reachable"] is False else "offline")
router = "reachable" if r["reachable"] else "not reachable"
online = sum(1 for x in s["devices"] if x["online"])
today = (s["home"]["down"] + s["home"]["up"]) / 1e9
print(f"  Answering at http://localhost:8787, running for {int(up // 3600)} h {int(up % 3600 // 60)} min")
print(f"  Dish {dish} · router {router} · {online} devices online · {today:.2f} GB today")
if d["reachable"] is False or r["reachable"] is False:
    print("  If this lasts, macOS may be blocking Orbit from your home network:")
    print("  System Settings > Privacy & Security > Local Network, then turn on Python.")
PYEOF
}

case "${1:-}" in
  install)
    [[ -x "$PY" ]] || { echo "Set up Orbit first: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"; exit 1 }
    if loaded; then unload || exit 1; fi
    rm -f "$PLIST_LOGIN" "$PLIST_HOME"
    if [[ " $* " == *" --login "* ]]; then PLIST=$PLIST_LOGIN; else PLIST=$PLIST_HOME; fi
    write_plist "$*"
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true  # undo a switch-off in System Settings > Login Items
    launchctl bootstrap "$DOMAIN" "$PLIST"
    if [[ "$PLIST" == "$PLIST_LOGIN" ]]; then
      echo "Orbit now runs in the background and starts by itself when you log in."
    else
      echo "Orbit now runs in the background. It won't start by itself when you log in:"
      echo "start it with scripts/service.sh start or from the Orbit app (install with --login to change that)."
    fi
    echo "Open http://localhost:8787 · log: $LOG"
    ;;
  status)
    if ! loaded; then echo "Orbit isn't running in the background. Start it with: scripts/service.sh start"; exit 0; fi
    launchctl print "$DOMAIN/$LABEL" | awk -F' = ' '/^\tstate = /{print "  State: " $2} /^\tpid = /{print "  Process: " $2} /^\tlast exit code = /{print "  Last exit: " $2}'
    summary
    code=$(grep -o "Access code for other devices: [0-9-]*" "$LOG" 2>/dev/null | tail -1 || true)
    if [[ -n "$code" ]]; then echo "  $code"; fi
    ;;
  logs)
    tail -n 40 -f "$LOG"
    ;;
  restart)
    loaded || { echo "Not installed. Run: scripts/service.sh install"; exit 1 }
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "Restarted."
    ;;
  stop)
    if loaded; then
      unload || exit 1
      if [[ "$PLIST" == "$PLIST_LOGIN" ]]; then echo "Stopped. It starts again next time you log in, or with: scripts/service.sh start"
      else echo "Stopped. Start it again with: scripts/service.sh start, or from the Orbit app."; fi
    else echo "It wasn't running."; fi
    ;;
  start)
    [[ -f "$PLIST" ]] || { echo "Not installed. Run: scripts/service.sh install"; exit 1 }
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true  # undo a switch-off in System Settings > Login Items
    if loaded; then launchctl kickstart "$DOMAIN/$LABEL"; else launchctl bootstrap "$DOMAIN" "$PLIST"; fi
    echo "Started. Open http://localhost:8787"
    ;;
  uninstall)
    if loaded; then unload || exit 1; fi
    rm -f "$PLIST_LOGIN" "$PLIST_HOME"
    echo "Removed the background service. Your history in data/orbit.db is kept."
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
