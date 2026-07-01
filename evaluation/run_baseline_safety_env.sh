#!/bin/bash
# Re-run the gpt-5 prompt-baselines for the safety + environment conditions after
# the temperature=0 crash (see config.toml [llm.gpt5] temperature=1.0 fix).
#
# Self-contained: pins absolute poetry + venv paths so it works in a detached
# tmux shell with no env activation. It archives the dead crashed outputs first
# so run_promptbaseline.sh's "already evaluated" skip-logic does not short-circuit
# the re-run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Absolute paths resolved during the 2026-06-02 environment rebuild.
POETRY="/root/.local/bin/poetry"
PYBIN="/root/.cache/pypoetry/virtualenvs/theagentcompany-gHjgYKap-py3.12/bin/python"

# Sanity: the OpenHands venv python must exist and import openhands, else the
# multi-hour run would crash on the first task's import.
if [ ! -x "$PYBIN" ]; then
    echo "ERROR: venv python not found at $PYBIN. Run 'poetry install --with evaluation' first." >&2
    exit 1
fi
if ! "$PYBIN" -c "import openhands" 2>/dev/null; then
    echo "ERROR: 'import openhands' failed in $PYBIN. Rebuild the venv." >&2
    exit 1
fi
echo "Using PYBIN=$PYBIN"
export PYBIN

# 1. Move the dead (temperature-crashed) outputs aside instead of deleting, so
#    they can be inspected/restored if needed.
for cond in safety environment; do
    d="promptbaseline-gpt5-${cond}"
    if [ -d "$d" ]; then
        echo "Archiving dead outputs: $d -> ${d}.dead"
        rm -rf "${d}.dead"
        mv "$d" "${d}.dead"
    fi
done

# 2. Launch the re-run. Conditions are COMMA-separated. 244-task benign list.
#    The agent now uses temperature=1.0 (gpt-5 compatible). run_promptbaseline.sh
#    uses the exported PYBIN above for run_eval.py.
exec ./run_promptbaseline.sh \
    --agent-llm-config gpt5 \
    --conditions safety,environment \
    --task-list promptbaseline_benign.txt \
    --server-hostname localhost
