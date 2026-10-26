#!/usr/bin/env python3
"""
ax_driver.py — generic Ax coprocess for knit-ax.

Protocol: one JSON object per line — one request on stdin, one response on
stdout.  The driver knows only Ax; it has no dependency on knit.

Commands
--------
init     {"cmd":"init",   "spec":<search-space JSON>, "state_path":<path>}
resume   {"cmd":"resume", "path":<state.json>,         "state_path":<path>}
ask      {"cmd":"ask",    "n":<int>}
tell     {"cmd":"tell",   "index":<int>, "objective":<float>, "status":"ok"|"penalized"|"failed"}
best     {"cmd":"best"}
save     {"cmd":"save",   "path":<path>}
shutdown {"cmd":"shutdown"}

Search-space JSON schema (produced by Bash; passed verbatim to init)
----------------------------------------------------------------------
{
  "objective":  {"name": "val_loss", "minimize": true},
  "seed":        1234,
  "sobol_trials": 4,
  "parameters": [
    {"name":"lr",    "ax":"range",  "value_type":"float", "bounds":[1e-5,1.0], "log_scale":true},
    {"name":"batch", "ax":"choice", "value_type":"int",   "values":[16,32,64], "ordered":true},
    {"name":"opt",   "ax":"choice", "value_type":"str",   "values":["sgd","adam"], "ordered":false},
    {"name":"epoch", "ax":"fixed",  "value":20}
  ]
}
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Ax import — fail fast with a JSON error if ax-platform is not installed
# ---------------------------------------------------------------------------

def _import_ax() -> Tuple[Any, Any]:
    try:
        from ax.service.ax_client import AxClient
        from ax.service.utils.instantiation import ObjectiveProperties
        return AxClient, ObjectiveProperties
    except ImportError as exc:
        _emit({"error": f"ax-platform not available: {exc}"})
        sys.exit(1)


def _emit(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Parameter conversion
# ---------------------------------------------------------------------------

def _ax_parameters(spec_params: List[dict]) -> List[dict]:
    """Convert knit search-space parameter descriptors to Ax parameter dicts."""
    out: List[dict] = []
    for p in spec_params:
        kind = p["ax"]
        if kind == "range":
            out.append({
                "name": p["name"],
                "type": "range",
                "bounds": p["bounds"],
                "value_type": p["value_type"],
                "log_scale": bool(p.get("log_scale", False)),
            })
        elif kind == "choice":
            out.append({
                "name": p["name"],
                "type": "choice",
                "values": p["values"],
                "value_type": p["value_type"],
                "is_ordered": bool(p.get("ordered", False)),
            })
        elif kind == "fixed":
            out.append({
                "name": p["name"],
                "type": "fixed",
                "value": p["value"],
            })
    return out


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

class AxDriver:
    def __init__(self) -> None:
        self._AxClient, self._ObjectiveProperties = _import_ax()
        self._client: Any = None
        self._obj_name: str = ""
        self._minimize: bool = True
        self._state_path: str = ""
        # Completed observations tracked locally so best() does not rely on
        # version-specific Ax model introspection APIs.
        self._observations: Dict[int, Tuple[dict, float]] = {}

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def _send(self, msg: dict) -> None:
        _emit(msg)

    def _n_trials(self) -> int:
        """Trials that have consumed budget: the terminal evaluated ones
        (completed or failed).

        This is the count the knit loop measures its budget against. RUNNING or
        CANDIDATE trials do NOT count: a campaign killed with trials in flight
        (possible under --parallel > 1) persists them as RUNNING, and on resume
        they are abandoned (see _abandon_stale_trials) and must be re-launched.
        Counting them would silently shrink the delivered budget and lose those
        evaluations.
        """
        try:
            n = 0
            for trial in self._client.experiment.trials.values():
                status = trial.status
                if status.is_completed or status.is_failed:
                    n += 1
            return n
        except Exception:
            return 0

    def _abandon_stale_trials(self) -> int:
        """Abandon any non-terminal trial (RUNNING/CANDIDATE) left behind by a
        killed campaign, so a resumed campaign does not treat them as still in
        flight and Ax re-proposes fresh trials for the remaining budget. Returns
        the number abandoned. Best-effort: a trial that cannot be transitioned is
        skipped.
        """
        n = 0
        try:
            for trial in self._client.experiment.trials.values():
                status = trial.status
                if status.is_completed or status.is_failed or status.is_abandoned:
                    continue
                try:
                    trial.mark_abandoned(reason="resumed after interruption")
                    n += 1
                except Exception:
                    pass
        except Exception:
            pass
        return n

    def _rebuild_observations(self) -> None:
        """Repopulate _observations from a freshly loaded experiment."""
        self._observations = {}
        try:
            data = self._client.experiment.fetch_data()
            df = data.df
            obj_rows = df[df["metric_name"] == self._obj_name]
            for _, row in obj_rows.iterrows():
                t_idx = int(row["trial_index"])
                trial = self._client.experiment.trials.get(t_idx)
                if trial is None:
                    continue
                arm = getattr(trial, "arm", None)
                if arm is None:
                    continue
                self._observations[t_idx] = (
                    dict(arm.parameters),
                    float(row["mean"]),
                )
        except Exception:
            pass

    # ------------------------------------------------------------------
    # commands
    # ------------------------------------------------------------------

    def cmd_init(self, req: dict) -> None:
        spec = req["spec"]
        obj = spec["objective"]
        self._obj_name = obj["name"]
        self._minimize = bool(obj.get("minimize", True))
        self._state_path = req.get("state_path", "")
        seed = spec.get("seed")
        sobol_trials = spec.get("sobol_trials")

        self._client = self._AxClient(
            random_seed=seed,
            verbose_logging=False,
        )
        gen_kwargs: dict = {}
        if sobol_trials is not None:
            gen_kwargs["num_initialization_trials"] = int(sobol_trials)

        self._client.create_experiment(
            name="knit_ax",
            parameters=_ax_parameters(spec.get("parameters", [])),
            objectives={
                self._obj_name: self._ObjectiveProperties(minimize=self._minimize)
            },
            choose_generation_strategy_kwargs=gen_kwargs if gen_kwargs else None,
        )
        self._observations = {}
        self._send({"status": "ok", "n_trials": 0})

    def cmd_resume(self, req: dict) -> None:
        path = req["path"]
        self._state_path = req.get("state_path", path)
        self._client = self._AxClient.load_from_json_file(path)
        # Recover the objective name and sense from the persisted experiment.
        # Use AxClient.objective_name (stable public API) for the name:
        # opt_cfg.objective.metric does not exist in every Ax version (1.x's
        # Objective exposes metric_names, not metric), so reaching for .metric
        # raised "'Objective' object has no attribute 'metric'" and broke resume.
        self._obj_name = self._client.objective_name
        opt_cfg = self._client.experiment.optimization_config
        if opt_cfg is not None:
            self._minimize = bool(opt_cfg.objective.minimize)
        self._rebuild_observations()
        self._abandon_stale_trials()
        self._send({"status": "ok", "n_trials": self._n_trials()})

    def cmd_ask(self, req: dict) -> None:
        n = int(req.get("n", 1))
        # get_next_trials returns (Dict[index, params], optimization_complete)
        # in some versions, or just Dict[index, params] in others.
        raw = self._client.get_next_trials(max_trials=n)
        if isinstance(raw, tuple):
            trials_dict, _ = raw
        else:
            trials_dict = raw
        trials = [
            {"index": idx, "params": params}
            for idx, params in trials_dict.items()
        ]
        self._send({"trials": trials})

    def cmd_tell(self, req: dict) -> None:
        idx = int(req["index"])
        status = req.get("status", "ok")
        if status in ("ok", "penalized"):
            obj_val = float(req["objective"])
            self._client.complete_trial(
                trial_index=idx,
                raw_data={self._obj_name: obj_val},
            )
            trial = self._client.experiment.trials.get(idx)
            params: dict = {}
            if trial is not None:
                arm = getattr(trial, "arm", None)
                if arm is not None:
                    params = dict(arm.parameters)
            self._observations[idx] = (params, obj_val)
        else:
            self._client.log_trial_failure(trial_index=idx)
        # Persist after every tell so a killed coprocess can be resumed.
        if self._state_path:
            Path(self._state_path).parent.mkdir(parents=True, exist_ok=True)
            self._client.save_to_json_file(self._state_path)
        self._send({"status": "ok"})

    def cmd_best(self, _req: dict) -> None:
        if not self._observations:
            self._send({"best": None, "n_trials": self._n_trials()})
            return
        best_idx = min(
            self._observations,
            key=lambda i: (
                self._observations[i][1]
                if self._minimize
                else -self._observations[i][1]
            ),
        )
        params, obj_val = self._observations[best_idx]
        self._send({
            "best": {
                "index": best_idx,
                "params": params,
                "objective": obj_val,
            },
            "n_trials": self._n_trials(),
        })

    def cmd_save(self, req: dict) -> None:
        path = req["path"]
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._client.save_to_json_file(path)
        self._send({"status": "ok"})

    def cmd_shutdown(self, _req: dict) -> None:
        self._send({"status": "ok"})
        sys.exit(0)

    # ------------------------------------------------------------------
    # main loop
    # ------------------------------------------------------------------

    def run(self) -> None:
        handlers = {
            "init": self.cmd_init,
            "resume": self.cmd_resume,
            "ask": self.cmd_ask,
            "tell": self.cmd_tell,
            "best": self.cmd_best,
            "save": self.cmd_save,
            "shutdown": self.cmd_shutdown,
        }
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError as exc:
                self._send({"error": f"invalid JSON: {exc}"})
                continue
            cmd = req.get("cmd")
            handler = handlers.get(cmd)
            if handler is None:
                self._send({"error": f"unknown command: {cmd!r}"})
                continue
            try:
                handler(req)
            except Exception as exc:
                self._send({"error": f"{cmd} failed: {exc}"})


def main() -> None:
    AxDriver().run()


if __name__ == "__main__":
    main()
