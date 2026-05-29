#!/bin/bash
# Pre-flight checks for the prompt-baseline experiment.
# Verifies the environment is ready BEFORE you spend time on a real run.
# Safe to run repeatedly. Does not modify anything.
#
# Usage:
#   bash preflight.sh                      # uses defaults (gpt5mini, smoke list)
#   POETRY=$(which poetry) bash preflight.sh
#   bash preflight.sh --agent-llm-config gpt5mini --task-list promptbaseline_smoke10.txt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_IMAGE="${OAS_BASE_IMAGE:-openagentsafety-base:latest}"
POETRY="${POETRY:-poetry}"
AGENT_LLM_CONFIG="gpt5mini"
TASK_LIST="promptbaseline_smoke10.txt"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-llm-config) AGENT_LLM_CONFIG="$2"; shift 2;;
        --task-list)        TASK_LIST="$2";        shift 2;;
        *) shift;;
    esac
done

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ]  $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL]  $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [warn]  $1"; WARN=$((WARN+1)); }

echo "=== OpenAgentSafety prompt-baseline pre-flight ==="

# 1. Docker usable
echo "Docker:"
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "docker works ($(docker --version | awk '{print $3}' | tr -d ,))"
    else
        bad "docker installed but cannot connect to daemon (perms? try: sudo chmod 666 /var/run/docker.sock, or re-login after usermod -aG docker)"
    fi
else
    bad "docker not found on PATH"
fi

# 2. Base image built
echo "Base image:"
if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    ok "base image present: $BASE_IMAGE"
else
    bad "base image '$BASE_IMAGE' not found. Build it:
            cd $REPO/workspaces/openagentsafety_base_image && docker build -t $BASE_IMAGE ."
fi

# 3. Poetry + OpenHands import
echo "Python / OpenHands:"
if command -v "$POETRY" >/dev/null 2>&1 || [ -x "$POETRY" ]; then
    ok "poetry found ($POETRY)"
    if (cd "$REPO" && "$POETRY" run python -c "import openhands" >/dev/null 2>&1); then
        ok "openhands imports inside poetry env"
    else
        bad "openhands not importable in poetry env. Run: cd $REPO && $POETRY install"
    fi
    if (cd "$REPO" && "$POETRY" run python -c "import openai" >/dev/null 2>&1); then
        ok "openai SDK present in poetry env"
    else
        warn "openai SDK not importable in poetry env (run_eval.py imports it)"
    fi
else
    bad "poetry not found. Install it, or pass POETRY=/path/to/poetry"
fi

# 4. config.toml + agent config block
echo "Config:"
CFG="$SCRIPT_DIR/config.toml"
if [ -f "$CFG" ]; then
    ok "config.toml exists"
    if grep -q "\[llm.${AGENT_LLM_CONFIG}\]" "$CFG"; then
        ok "config block [llm.${AGENT_LLM_CONFIG}] found"
        if grep -A4 "\[llm.${AGENT_LLM_CONFIG}\]" "$CFG" | grep -q "REPLACE_WITH_YOUR_KEY"; then
            bad "api_key still set to REPLACE_WITH_YOUR_KEY in [llm.${AGENT_LLM_CONFIG}]"
        else
            ok "api_key appears to be set"
        fi
    else
        bad "no [llm.${AGENT_LLM_CONFIG}] block in config.toml (copy from config.toml.template)"
    fi
else
    bad "config.toml missing. Run: cp $SCRIPT_DIR/config.toml.template $CFG  then edit it"
fi

# 5. Task list + task dirs exist
echo "Tasks:"
LIST="$SCRIPT_DIR/$TASK_LIST"
if [ -f "$LIST" ]; then
    n=$(grep -cve '^\s*$' "$LIST")
    ok "task list found: $TASK_LIST ($n tasks)"
    missing=0
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        [ -d "$REPO/workspaces/tasks/$t" ] || { warn "no task dir: $t"; missing=$((missing+1)); }
    done < "$LIST"
    [ "$missing" -eq 0 ] && ok "all task dirs present"
else
    bad "task list not found: $LIST"
fi

# 6. Servers (informational only - smoke tasks have no deps)
echo "Servers (optional for no-dependency tasks):"
if curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:2999/api/healthcheck/owncloud 2>/dev/null | grep -q 200; then
    ok "api-server reachable on :2999 (servers up)"
else
    warn "api-server not reachable on :2999 - fine for the no-dep smoke tasks, REQUIRED for tasks needing owncloud/gitlab/plane"
fi

echo ""
echo "=== summary: $PASS ok, $WARN warn, $FAIL fail ==="
if [ "$FAIL" -gt 0 ]; then
    echo "Resolve the [FAIL] items above before running run_promptbaseline.sh."
    exit 1
else
    echo "Ready. Run: POETRY=$POETRY bash run_promptbaseline.sh --agent-llm-config $AGENT_LLM_CONFIG --task-list $TASK_LIST"
    exit 0
fi
