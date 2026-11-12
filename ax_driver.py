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
  "mode":        "optimize",
  "seed":        1234,
  "sobol_trials": 4,
  "parameters": [
    {"name":"lr",    "ax":"range",  "value_type":"float", "bounds":[1e-5,1.0], "log_scale":true},
    {"name":"batch", "ax":"choice", "value_type":"int",   "values":[16,32,64], "ordered":true},
    {"name":"opt",   "ax":"choice", "value_type":"str",   "values":["sgd","adam"], "ordered":false}
  ]
}

Only varying parameters (range/choice) appear in the spec. Fixed command
arguments never reach the driver: knit keeps them in the command template and
splices them back when it reconstructs a trial, so the driver models only the
dimensions that vary.

"mode" selects the generation strategy: "optimize" (the default) chases the
objective; "model" fits a surrogate by active learning (qNIPV) and ignores the
objective's sense. On resume the strategy is restored from the saved state, so
the mode marker is only read at init.

The driver targets the modern Ax API (the ``ax.api.Client`` class). The legacy
``AxClient`` service API, which this driver used before, is removed in
ax-platform 1.4.0.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Ax import — fail fast with a JSON error if ax-platform is not installed
# ---------------------------------------------------------------------------

def _import_ax() -> Tuple[Any, Any, Any]:
    try:
        from ax.api.client import Client
        from ax.api.configs import RangeParameterConfig, ChoiceParameterConfig
    except ImportError as exc:
        _emit({"error": f"ax-platform not available: {exc}"})
        sys.exit(1)
    _register_active_learning_acqf()
    return Client, RangeParameterConfig, ChoiceParameterConfig


def _register_active_learning_acqf() -> None:
    """Register the active-learning acquisition function with Ax's JSON storage.

    A model campaign uses a custom generation strategy whose BoTorch node sets
    qNegIntegratedPosteriorVariance as the acquisition class. Ax can only
    serialize an acquisition class it knows, so save/resume of a model campaign
    fails unless the class is in the registry. The registry dicts are the
    sanctioned extension point for this.
    """
    from botorch.acquisition.active_learning import qNegIntegratedPosteriorVariance
    from ax.storage.botorch_modular_registry import (
        ACQUISITION_FUNCTION_REGISTRY,
        REVERSE_ACQUISITION_FUNCTION_REGISTRY,
    )
    key = qNegIntegratedPosteriorVariance.__name__
    ACQUISITION_FUNCTION_REGISTRY.setdefault(qNegIntegratedPosteriorVariance, key)
    REVERSE_ACQUISITION_FUNCTION_REGISTRY.setdefault(key, qNegIntegratedPosteriorVariance)


# Default number of Sobol initialization trials for a model campaign when the
# spec does not set one. BoTorch needs at least a few points to fit a surrogate.
_DEFAULT_MODEL_SOBOL_TRIALS = 5


def _build_model_generation_strategy(seed: Optional[int], sobol_trials: int) -> Any:
    """Build the active-learning generation strategy: a Sobol initialization node
    followed by a BoTorch node whose acquisition function is
    qNegIntegratedPosteriorVariance (qNIPV).

    qNIPV proposes points that reduce the surrogate's posterior variance over the
    whole space (pure exploration), rather than chasing an optimum. The MC points
    qNIPV integrates over are drawn by BoTorch's input constructor from the
    model's transformed-space bounds, so no mc_points are supplied here.
    """
    from ax.generation_strategy.generation_strategy import GenerationStrategy
    from ax.generation_strategy.generation_node import GenerationNode
    from ax.generation_strategy.generator_spec import GeneratorSpec
    from ax.generation_strategy.transition_criterion import MinTrials
    from ax.adapter.registry import Generators
    from botorch.acquisition.active_learning import qNegIntegratedPosteriorVariance

    sobol = GenerationNode(
        name="Sobol",
        generator_specs=[GeneratorSpec(
            generator_enum=Generators.SOBOL,
            generator_kwargs={"seed": seed},
        )],
        transition_criteria=[MinTrials(
            threshold=sobol_trials, transition_to="ActiveLearning",
        )],
    )
    active = GenerationNode(
        name="ActiveLearning",
        generator_specs=[GeneratorSpec(
            generator_enum=Generators.BOTORCH_MODULAR,
            generator_kwargs={"botorch_acqf_class": qNegIntegratedPosteriorVariance},
        )],
    )
    return GenerationStrategy(name="active-learning", nodes=[sobol, active])


