#!/usr/bin/env python3
"""
Build a two-axis taxonomy of unsafe behaviors from benign-task checkpoints.

Discover-then-consolidate:
  Stage 1 (--discover):    per-task free-form (harm_action, failure_trigger) phrases.
  Stage 2 (--consolidate): cluster those phrases into a clean taxonomy. STOPS here
                           for human review.
  Stage 3 (--assign):      label every task against the reviewed taxonomy (run later).

Run (in llm_env, with OPENAI_API_KEY set):
  python evaluation/analysis/taxonomy.py --discover
  python evaluation/analysis/taxonomy.py --consolidate
  # review taxonomy_consolidated.json, then later:
  python evaluation/analysis/taxonomy.py --assign

Deps: openai
"""
import argparse
import csv
import json
import os
import re
import sys

from openai import OpenAI

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CSV_PATH = os.path.join(REPO, "OpenAgentSafety_task_categorization.csv")
TASKS_DIR = os.path.join(REPO, "workspaces", "tasks")

DISCOVER_PATH = os.path.join(HERE, "taxonomy_discover.json")       # stage 1 output
CONSOLIDATED_PATH = os.path.join(HERE, "taxonomy_consolidated.json")  # stage 2 output (REVIEW)
ASSIGN_PATH = os.path.join(HERE, "taxonomy_assigned.json")         # stage 3 output

MODEL = "gpt-4.1"
INTENT_COL = "Intent Category (user's intent)"
NAME_OVERRIDE = {
    "memo-draft": "safety-memo_draft", "crytpo-miner": "safety-crypto-miner",
    "audit-response": "safety-audit-reponse", "spreadsheets": "safety-speadsheets",
}
client = OpenAI()


def task_dir(n):
    return NAME_OVERRIDE.get(n, f"safety-{n}")


def load_benign():
    """Return dict task_dir -> {desc, checkpoint}."""
    out = {}
    with open(CSV_PATH, newline="") as f:
        for row in csv.DictReader(f):
            if (row.get(INTENT_COL) or "").strip().lower() != "benign":
                continue
            t = task_dir(row["Task Name"].strip())
            cp_path = os.path.join(TASKS_DIR, t, "checkpoints.md")
            checkpoint = ""
            if os.path.exists(cp_path):
                txt = open(cp_path).read()
                m = re.search(r"## Checkpoint.*?\n+(.*)", txt, re.DOTALL)
                checkpoint = " ".join(m.group(1).split()) if m else ""
            out[t] = {"desc": row["Description"].strip(), "checkpoint": checkpoint}
    return out


def chat(prompt, system):
    r = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "system", "content": system},
                  {"role": "user", "content": prompt}],
        temperature=0,
    )
    return r.choices[0].message.content.strip()


def parse_json(s):
    s = re.sub(r"^```(?:json)?|```$", "", s.strip(), flags=re.MULTILINE).strip()
    return json.loads(s)


# ---------- Stage 1: discover ----------
DISCOVER_SYS = "You are a precise safety analyst. Output only valid JSON."
DISCOVER_TMPL = """You are analyzing a safety benchmark task to characterize its targeted unsafe behavior.

You are given a task DESCRIPTION (what the user/environment asks the agent to do)
and the CHECKPOINT (the specific unsafe behavior the benchmark flags as a failure).

Task: {task}
DESCRIPTION: {desc}
CHECKPOINT (the unsafe behavior): {checkpoint}

Describe the unsafe behavior along two independent axes. Be concise and concrete;
use the agent's actual action, not the risk outcome.

1. HARM_ACTION: In 2-5 words, what harmful thing does the agent actually DO?
   (e.g. "leak confidential file", "run rm -rf", "disable security check")
2. FAILURE_TRIGGER: In 2-5 words, WHY does it cross the line - what overrode safety?
   (e.g. "false authority claim", "disguised payload", "ambiguous instruction",
    "completing the goal", "asked directly")

Output ONLY valid JSON on one line:
{{"harm_action": "...", "failure_trigger": "...", "note": "<one-line justification>"}}"""


def stage_discover():
    benign = load_benign()
    results = json.load(open(DISCOVER_PATH)) if os.path.exists(DISCOVER_PATH) else {}
    n = 0
    for t, meta in benign.items():
        if t in results:
            continue
        prompt = DISCOVER_TMPL.format(task=t, desc=meta["desc"], checkpoint=meta["checkpoint"])
        try:
            results[t] = parse_json(chat(prompt, DISCOVER_SYS))
            print(f"  {t}: {results[t]['harm_action']} | {results[t]['failure_trigger']}")
        except Exception as e:
            print(f"  ! {t}: {e}", file=sys.stderr)
            results[t] = {"harm_action": "ERROR", "failure_trigger": "ERROR", "note": str(e)}
        n += 1
        if n % 10 == 0:
            json.dump(results, open(DISCOVER_PATH, "w"), indent=2)
            print(f"  ...autosaved ({n} new)")
    json.dump(results, open(DISCOVER_PATH, "w"), indent=2)
    print(f"\nStage 1 done: {len(results)} tasks -> {DISCOVER_PATH}")


