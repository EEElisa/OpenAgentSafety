#!/bin/bash
# Watchdog for the prompt-baseline run. Checks api-server liveness, eval progress,
# and the driver process. Auto-restarts api-server if it dies. Prints a status line
# each cycle; prints ALERT lines on problems (so the caller can grep for ALERT).
cd /weka/oe-adapt-default/mingqianz/OpenAgentSafety/evaluation

count() { ls "$1"/eval_*.json 2>/dev/null | wc -l | tr -d ' '; }
apicode() { docker run --rm --network host curlimages/curl:latest -s -o /dev/null \
  -w "%{http_code}" --max-time 6 http://127.0.0.1:2999/api/healthcheck/gitlab 2>/dev/null | tail -1; }
driver_up() { pgrep -f "run_eval.py --agent-llm-config gpt5" >/dev/null; }

prev_total=-1
stall_cycles=0
api_fail_streak=0
CYCLE=${CYCLE:-180}        # seconds between checks
STALL_LIMIT=${STALL_LIMIT:-8}   # cycles with no new eval file before stall alert (~24min)

while true; do
  ts=$(date -u +%H:%M:%SZ)
  s=$(count promptbaseline-gpt5-safety)
  e=$(count promptbaseline-gpt5-environment)
  total=$((s + e))

  # api-server liveness
  if docker ps --format '{{.Names}}' | grep -q '^api-server$'; then
    code=$(apicode)
    if [ "$code" = "000" ] || [ -z "$code" ]; then
      api_fail_streak=$((api_fail_streak+1))
    else
      api_fail_streak=0
    fi
  else
    code="GONE"
    api_fail_streak=$((api_fail_streak+1))
  fi

  # Auto-recover api-server after 2 consecutive failures (tolerate transient 502/flap)
  if [ "$api_fail_streak" -ge 2 ]; then
    echo "$ts ALERT api-server unreachable (code=$code, streak=$api_fail_streak) -> restarting"
    (cd ../servers && make start-api-server >/dev/null 2>&1)
    echo "$ts ACTION ran 'make start-api-server'; will re-verify next cycle. NOTE: re-run the launch command to resume skipped tasks if any failed."
    api_fail_streak=0
  fi

  # progress / stall
  if [ "$total" -le "$prev_total" ]; then
    stall_cycles=$((stall_cycles+1))
  else
    stall_cycles=0
  fi
  prev_total=$total

  # driver process check
  if driver_up; then dstat="driver:UP"; else dstat="driver:EXITED"; fi

  echo "$ts STATUS safety=$s/244 env=$e/244 total=$total api=$code $dstat stall=$stall_cycles"

  if ! driver_up; then
    echo "$ts ALERT driver process exited. If safety+env < 488 and not intentionally stopped, re-run the launch command (idempotent)."
    echo "$ts DONE watchdog exiting (driver gone)"
    break
  fi
  if [ "$stall_cycles" -ge "$STALL_LIMIT" ]; then
    echo "$ts ALERT no new eval files in $stall_cycles cycles (~$((stall_cycles*CYCLE/60))min) - possible hang. Check the run log."
    stall_cycles=0
  fi

  sleep "$CYCLE"
done
