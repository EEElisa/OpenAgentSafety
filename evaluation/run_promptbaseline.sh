#!/bin/bash
# Prompt-baseline experiment: run the same task list under 3 prompt conditions
# (control / safety / environment) with the SAME model, into separate output dirs.
# Differs from run_eval.sh only in: iterating an explicit task list + 3 conditions.
#
# Prereqs (see docs/SETUP.md): Docker + servers up, `poetry install` done, config.toml
# with the agent model block. Run as root from the evaluation/ directory.
#
# Usage:
#   bash run_promptbaseline.sh \
#     --agent-llm-config gpt5mini \
#     --env-llm-config gpt5mini \
#     --task-list promptbaseline_smoke10.txt \
#     --server-hostname localhost

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="$(cd "$SCRIPT_DIR/../workspaces/tasks" && pwd)"

AGENT_LLM_CONFIG="gpt5mini"
ENV_LLM_CONFIG="gpt5mini"          # used only by the LLM evaluator here (no NPCs)
TASK_LIST="promptbaseline_smoke10.txt"
SERVER_HOSTNAME="localhost"
CONDITIONS=("control" "safety" "environment")
# Call the venv Python directly so this works as root (poetry env resolution
# breaks under sudo). Override with PYBIN=... if your venv path differs.
PYBIN="${PYBIN:-/root/.cache/pypoetry/virtualenvs/theagentcompany-gHjgYKap-py3.12/bin/python}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-llm-config) AGENT_LLM_CONFIG="$2"; shift 2;;
        --env-llm-config)   ENV_LLM_CONFIG="$2";   shift 2;;
        --task-list)        TASK_LIST="$2";        shift 2;;
        --server-hostname)  SERVER_HOSTNAME="$2";  shift 2;;
        --conditions)       IFS=',' read -ra CONDITIONS <<< "$2"; shift 2;;
        *) echo "Unknown argument: $1"; exit 1;;
    esac
done

if [ ! -f "$SCRIPT_DIR/$TASK_LIST" ]; then
    echo "Task list not found: $SCRIPT_DIR/$TASK_LIST"; exit 1
fi
mapfile -t TASKS < "$SCRIPT_DIR/$TASK_LIST"

# run_eval.py instantiates a global openai client at import (used by the NPC
# FakeUser). Export the agent key as OPENAI_API_KEY so that import succeeds even
# though the no-NPC tasks never call it.
if [ -z "$OPENAI_API_KEY" ] && [ -f "$SCRIPT_DIR/config.toml" ]; then
    OPENAI_API_KEY=$("$PYBIN" -c "import tomllib;print(tomllib.load(open('$SCRIPT_DIR/config.toml','rb'))['llm']['$AGENT_LLM_CONFIG']['api_key'])" 2>/dev/null)
    export OPENAI_API_KEY
fi

echo "Agent model: $AGENT_LLM_CONFIG | conditions: ${CONDITIONS[*]} | tasks: ${#TASKS[@]}"

# Pre-create the output dirs.
for cond in "${CONDITIONS[@]}"; do
    mkdir -p "$SCRIPT_DIR/promptbaseline-${AGENT_LLM_CONFIG}-${cond}"
done

# Loop tasks OUTER, conditions INNER: every task gets run under all conditions
# before moving on, so a partial/interrupted run still yields complete, comparable
# results for the tasks finished so far.
for task_name in "${TASKS[@]}"; do
    [ -z "$task_name" ] && continue
    task_dir="$TASKS_DIR/$task_name"
    if [ ! -d "$task_dir" ]; then
        echo "skip $task_name (no task dir)"; continue
    fi
    echo "=== task: $task_name ==="
    for cond in "${CONDITIONS[@]}"; do
        OUT="$SCRIPT_DIR/promptbaseline-${AGENT_LLM_CONFIG}-${cond}"
        if [ -f "$OUT/eval_${task_name}.json" ]; then
            echo "  skip [$cond] (already evaluated)"; continue
        fi
        echo "  running [$cond]"
        cd "$SCRIPT_DIR"
        "$PYBIN" run_eval.py \
            --agent-llm-config "$AGENT_LLM_CONFIG" \
            --env-llm-config "$ENV_LLM_CONFIG" \
            --outputs-path "$OUT" \
            --server-hostname "$SERVER_HOSTNAME" \
            --task-path "$task_dir/" \
            --safety-prompt "$cond"
    done
done

echo "All prompt-baseline conditions completed."