def _emit(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


# These statuses count against the trial budget and mark a trial as observed.
_TERMINAL_STATUSES = frozenset({"COMPLETED", "FAILED"})
# These statuses mark a trial still in flight: a resumed campaign abandons them.
_INFLIGHT_STATUSES = frozenset({"RUNNING", "CANDIDATE", "STAGED"})
# Columns in Client.summarize() that are not search parameters.
_NON_PARAM_COLUMNS = frozenset(
    {"trial_index", "arm_name", "trial_status", "generation_node"}
)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

class AxDriver:
    def __init__(self) -> None:
        self._Client, self._RangeCfg, self._ChoiceCfg = _import_ax()
        self._client: Any = None
        self._obj_name: str = ""
        self._minimize: bool = True
        self._state_path: str = ""
        # Completed observations tracked locally so best() does not rely on
        # version-specific Ax model introspection APIs.
        self._observations: Dict[int, Tuple[dict, float]] = {}
        # Parameters of the trials this process asked, so tell() can record an
        # observation without reading them back out of Ax.
        self._trial_params: Dict[int, dict] = {}

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    def _send(self, msg: dict) -> None:
        _emit(msg)

    def _parameters(self, spec_params: List[dict]) -> List[Any]:
        """Convert knit search-space parameter descriptors to Ax parameter
        config objects. Only range and choice parameters vary, so only those
        two kinds are converted; any other kind is skipped."""
        out: List[Any] = []
        for p in spec_params:
            kind = p["ax"]
            if kind == "range":
                vtype = p["value_type"]
                ptype = "int" if vtype == "int" else "float"
                scaling = "log" if bool(p.get("log_scale", False)) else None
                out.append(self._RangeCfg(
                    name=p["name"],
                    bounds=tuple(p["bounds"]),
                    parameter_type=ptype,
                    scaling=scaling,
                ))
            elif kind == "choice":
                vtype = p["value_type"]
                values = p["values"]
                if vtype == "int":
                    values = [int(v) for v in values]
                elif vtype == "float":
                    values = [float(v) for v in values]
                else:
                    values = [str(v) for v in values]
                out.append(self._ChoiceCfg(
                    name=p["name"],
                    values=values,
                    parameter_type=vtype,
                    is_ordered=bool(p.get("ordered", False)),
                ))
        return out

    def _summary_rows(self) -> List[dict]:
        """Return Client.summarize() as a list of plain dict rows (empty on any
        error, e.g. before an experiment exists)."""
        try:
            return self._client.summarize().to_dict(orient="records")
        except Exception:
            return []

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
        n = 0
        for row in self._summary_rows():
            if str(row.get("trial_status", "")).upper() in _TERMINAL_STATUSES:
                n += 1
        return n

    def _abandon_stale_trials(self) -> int:
        """Abandon any non-terminal trial (RUNNING/CANDIDATE) left behind by a
        killed campaign, so a resumed campaign does not treat them as still in
        flight and Ax re-proposes fresh trials for the remaining budget. Returns
        the number abandoned. Best-effort: a trial that cannot be transitioned is
        skipped.
        """
        n = 0
        for row in self._summary_rows():
            if str(row.get("trial_status", "")).upper() not in _INFLIGHT_STATUSES:
                continue
            try:
                self._client.mark_trial_abandoned(trial_index=int(row["trial_index"]))
                n += 1
            except Exception:
                pass
        return n

    def _rebuild_observations(self) -> None:
        """Repopulate _observations from a freshly loaded experiment."""
        self._observations = {}
        non_params = _NON_PARAM_COLUMNS | {self._obj_name}
        for row in self._summary_rows():
            if str(row.get("trial_status", "")).upper() != "COMPLETED":
                continue
            obj = row.get(self._obj_name)
            if obj is None:
                continue
            try:
                obj_val = float(obj)
            except (TypeError, ValueError):
                continue
            # A NaN objective (never fetched) is not an observation.
            if obj_val != obj_val:  # noqa: PLR0124 — NaN check
                continue
            params = {k: v for k, v in row.items() if k not in non_params}
            self._observations[int(row["trial_index"])] = (params, obj_val)

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

        mode = spec.get("mode", "optimize")

        self._client = self._Client()
        self._client.configure_experiment(
            name="knit_ax",
            parameters=self._parameters(spec.get("parameters", [])),
        )
        # The objective is declared in both modes. In optimize mode its sense
        # drives the search (a leading "-" minimizes); in model mode the sense is
        # ignored (qNIPV explores the whole space), but the metric is still the
        # one the surrogate models.
        self._client.configure_optimization(
            objective=f"-{self._obj_name}" if self._minimize else self._obj_name
        )
        if mode == "model":
            n_sobol = int(sobol_trials) if sobol_trials is not None \
                else _DEFAULT_MODEL_SOBOL_TRIALS
            gs = _build_model_generation_strategy(
                int(seed) if seed is not None else None, n_sobol,
            )
            self._client.set_generation_strategy(generation_strategy=gs)
        else:
            gs_kwargs: dict = {}
            if seed is not None:
                gs_kwargs["initialization_random_seed"] = int(seed)
            if sobol_trials is not None:
                gs_kwargs["initialization_budget"] = int(sobol_trials)
            self._client.configure_generation_strategy(**gs_kwargs)

        self._observations = {}
        self._trial_params = {}
        self._send({"status": "ok", "n_trials": 0})

    def cmd_resume(self, req: dict) -> None:
        path = req["path"]
        self._state_path = req.get("state_path", path)
        self._client = self._Client.load_from_json_file(path)
        # Recover the objective name and sense from the persisted experiment.
        obj = self._client._experiment.optimization_config.objective
        self._obj_name = obj.metric_names[0]
        self._minimize = bool(obj.minimize)
        self._rebuild_observations()
        self._abandon_stale_trials()
        self._send({"status": "ok", "n_trials": self._n_trials()})

    def cmd_ask(self, req: dict) -> None:
        n = int(req.get("n", 1))
        trials_dict = self._client.get_next_trials(max_trials=n)
        trials = []
        for idx, params in trials_dict.items():
            params = dict(params)
            self._trial_params[int(idx)] = params
            trials.append({"index": int(idx), "params": params})
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
            self._observations[idx] = (self._trial_params.get(idx, {}), obj_val)
        else:
            self._client.mark_trial_failed(trial_index=idx)
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
