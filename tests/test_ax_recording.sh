#!/usr/bin/env bats
#
# Incremental progress recording for "ax optimize". _knit_ax_observe refreshes
# the campaign's result.json / optimizations row after every trial, and the
# INT/TERM handler stamps the campaign "interrupted", so "ax show" / "ax list"
# stay accurate even when a run is killed (e.g. a walltime SIGTERM) before the
# clean _knit_ax_finish. _knit_ax_is_better picks the better objective per sense.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    _KNIT_PREFIX="${KNIT_AX_TEST_DB_DIR}/.knit"
    CAMPAIGNS="${KNIT_AX_TEST_DB_DIR}/campaigns"
    # A submit-mode training job with a declared objective and a varying knob, so
    # "ax prepare" can build a campaign (its dir and the optimizations row are the
    # fixtures the recording path writes to).
    knit_register "submit__1__train" knit_empty "Training job (submit)."
    knit_with_optional "lr:real" "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_table    "train"
    knit_with_output   "val_loss:real" "" "validation loss"
    knit_done
    knit ax prepare --campaign demo --objective val_loss --minimize \
        --trials 8 --parallel 1 --seed 1 -- submit -- train --lr @sweep
    DIR="${CAMPAIGNS}/demo"
}

teardown() {
    knit_ax_test_db_teardown
}

# ---------- _knit_ax_is_better ----------

@test "is_better: an empty best accepts any candidate" {
    _knit_ax_is_better 0.5 "" true
    _knit_ax_is_better 0.5 "" false
}

@test "is_better: minimize prefers the smaller value" {
    _knit_ax_is_better 0.2 0.5 true
    run _knit_ax_is_better 0.9 0.5 true
    [ "$status" -ne 0 ]
}

@test "is_better: maximize prefers the larger value" {
    _knit_ax_is_better 0.9 0.5 false
    run _knit_ax_is_better 0.2 0.5 false
    [ "$status" -ne 0 ]
}

@test "is_better: compares numerically, not lexically" {
    # 0.001 < 0.01 numerically; a string compare would get this wrong.
    _knit_ax_is_better 1e-3 1e-2 true
    _knit_ax_is_better 9 10 true
}

# ---------- incremental recording through _knit_ax_observe ----------

@test "observe records live trials_done, best-so-far, and a running status" {
    # Minimal _knit_ax_optimize frame; the recording path reads these by dynamic
    # scope. Stub the driver RPC so the "tell" needs no coprocess.
    local dir="${DIR}" campaign="demo" minimize="true"
    local _knit_ax_done=0 _knit_ax_best_obj="" _knit_ax_best_idx="" _knit_ax_best_id=""
    local on_failure="ignore" penalty=""
    declare -A _knit_ax_trial_row=()
    _knit_ax_rpc() { local -n __r=$1; __r='{"status":"ok"}'; }

    _knit_ax_observe 0 row-0 completed 0.40
    _knit_ax_observe 1 row-1 completed 0.25
    _knit_ax_observe 2 row-2 completed 0.90

    [ -f "${DIR}/result.json" ]
    [ "$(jq -r '.trials_done'    "${DIR}/result.json")" = "3" ]
    # minimize => the smallest objective wins, with its trial index and row id.
    [ "$(jq -r '.best.objective' "${DIR}/result.json")" = "0.25" ]
    [ "$(jq -r '.best.index'     "${DIR}/result.json")" = "1" ]
    [ "$(jq -r '.best.id'        "${DIR}/result.json")" = "row-1" ]
    [ "$(cat "${DIR}/status")" = "running" ]
}

@test "observe counts a failed trial but does not let it win the best" {
    local dir="${DIR}" campaign="demo" minimize="true"
    local _knit_ax_done=0 _knit_ax_best_obj="" _knit_ax_best_idx="" _knit_ax_best_id=""
    local on_failure="ignore" penalty=""
    declare -A _knit_ax_trial_row=()
    _knit_ax_rpc() { local -n __r=$1; __r='{"status":"ok"}'; }

    _knit_ax_observe 0 row-0 completed 0.4
    _knit_ax_observe 1 row-1 failed ""

    [ "$(jq -r '.trials_done'    "${DIR}/result.json")" = "2" ]
    [ "$(jq -r '.best.objective' "${DIR}/result.json")" = "0.4" ]
    [ "$(jq -r '.best.id'        "${DIR}/result.json")" = "row-0" ]
}

@test "observe outside an optimize frame only tells Ax (no recording)" {
    # No dir/campaign in scope: the guard makes recording a no-op, so no stray
    # result.json is written and the tell still happens.
    local told=""
    _knit_ax_rpc() { local -n __r=$1; told="yes"; __r='{"status":"ok"}'; }
    local on_failure="ignore" penalty=""
    declare -A _knit_ax_trial_row=()

    _knit_ax_observe 0 row-0 completed 0.40
    [ "${told}" = "yes" ]
    [ ! -f "${DIR}/result.json" ]
}

# ---------- interrupt leaves a resumable "interrupted" record ----------

@test "interrupt stamps the campaign interrupted, keeping the recorded count" {
    # A run recorded 3 trials, then is signalled before the clean finish.
    _knit_ax_finish "${DIR}" demo running 3 row-1 1 0.25
    local dir="${DIR}" campaign="demo"
    local _KNIT_AX_COPROC_PID=""
    # _knit_ax_interrupt exits 143; run it in a subshell so the test survives.
    ( _knit_ax_interrupt ) || true

    [ "$(cat "${DIR}/status")" = "interrupted" ]
    # The count/best recorded before the signal are untouched.
    [ "$(jq -r '.trials_done'    "${DIR}/result.json")" = "3" ]
    [ "$(jq -r '.best.objective' "${DIR}/result.json")" = "0.25" ]
    # The DB row reflects the interrupted status too.
    [ "$(_knit_sqlite3 "SELECT status FROM optimizations WHERE id='demo';")" = "interrupted" ]
}
