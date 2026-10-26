#!/usr/bin/env python3
"""
tests/test_ax_protocol.py — protocol test for ax_driver.py.

Drives ax_driver.py as a subprocess over newline-delimited JSON.
Does not import Ax itself; the subprocess handles that.

Run after activating the _ax-driver venv (or any env with ax-platform):
    python tests/test_ax_protocol.py

Skips all tests when ax-platform is not available in the subprocess.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Optional

DRIVER = Path(__file__).resolve().parent.parent / "ax_driver.py"

# 1-D search space: minimize y = (x - 2)^2, optimum at x=2, y=0.
SPEC_1D = {
    "objective": {"name": "y", "minimize": True},
    "seed": 42,
    "sobol_trials": 3,
    "parameters": [
        {
            "name": "x",
            "ax": "range",
            "value_type": "float",
            "bounds": [-5.0, 5.0],
        }
    ],
}


def _objective(params: dict) -> float:
    return (params["x"] - 2.0) ** 2


# ---------------------------------------------------------------------------
# Subprocess wrapper
# ---------------------------------------------------------------------------

class DriverProcess:
    """Context manager that wraps a running ax_driver.py subprocess."""

    def __init__(self) -> None:
        self.proc: Optional[subprocess.Popen[str]] = None

    def __enter__(self) -> "DriverProcess":
        self.proc = subprocess.Popen(
            [sys.executable, str(DRIVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        return self

    def __exit__(self, *_: Any) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.send({"cmd": "shutdown"})
            except (BrokenPipeError, EOFError):
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def send(self, msg: dict) -> dict:
        assert self.proc is not None
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        raw = self.proc.stdout.readline()
        if not raw:
            raise EOFError("driver closed stdout unexpectedly")
        return json.loads(raw)

    def init(self, state_path: str = "") -> dict:
        req: dict = {"cmd": "init", "spec": SPEC_1D}
        if state_path:
            req["state_path"] = state_path
        return self.send(req)


# ---------------------------------------------------------------------------
# Availability check
# ---------------------------------------------------------------------------

def _ax_unavailable_reason() -> Optional[str]:
    """Return a reason string if ax-platform is not available, else None."""
    proc = subprocess.Popen(
        [sys.executable, str(DRIVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    # Close stdin; the driver exits when stdin closes (loop ends).
    out, _ = proc.communicate(input="", timeout=15)
    if not out.strip():
        return None  # driver started and exited cleanly (stdin EOF)
    first = out.strip().splitlines()[0]
    resp = json.loads(first)
    if "error" in resp and "ax-platform" in resp["error"]:
        return resp["error"]
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestAxProtocol(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        reason = _ax_unavailable_reason()
        if reason:
            raise unittest.SkipTest(f"ax-platform not available: {reason}")
        cls.tmpdir = tempfile.mkdtemp(prefix="knit_ax_test_")

    @classmethod
    def tearDownClass(cls) -> None:
        import shutil
        shutil.rmtree(cls.tmpdir, ignore_errors=True)

    # ---- basic protocol ----

    def test_init_ok(self) -> None:
        with DriverProcess() as dp:
            resp = dp.init()
            self.assertEqual(resp.get("status"), "ok")

    def test_ask_returns_trials(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            resp = dp.send({"cmd": "ask", "n": 2})
            self.assertIn("trials", resp, resp)
            self.assertEqual(len(resp["trials"]), 2)
            for trial in resp["trials"]:
                self.assertIn("index", trial)
                self.assertIn("params", trial)
                self.assertIn("x", trial["params"])

    def test_tell_ok(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            resp = dp.send({
                "cmd": "tell",
                "index": trial["index"],
                "objective": _objective(trial["params"]),
                "status": "ok",
            })
            self.assertEqual(resp.get("status"), "ok", resp)

    def test_tell_failed(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            resp = dp.send({
                "cmd": "tell",
                "index": trial["index"],
                "status": "failed",
            })
            self.assertEqual(resp.get("status"), "ok", resp)

    def test_tell_penalized(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            resp = dp.send({
                "cmd": "tell",
                "index": trial["index"],
                "objective": 999.0,
                "status": "penalized",
            })
            self.assertEqual(resp.get("status"), "ok", resp)

    def test_best_none_before_observations(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            resp = dp.send({"cmd": "best"})
            self.assertIn("best", resp)
            self.assertIsNone(resp["best"])

    def test_best_returns_index_params_objective(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            y = _objective(trial["params"])
            dp.send({"cmd": "tell", "index": trial["index"],
                      "objective": y, "status": "ok"})
            resp = dp.send({"cmd": "best"})
            self.assertIsNotNone(resp.get("best"))
            best = resp["best"]
            self.assertIn("index", best)
            self.assertIn("params", best)
            self.assertIn("objective", best)
            self.assertAlmostEqual(best["objective"], y)

    def test_best_converges(self) -> None:
        """After 12 sequential trials, best_objective should be < 1 (near x=2)."""
        with DriverProcess() as dp:
            dp.init()
            for _ in range(12):
                ask = dp.send({"cmd": "ask", "n": 1})
                trial = ask["trials"][0]
                dp.send({
                    "cmd": "tell",
                    "index": trial["index"],
                    "objective": _objective(trial["params"]),
                    "status": "ok",
                })
            resp = dp.send({"cmd": "best"})
            self.assertIsNotNone(resp.get("best"))
            self.assertLess(
                resp["best"]["objective"], 1.0,
                f"expected convergence toward x=2 within 12 trials, got {resp['best']}",
            )

    # ---- save / resume ----

    def test_save_creates_file(self) -> None:
        state = os.path.join(self.tmpdir, "state_save.json")
        with DriverProcess() as dp:
            dp.init()
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            dp.send({"cmd": "tell", "index": trial["index"],
                      "objective": _objective(trial["params"]), "status": "ok"})
            resp = dp.send({"cmd": "save", "path": state})
            self.assertEqual(resp.get("status"), "ok", resp)
        self.assertTrue(os.path.isfile(state))

    def test_auto_save_after_tell(self) -> None:
        """state_path in init → state file written after the first tell."""
        state = os.path.join(self.tmpdir, "state_auto.json")
        with DriverProcess() as dp:
            dp.init(state_path=state)
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            dp.send({"cmd": "tell", "index": trial["index"],
                      "objective": _objective(trial["params"]), "status": "ok"})
        self.assertTrue(
            os.path.isfile(state),
            "state file should be written after tell when state_path is set",
        )

    def test_resume_continues_from_saved_state(self) -> None:
        """
        Run 3 trials, save, resume in a new process, run 3 more.
        All 6 trial indices must be distinct (resume continues, not restarts).
        """
        state = os.path.join(self.tmpdir, "state_resume.json")
        seen: list[int] = []

        with DriverProcess() as dp:
            dp.init(state_path=state)
            for _ in range(3):
                ask = dp.send({"cmd": "ask", "n": 1})
                trial = ask["trials"][0]
                seen.append(trial["index"])
                dp.send({"cmd": "tell", "index": trial["index"],
                          "objective": _objective(trial["params"]), "status": "ok"})
            dp.send({"cmd": "save", "path": state})

        with DriverProcess() as dp:
            resp = dp.send({"cmd": "resume", "path": state, "state_path": state})
            self.assertEqual(resp.get("status"), "ok", resp)
            for _ in range(3):
                ask = dp.send({"cmd": "ask", "n": 1})
                trial = ask["trials"][0]
                seen.append(trial["index"])
                dp.send({"cmd": "tell", "index": trial["index"],
                          "objective": _objective(trial["params"]), "status": "ok"})
            resp = dp.send({"cmd": "best"})
            self.assertIsNotNone(resp.get("best"))

        self.assertEqual(
            len(seen), len(set(seen)),
            f"duplicate trial indices after resume: {seen}",
        )

    def test_resume_best_spans_both_sessions(self) -> None:
        """best() after resume covers all observed trials, not just the new ones."""
        state = os.path.join(self.tmpdir, "state_best_span.json")
        # First session: evaluate near x=4 (y≈4) to set a suboptimal best.
        with DriverProcess() as dp:
            dp.init(state_path=state)
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            # Override the actual value with a known one.
            dp.send({"cmd": "tell", "index": trial["index"],
                      "objective": 4.0, "status": "ok"})
            dp.send({"cmd": "save", "path": state})

        # Second session: evaluate at x≈2 (y≈0).
        with DriverProcess() as dp:
            dp.send({"cmd": "resume", "path": state, "state_path": state})
            ask = dp.send({"cmd": "ask", "n": 1})
            trial = ask["trials"][0]
            dp.send({"cmd": "tell", "index": trial["index"],
                      "objective": 0.01, "status": "ok"})
            resp = dp.send({"cmd": "best"})
            self.assertIsNotNone(resp.get("best"))
            # Best should be the 0.01 trial, not 4.0.
            self.assertLess(resp["best"]["objective"], 1.0, resp)

    def test_resume_ignores_inflight_trials_in_budget(self) -> None:
        """A trial asked but not told (in flight when a parallel campaign is
        killed) is persisted RUNNING. On resume it must NOT count against budget:
        n_trials reports only the completed/failed trial, and the in-flight one is
        abandoned so the next ask yields a fresh, distinct index.
        """
        state = os.path.join(self.tmpdir, "state_inflight.json")
        completed_idx = None
        inflight_idx = None

        # First session: ask two (parallel), complete one, leave one in flight.
        with DriverProcess() as dp:
            dp.init(state_path=state)
            ask = dp.send({"cmd": "ask", "n": 2})
            self.assertEqual(len(ask["trials"]), 2, ask)
            t0, t1 = ask["trials"]
            completed_idx = t0["index"]
            inflight_idx = t1["index"]
            dp.send({"cmd": "tell", "index": completed_idx,
                      "objective": _objective(t0["params"]), "status": "ok"})
            # t1 is deliberately never told; the auto-save after the tell above
            # persists it as a RUNNING trial.

        # Second session: resume and check budget accounting.
        with DriverProcess() as dp:
            resp = dp.send({"cmd": "resume", "path": state, "state_path": state})
            self.assertEqual(resp.get("status"), "ok", resp)
            self.assertEqual(
                resp.get("n_trials"), 1,
                f"resume must count only the completed trial, not the in-flight "
                f"one: {resp}",
            )
            ask = dp.send({"cmd": "ask", "n": 1})
            new_idx = ask["trials"][0]["index"]
            self.assertNotIn(
                new_idx, (completed_idx, inflight_idx),
                "resumed ask must propose a fresh trial, not reuse an index",
            )

    # ---- error handling ----

    def test_unknown_command_returns_error(self) -> None:
        with DriverProcess() as dp:
            resp = dp.send({"cmd": "bogus_cmd"})
            self.assertIn("error", resp)

    def test_invalid_json_returns_error(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(DRIVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert proc.stdin is not None
        assert proc.stdout is not None
        proc.stdin.write("not json\n")
        proc.stdin.flush()
        raw = proc.stdout.readline()
        resp = json.loads(raw)
        self.assertIn("error", resp)
        proc.stdin.write('{"cmd":"shutdown"}\n')
        proc.stdin.flush()
        proc.wait(timeout=5)
        self.assertEqual(proc.returncode, 0)

    def test_shutdown_exits_zero(self) -> None:
        with DriverProcess() as dp:
            dp.init()
            resp = dp.send({"cmd": "shutdown"})
            self.assertEqual(resp.get("status"), "ok")
            assert dp.proc is not None
            dp.proc.wait(timeout=2)
            self.assertEqual(dp.proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