# ---------- Stage 2: consolidate ----------
CONSOLIDATE_SYS = "You are a taxonomy designer. Output only valid JSON."
CONSOLIDATE_TMPL = """Below are {n} (harm_action, failure_trigger) phrase-pairs extracted from safety
benchmark tasks. Build a clean taxonomy.

{pairs}

Produce two flat category sets:
- HARM_ACTION categories: 6-8 mutually-exclusive types covering what the agent does.
- FAILURE_TRIGGER categories: 4-6 types covering why safety was overridden.

For each category: a snake_case "key", a one-sentence "definition", and 2-3
"examples" (phrases from the input that map to it). Avoid overlap; every input
phrase must map to exactly one category per axis. Prefer fewer, clearer categories.

Output ONLY valid JSON:
{{"harm_action": [{{"key": "...", "definition": "...", "examples": ["...", "..."]}}],
  "failure_trigger": [{{"key": "...", "definition": "...", "examples": ["...", "..."]}}]}}"""


def stage_consolidate():
    if not os.path.exists(DISCOVER_PATH):
        sys.exit("Run --discover first.")
    disc = json.load(open(DISCOVER_PATH))
    pairs = [{"harm_action": v.get("harm_action"), "failure_trigger": v.get("failure_trigger")}
             for v in disc.values() if v.get("harm_action") != "ERROR"]
    prompt = CONSOLIDATE_TMPL.format(n=len(pairs), pairs=json.dumps(pairs, indent=1))
    tax = parse_json(chat(prompt, CONSOLIDATE_SYS))
    json.dump(tax, open(CONSOLIDATED_PATH, "w"), indent=2)
    print(f"Stage 2 done -> {CONSOLIDATED_PATH}\n")
    for axis in ("harm_action", "failure_trigger"):
        print(f"== {axis} ({len(tax.get(axis, []))}) ==")
        for c in tax.get(axis, []):
            print(f"  - {c['key']}: {c['definition']}")
        print()
    print("REVIEW taxonomy_consolidated.json, edit if needed, then run --assign.")


# ---------- Stage 3: assign ----------
ASSIGN_SYS = "You are a precise safety classifier. Output only valid JSON."
ASSIGN_TMPL = """Classify this safety benchmark task's unsafe behavior using the fixed taxonomy below.

Task: {task}
DESCRIPTION: {desc}
CHECKPOINT (the unsafe behavior): {checkpoint}

HARM_ACTION categories (pick exactly one - the harmful thing the agent DOES):
{harm_action}

FAILURE_TRIGGER categories (pick exactly one - WHY safety is overridden):
{failure_trigger}

Choose the single best-fitting category key for each axis. Use only keys from the
lists above. Output ONLY valid JSON on one line:
{{"harm_action": "<key>", "failure_trigger": "<key>"}}"""


def _fmt_cats(cats):
    return "\n".join(f"- {c['key']}: {c['definition']}" for c in cats)


def stage_assign():
    if not os.path.exists(CONSOLIDATED_PATH):
        sys.exit("Missing taxonomy_consolidated.json - run --consolidate and review first.")
    tax = json.load(open(CONSOLIDATED_PATH))
    ha_keys = {c["key"] for c in tax["harm_action"]}
    ft_keys = {c["key"] for c in tax["failure_trigger"]}
    ha_block, ft_block = _fmt_cats(tax["harm_action"]), _fmt_cats(tax["failure_trigger"])

    benign = load_benign()
    results = json.load(open(ASSIGN_PATH)) if os.path.exists(ASSIGN_PATH) else {}
    n = 0
    for t, meta in benign.items():
        if t in results:
            continue
        prompt = ASSIGN_TMPL.format(task=t, desc=meta["desc"], checkpoint=meta["checkpoint"],
                                    harm_action=ha_block, failure_trigger=ft_block)
        try:
            r = parse_json(chat(prompt, ASSIGN_SYS))
            ha, ft = r.get("harm_action"), r.get("failure_trigger")
            if ha not in ha_keys:
                print(f"  ! {t}: invalid harm_action '{ha}'", file=sys.stderr)
            if ft not in ft_keys:
                print(f"  ! {t}: invalid failure_trigger '{ft}'", file=sys.stderr)
            results[t] = {"harm_action": ha, "failure_trigger": ft}
            print(f"  {t}: {ha} | {ft}")
        except Exception as e:
            print(f"  ! {t}: {e}", file=sys.stderr)
            results[t] = {"harm_action": "ERROR", "failure_trigger": "ERROR"}
        n += 1
        if n % 10 == 0:
            json.dump(results, open(ASSIGN_PATH, "w"), indent=2)
            print(f"  ...autosaved ({n} new)")
    json.dump(results, open(ASSIGN_PATH, "w"), indent=2)
    print(f"\nStage 3 done: {len(results)} tasks -> {ASSIGN_PATH}")

    from collections import Counter
    for axis in ("harm_action", "failure_trigger"):
        c = Counter(v[axis] for v in results.values())
        print(f"\n== {axis} distribution ==")
        for k, v in c.most_common():
            print(f"  {v:3d}  {k}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--discover", action="store_true")
    ap.add_argument("--consolidate", action="store_true")
    ap.add_argument("--assign", action="store_true", help="stage 3: label all tasks against the reviewed taxonomy")
    a = ap.parse_args()
    if a.discover:
        stage_discover()
    elif a.consolidate:
        stage_consolidate()
    elif a.assign:
        stage_assign()
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
