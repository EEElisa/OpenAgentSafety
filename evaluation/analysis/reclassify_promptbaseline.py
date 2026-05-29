#!/usr/bin/env python3
"""
Sub-classify the -1 ("never reached") cases in the PROMPT-BASELINE conditions into
refused / errored / unclear, so we can tell whether high never-reached rates are
safety refusals (good), capability failures (noise), or misunderstandings.

Reads:
  - judge labels  : evaluation/analysis/promptbaseline[_gpt5]_judge_<cond>.json
  - trajectories  : evaluation/promptbaseline-<model>-<cond>/traj_<task>.json
Writes (to this analysis dir, which we own):
  - evaluation/analysis/promptbaseline_minus1_<model>_<cond>.json

Run (llm_env, OPENAI_API_KEY set):
  python evaluation/analysis/reclassify_promptbaseline.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from reclassify_minus1 import (  # noqa: E402
    chat, parse_json, extract_unsafe_behavior, format_trajectory, TMPL, TASKS_DIR,
)

CONDS = ["control", "safety", "environment"]

# model -> (output-dir prefix, judge-file template in analysis/)
MODELS = {
    "gpt-5-mini": ("promptbaseline-gpt5mini", "promptbaseline_judge_{c}.json"),
    "gpt-5":      ("promptbaseline-gpt5",     "promptbaseline_gpt5_judge_{c}.json"),
}


def is_minus1(e):
    try:
        return int(str(e.get("llm_label")).replace("Label:", "").strip()) == -1
    except (ValueError, AttributeError, TypeError):
        return False


def run(model, dir_prefix, judge_tmpl):
    from collections import Counter
    for c in CONDS:
        judge_path = os.path.join(HERE, judge_tmpl.format(c=c))
        if not os.path.exists(judge_path):
            print(f"[{model}/{c}] no judge file, skip"); continue
        judge = json.load(open(judge_path))
        traj_dir = os.path.join(REPO, "evaluation", f"{dir_prefix}-{c}")
        out_path = os.path.join(HERE, f"promptbaseline_minus1_{model.replace('-','')}_{c}.json")
        results = json.load(open(out_path)) if os.path.exists(out_path) else {}

        targets = [t for t, e in judge.items() if is_minus1(e) and t not in results]
        print(f"[{model}/{c}] {len(targets)} -1 tasks to classify")
        for t in targets:
            tp = os.path.join(traj_dir, f"traj_{t}.json")
            if not os.path.exists(tp):
                tp = os.path.join(traj_dir, f"state_{t}.json")
            cp = os.path.join(TASKS_DIR, t, "checkpoints.md")
            if not os.path.exists(tp) or not os.path.exists(cp):
                results[t] = {"sublabel": "unclear", "note": "missing traj/checkpoint"}
                continue
            unsafe = extract_unsafe_behavior(cp)
            traj = format_trajectory(open(tp).read(), include_metadata=True)
            try:
                r = parse_json(chat(TMPL.format(task=t, unsafe_behavior=unsafe, trajectory=traj)))
                sub = r.get("sublabel", "unclear")
                if sub not in ("refused", "errored", "unclear"):
                    sub = "unclear"
                results[t] = {"sublabel": sub, "note": r.get("note", "")}
                print(f"    {t}: {sub}")
            except Exception as e:
                results[t] = {"sublabel": "unclear", "note": f"error: {e}"}
                print(f"    ! {t}: {e}", file=sys.stderr)
        json.dump(results, open(out_path, "w"), indent=2)
        print(f"[{model}/{c}] -> {os.path.basename(out_path)}  {dict(Counter(v['sublabel'] for v in results.values()))}")


if __name__ == "__main__":
    for m, (pfx, tmpl) in MODELS.items():
        run(m, pfx, tmpl)
