#!/bin/bash
# unrealed-cmd.sh <editor command> [max seconds]
#
# Reference implementation of the send-confirm-wait pattern for UnrealEd. Linux
# and Git Bash; a real UnrealEdMCP service should do the same thing in its own
# language rather than shell out to this.
#
# Send one editor command, confirm UnrealEd took it, then wait for it to finish.
#
# Three things make naive automation unreliable:
#  * A command sent while the editor is BUSY is silently dropped -- the bridge
#    still exits 0. Autosave (every 5 min, ~60s) is the usual cause, so turn it
#    off; even then a command must be confirmed.
#  * System/UnrealEd.log on disk lags the log WINDOW by an unbounded amount, so
#    the file can confirm nothing. unrealed-log.exe reads the window.
#  * The window's control has a BOUNDED scrollback, so a chatty command scrolls
#    its own "Cmd:" line away -- MAP REBUILD logs a block per brush. Receipt is
#    therefore any of: the Cmd line appearing, the text changing, or the process
#    going busy.
BR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEND="$BR/unrealed-send.exe"; LOGTOOL="$BR/unrealed-log.exe"
CMD="$1"; MAXWAIT=${2:-7200}
PID=$(pgrep -x UnrealEd.exe) || { echo "UnrealEd is not running"; exit 1; }
HZ=$(getconf CLK_TCK)
INSTALL=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.sweeney/config.json')))['install_root'])")
cd "$INSTALL/System"

state() { wine "$LOGTOOL" 2>/dev/null | md5sum | cut -c1-32; }
hascmd() { wine "$LOGTOOL" 2>/dev/null | grep -cF "Cmd: $CMD"; }
cpu() {
  read a b < <(awk '{print $14, $15}' /proc/$PID/stat 2>/dev/null); sleep 1
  read c d < <(awk '{print $14, $15}' /proc/$PID/stat 2>/dev/null)
  [ -z "$c" ] && { echo -1; return; }
  echo $(( ((c + d) - (a + b)) * 100 / HZ ))
}

st0=$(state); n0=$(hascmd); got=0
for attempt in 1 2 3 4 5 6; do
  # Never discard the bridge's stderr. It reports the one failure that looks
  # identical to "editor busy" from the outside: exit 6, "Could not focus
  # UnrealEd's Command control", which means a modeless dialog -- Build Options
  # is the usual one -- holds the keyboard focus. No amount of retrying fixes
  # that; the dialog has to be closed.
  err=$(wine "$SEND" "$CMD" 2>&1 >/dev/null | grep -v "^....:fixme")
  rc=${PIPESTATUS[0]}
  if [ -n "$err" ]; then echo "   bridge: $err"; fi
  if [ "$rc" = 6 ]; then
    echo "$CMD -- BLOCKED: close UnrealEd's open dialog and retry"
    exit 6
  fi
  for w in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    [ "$(hascmd)" -gt "$n0" ] && { got=1; break; }
    [ "$(state)" != "$st0" ] && { got=1; break; }
    [ "$(cpu)" -ge 15 ] && { got=1; break; }
  done
  [ $got = 1 ] && break
  echo "   (attempt $attempt: no sign of it -- retrying)"
done
[ $got = 0 ] && { echo "$CMD -- NEVER RECEIVED"; exit 1; }

busy=0; idle=0; t=0
while [ $t -lt "$MAXWAIT" ]; do
  c=$(cpu); t=$((t+2)); sleep 1
  [ "$c" -lt 0 ] && { echo "$CMD -- UnrealEd exited"; exit 1; }
  if [ "$c" -ge 15 ]; then busy=1; idle=0; else idle=$((idle+1)); fi
  [ $busy = 1 ] && [ $idle -ge 10 ] && break
  [ $busy = 0 ] && [ $idle -ge 25 ] && break
done
echo "$CMD -- ok, ${t}s, did work: $busy"
