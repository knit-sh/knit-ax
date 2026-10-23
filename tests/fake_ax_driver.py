#!/usr/bin/env python3
"""
tests/fake_ax_driver.py — a deterministic stand-in for ax_driver.py.

Speaks the exact newline-delimited JSON protocol that ax_driver.py does
(init / resume / ask / tell / best / shutdown), but proposes points from a
fixed grid instead of fitting a real Ax model. This lets the plugin's
end-to-end bats test drive the whole prepare -> optimize -> ask/collect/observe
-> best wiring hermetically: no Ax, no PyTorch, no network, and a known optimum
the loop must land on within the budget.

The grid for a range parameter is the five evenly spaced points
    lo, lo+d, lo+2d, lo+3d, hi      (d = (hi-lo)/4)
so the midpoint (lo+hi)/2 is the third proposal (trial index 2 within a run).
A surrogate objective peaked at that midpoint therefore has its optimum in the
grid, and "best" returns it once the budget covers index 2.

State is persisted to the init/resume state_path after init and after every
tell, so a run truncated after K trials resumes from exactly K (budget math in
"ax optimize" reads the reported n_trials).
"""
from __future__ import annotations

import json
import sys
from typing import Any


def _grid_value(param: dict, idx: int) -> Any:
    """Deterministic proposal for one parameter at trial index `idx`."""
    kind = param.get("ax")
    if kind == "range":
        lo, hi = param["bounds"]
        step = (hi - lo) / 4.0
        value = lo + (idx % 5) * step
        if param.get("value_type") == "int":
            return int(round(value))
        return value
    if kind == "choice":
        values = param["values"]
        return values[idx % len(values)]
    # A fixed parameter carries one value through every trial.
    return param.get("value")


class FakeDriver:
    def __init__(self) -> None:
        self.spec: dict = {}
        self.state_path: str = ""
        self.next_idx: int = 0
        # index (as str) -> {"params": {...}, "objective": float|None}
        self.trials: dict[str, dict] = {}

    # ---- persistence ----

    def _save(self) -> None:
        if not self.state_path:
            return
        with open(self.state_path, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "spec": self.spec,
                    "next_idx": self.next_idx,
                    "trials": self.trials,
                },
                handle,
            )

    def _load(self, path: str) -> None:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        self.spec = data.get("spec", {})
        self.next_idx = data.get("next_idx", 0)
        self.trials = data.get("trials", {})
        self.state_path = path

    def _n_told(self) -> int:
        return sum(1 for t in self.trials.values() if t.get("objective") is not None)

    # ---- commands ----

    def init(self, req: dict) -> dict:
        self.spec = req.get("spec", {})
        self.state_path = req.get("state_path", "")
        self.next_idx = 0
        self.trials = {}
        self._save()
        return {"status": "ok", "n_trials": 0}

    def resume(self, req: dict) -> dict:
        self._load(req.get("state_path") or req.get("path", ""))
        return {"status": "ok", "n_trials": self._n_told()}

    def ask(self, req: dict) -> dict:
        n = int(req.get("n", 1))
        params_spec = self.spec.get("parameters", [])
        grid_len = 5
        trials = []
        for _ in range(n):
            idx = self.next_idx
            if idx >= grid_len:
                break  # grid exhausted -> no more proposals
            params = {p["name"]: _grid_value(p, idx) for p in params_spec}
            self.trials[str(idx)] = {"params": params, "objective": None}
            self.next_idx += 1
            trials.append({"index": idx, "params": params})
        return {"trials": trials}

    def tell(self, req: dict) -> dict:
        idx = str(req["index"])
        entry = self.trials.setdefault(idx, {"params": {}, "objective": None})
        if req.get("status") == "failed":
            entry["objective"] = None
        else:
            entry["objective"] = req.get("objective")
        self._save()
        return {"status": "ok"}

    def best(self, _req: dict) -> dict:
        minimize = self.spec.get("objective", {}).get("minimize", True)
        best_idx = None
        best_obj = None
        for idx, entry in self.trials.items():
            obj = entry.get("objective")
            if obj is None:
                continue
            if best_obj is None or (obj < best_obj if minimize else obj > best_obj):
                best_obj = obj
                best_idx = idx
        n_trials = self._n_told()
        if best_idx is None:
            return {"best": None, "n_trials": n_trials}
        return {
            "best": {
                "index": int(best_idx),
                "params": self.trials[best_idx]["params"],
                "objective": best_obj,
            },
            "n_trials": n_trials,
        }


def main() -> int:
    driver = FakeDriver()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        cmd = req.get("cmd")
        if cmd == "shutdown":
            break
        if cmd == "init":
            resp = driver.init(req)
        elif cmd == "resume":
            resp = driver.resume(req)
        elif cmd == "ask":
            resp = driver.ask(req)
        elif cmd == "tell":
            resp = driver.tell(req)
        elif cmd == "best":
            resp = driver.best(req)
        else:
            resp = {"error": f"unknown command: {cmd}"}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
