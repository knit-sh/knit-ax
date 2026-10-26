#!/usr/bin/env bats
#
# End-to-end campaign test against a deterministic surrogate. It drives the whole
# plugin control flow for real — "ax prepare" writes and records the campaign,
# "ax optimize" reads it back, computes the remaining budget, runs the shared
# search-core loop, and the loop's ask -> launch -> collect -> observe -> best
# cycle records the optimum on the campaign row and on disk. Only the two genuine
# externals are replaced: the Ax brain (a deterministic grid proposer,
# tests/fake_ax_driver.py, so no Ax / PyTorch / network is needed) and the
# scheduler (knit_search_launch is stubbed to evaluate a closed-form surrogate and
# seed the job + objective rows the loop reads). Real Ax convergence is proven
# separately by tests/test_ax_protocol.py.
#
# Surrogate: parameter x over [0, 12], objective MAXIMIZE score = 100 - (x-6)^2,
# so the optimum is x = 6 with score 100. The fake proposer's grid for [0, 12] is
# {0, 3, 6, 9, 12}; the midpoint 6 is the third proposal (trial index 2), so a
# budget that reaches index 2 must land on score 100.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    _KNIT_JQ_EXE="jq"
    _KNIT_PREFIX="${KNIT_AX_TEST_DB_DIR}/.knit"
    CAMPAIGNS="${KNIT_AX_TEST_DB_DIR}/campaigns"
    FAKE_DRIVER="${BATS_TEST_DIRNAME}/fake_ax_driver.py"

    # A submit-mode job with one varying real parameter and a declared objective
    # output. The loop never really launches it (knit_search_launch is stubbed),
    # but prepare needs the registration to resolve the objective and build a spec.
    knit_register "submit__1__train" knit_empty "Surrogate training job."
    knit_with_optional "x:real" "" "x knob" --domain '[0..12]'
    knit_with_table    "train"
    knit_with_output   "score:real" "" "surrogate score"
    knit_done

    # The loop reads job terminal state from "jobs" and the objective from "train";
    # the stubbed launch seeds both. (prepare creates "optimizations" itself.)
    "${_KNIT_SQLITE_EXE}" "${_KNIT_DATABASE}" \
        "CREATE TABLE IF NOT EXISTS jobs (id TEXT, state TEXT);
         CREATE TABLE IF NOT EXISTS train (id TEXT, score REAL);"

    # Count launches in a file, not a variable: bats "run" executes the command
    # in a subshell, so a variable bumped inside the loop would not survive back
    # to the test, but an appended file does.
    __e2e_launch_log="${KNIT_AX_TEST_DB_DIR}/launches"
    : > "${__e2e_launch_log}"

    # Install the surrogate seams AFTER knit_ax_test_load, which sources knit.sh
    # and plugin.sh and would otherwise redefine them with the real versions.
    _install_surrogate_seams
}

# Number of trials the stubbed launch has run so far.
_launch_count() {
    wc -l < "${__e2e_launch_log}" | tr -d ' '
}

teardown() {
    knit_ax_test_db_teardown
}

# ---------- surrogate seams ----------

# Replace the two genuine externals: the Ax brain (a deterministic grid proposer)
# and the scheduler (knit_search_launch). Everything else runs for real.
_install_surrogate_seams() {
    # The _ax-driver venv is never built in the test; return a throwaway prefix.
    _knit_ax_ensure_driver() {
        local -n __ret=$1
        __ret="${KNIT_AX_TEST_DB_DIR}/driver"
        mkdir -p "${__ret}"
    }

    # Launch the deterministic fake driver as the coprocess, mirroring the real
    # start_driver but with python3 and no venv activation.
    _knit_ax_start_driver() {
        coproc AX_DRIVER { exec python3 "${FAKE_DRIVER}"; }
        _KNIT_AX_RPC_OUT="${AX_DRIVER[0]}"
        _KNIT_AX_RPC_IN="${AX_DRIVER[1]}"
        _KNIT_AX_COPROC_PID="${AX_DRIVER_PID}"
    }

    # Stand in for the scheduler: read the proposed x off the reconstructed argv,
    # evaluate the surrogate, and seed the terminal job row + the objective row the
    # loop's collector reads. Returns a fresh child row id by nameref.
    knit_search_launch() {
        local -n __uuid=$1; shift
        local -a argv=( "$@" )
        local xval="" i
        for ((i = 0; i < ${#argv[@]}; i++)); do
            [[ "${argv[i]}" == "--x" ]] && xval="${argv[i + 1]}"
        done
        printf 'x\n' >> "${__e2e_launch_log}"
        local uuid
        uuid="trial-$(_launch_count)"
        __uuid="${uuid}"
        local score
        score="$(_surrogate "${xval}")"
        "${_KNIT_SQLITE_EXE}" "${_KNIT_DATABASE}" \
            "INSERT INTO jobs  (id, state) VALUES ('${uuid}', 'completed');
             INSERT INTO train (id, score) VALUES ('${uuid}', ${score});"
        return 0
    }
}

# The closed-form surrogate: maximize 100 - (x - 6)^2 (optimum x = 6, score 100).
_surrogate() {
    python3 -c "x = float('$1'); print(100.0 - (x - 6.0) ** 2)"
}

# Drive the fake driver to write a genuine K-trial state.json into a campaign's
# directory, simulating a run interrupted after K trials. Driving the real fake
# driver (rather than hand-writing JSON) keeps the persisted format in step with
# it. A single "ax optimize" then resumes from this state. One optimize per test
# keeps exactly one Ax coprocess alive at a time (bash tracks one coproc).
_seed_state() {
    local campaign="$1" k="$2"
    local sp="${CAMPAIGNS}/${campaign}/state.json"
    local spec='{"objective":{"name":"score","minimize":false},"parameters":[{"name":"x","ax":"range","value_type":"float","bounds":[0,12]}]}'
    {
        printf '{"cmd":"init","spec":%s,"state_path":"%s"}\n' "${spec}" "${sp}"
        local i x
        for ((i = 0; i < k; i++)); do
            x=$(( (i % 5) * 3 ))                     # the fake driver's grid for [0,12]
            printf '{"cmd":"ask","n":1}\n'
            printf '{"cmd":"tell","index":%d,"objective":%s,"status":"ok"}\n' \
                "${i}" "$(_surrogate "${x}")"
        done
        printf '{"cmd":"shutdown"}\n'
    } | python3 "${FAKE_DRIVER}" >/dev/null
}

# ---------- full run converges on the known optimum ----------

@test "optimize runs to budget and records the surrogate optimum" {
    knit ax prepare --campaign e2e --objective score --maximize \
        --trials 5 --parallel 1 -- submit -- train --x @sweep
    run knit ax optimize --campaign e2e
    [ "$status" -eq 0 ]

    # Campaign is marked completed on disk and in the row.
    [ "$(cat "${CAMPAIGNS}/e2e/status")" = "completed" ]
    [ -f "${CAMPAIGNS}/e2e/state.json" ]
    [ -f "${CAMPAIGNS}/e2e/result.json" ]

    # The best objective is the surrogate optimum (score 100 at x = 6), and the
    # full budget was launched and recorded.
    local best
    best="$(jq -r '.best.objective' "${CAMPAIGNS}/e2e/result.json")"
    [ "$(printf '%.0f' "${best}")" -eq 100 ]
    [ "$(jq -r '.trials_done' "${CAMPAIGNS}/e2e/result.json")" -eq 5 ]
    [ "$(_launch_count)" -eq 5 ]

    # A completed run leaves a resumable state.json holding every trial.
    [ "$(jq '.trials | length' "${CAMPAIGNS}/e2e/state.json")" -eq 5 ]

    # The optimizations row carries the same best and a resolved best_id.
    local row
    row="$("${_KNIT_SQLITE_EXE}" "${_KNIT_DATABASE}" \
        "SELECT status||'|'||CAST(ROUND(best_objective) AS INT)||'|'||(best_id IS NOT NULL AND best_id<>'') \
         FROM optimizations WHERE id='e2e';")"
    [ "${row}" = "completed|100|1" ]
}

# ---------- a partial run resumes from the persisted state ----------

@test "optimize resumes a partial campaign and reaches the optimum" {
    knit ax prepare --campaign rez --objective score --maximize \
        --trials 5 --parallel 1 -- submit -- train --x @sweep

    # Simulate a run interrupted after two trials (x = 0, x = 3).
    _seed_state rez 2
    [ "$(jq '.trials | length' "${CAMPAIGNS}/rez/state.json")" -eq 2 ]

    # Resuming runs only the remaining three trials (not a fresh five), reaching
    # x = 6 (score 100).
    run knit ax optimize --campaign rez
    [ "$status" -eq 0 ]
    [ "$(_launch_count)" -eq 3 ]
    [ "$(jq -r '.trials_done' "${CAMPAIGNS}/rez/result.json")" -eq 5 ]
    local best
    best="$(jq -r '.best.objective' "${CAMPAIGNS}/rez/result.json")"
    [ "$(printf '%.0f' "${best}")" -eq 100 ]
}

# ---------- already-at-budget optimize is a no-op ----------

@test "optimize is a no-op once the campaign is already at budget" {
    knit ax prepare --campaign full --objective score --maximize \
        --trials 3 --parallel 1 -- submit -- train --x @sweep

    # A state already holding the full budget: optimize should launch nothing.
    _seed_state full 3
    run knit ax optimize --campaign full
    [ "$status" -eq 0 ]
    [ "$(_launch_count)" -eq 0 ]
    [[ "$output" == *"already at budget"* ]]
}

# ---------- a campaign where every trial fails records no best ----------

@test "optimize with all trials failing completes with a null best" {
    knit ax prepare --campaign allfail --objective score --maximize \
        --trials 3 --parallel 1 -- submit -- train --x @sweep

    # Every trial "runs" but yields no objective (NULL score), so collect fails
    # and the loop tells Ax a failure for each — the bad trials never abort the
    # campaign (observe always returns 0).
    knit_search_launch() {
        local -n __uuid=$1; shift
        printf 'x\n' >> "${__e2e_launch_log}"
        local uuid
        uuid="trial-$(_launch_count)"
        __uuid="${uuid}"
        "${_KNIT_SQLITE_EXE}" "${_KNIT_DATABASE}" \
            "INSERT INTO jobs  (id, state) VALUES ('${uuid}', 'completed');
             INSERT INTO train (id, score) VALUES ('${uuid}', NULL);"
        return 0
    }

    run knit ax optimize --campaign allfail
    [ "$status" -eq 0 ]

    # The full budget was attempted and the campaign completed, but with no best.
    [ "$(cat "${CAMPAIGNS}/allfail/status")" = "completed" ]
    [ "$(_launch_count)" -eq 3 ]
    [ "$(jq -r '.best.objective' "${CAMPAIGNS}/allfail/result.json")" = "null" ]

    # "ax list" renders the missing best as an em-dash.
    run knit ax list
    [ "$status" -eq 0 ]
    [[ "$output" == *"allfail"* ]]
    [[ "$output" == *"best=—"* ]]
}

# ---------- a driver that cannot resume fails loudly (never re-runs budget) ----

# A driver stand-in that answers every non-shutdown command with an error, used
# to prove "ax optimize" aborts on a failed resume instead of silently treating
# the campaign as 0 trials done and re-running the whole budget.
_install_error_driver() {
    local errdrv="${KNIT_AX_TEST_DB_DIR}/err_driver.py"
    cat > "${errdrv}" <<'PY'
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if json.loads(line).get("cmd") == "shutdown":
        break
    sys.stdout.write(json.dumps({"error": "simulated resume failure"}) + "\n")
    sys.stdout.flush()
PY
    _knit_ax_start_driver() {
        coproc AX_DRIVER { exec python3 "${KNIT_AX_TEST_DB_DIR}/err_driver.py"; }
        _KNIT_AX_RPC_OUT="${AX_DRIVER[0]}"
        _KNIT_AX_RPC_IN="${AX_DRIVER[1]}"
        _KNIT_AX_COPROC_PID="${AX_DRIVER_PID}"
    }
}

@test "optimize fatals loudly when the driver fails to resume" {
    knit ax prepare --campaign err --objective score --maximize \
        --trials 5 --parallel 1 -- submit -- train --x @sweep

    # A state.json exists, so optimize takes the resume path; the driver errors.
    : > "${CAMPAIGNS}/err/state.json"
    _install_error_driver

    run knit ax optimize --campaign err
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to resume"* ]]
    [[ "$output" == *"simulated resume failure"* ]]
    # Crucially, no trial was launched: the failure did not degrade to a 0-done
    # full-budget re-run.
    [ "$(_launch_count)" -eq 0 ]
}
