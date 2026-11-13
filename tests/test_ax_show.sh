#!/usr/bin/env bats
#
# "ax show" tests: the default detail for an optimize campaign (unchanged: shows
# a best) versus a model campaign (shows the command-qualified axis names and no
# optimum), and the opt-in --diagnostics flag (cross-validated R^2 / RMSE via the
# driver). The Ax brain is the deterministic fake driver (tests/fake_ax_driver.py),
# whose diagnostics returns a fixed fold count / R^2 / RMSE. Real-Ax diagnostics
# are exercised by tests/test_ax_protocol.py.

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

    knit_register "submit__1__train" knit_empty "Surrogate training job."
    knit_with_optional "x:real" "" "x knob" --domain '[0..12]'
    knit_with_table    "train"
    knit_with_output   "score:real" "" "surrogate score"
    knit_done

    _install_show_seams
}

teardown() {
    knit_ax_test_db_teardown
}

_install_show_seams() {
    _knit_ax_ensure_driver() {
        local -n __ret=$1
        __ret="${KNIT_AX_TEST_DB_DIR}/driver"
        mkdir -p "${__ret}"
    }
    _knit_ax_start_driver() {
        coproc AX_DRIVER { exec python3 "${FAKE_DRIVER}"; }
        _KNIT_AX_RPC_OUT="${AX_DRIVER[0]}"
        _KNIT_AX_RPC_IN="${AX_DRIVER[1]}"
        _KNIT_AX_COPROC_PID="${AX_DRIVER_PID}"
    }
}

_prepare_optimize() {
    knit ax prepare --campaign "$1" --objective score --max-trials 5 \
        -- submit -- train --x '[0..12]'
}

_prepare_model() {
    knit ax prepare --campaign "$1" --objective score --model --max-trials 5 \
        -- submit -- train --x '[0..12]'
}

_seed_state() {
    printf '{"spec":{"objective":{"name":"score"}},"next_idx":0,"trials":{}}\n' \
        > "${CAMPAIGNS}/$1/state.json"
}

# ---------- command surface ----------

@test "ax show --help shows --campaign and --diagnostics" {
    run knit ax show --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--campaign"* ]]
    [[ "$output" == *"--diagnostics"* ]]
}

# ---------- default detail ----------

@test "ax show on an optimize campaign shows a best and no axes line" {
    _prepare_optimize c_opt
    run knit ax show --campaign c_opt
    [ "$status" -eq 0 ]
    [[ "$output" == *"best:"* ]]
    [[ "$output" != *"axes:"* ]]
    [[ "$output" == *"(minimize)"* ]]
}

@test "ax show on a model campaign shows the axes and no best" {
    _prepare_model c_mod
    run knit ax show --campaign c_mod
    [ "$status" -eq 0 ]
    [[ "$output" == *"axes:"* ]]
    [[ "$output" == *"train.x"* ]]
    [[ "$output" != *"best:"* ]]
    [[ "$output" == *"(model)"* ]]
}

# ---------- --diagnostics ----------

@test "ax show --diagnostics before any trial fatals" {
    _prepare_model c_notrial
    run knit ax show --campaign c_notrial --diagnostics
    [ "$status" -ne 0 ]
    [[ "$output" == *"no trials yet"* ]]
}

@test "ax show --diagnostics reports cross-validated R^2 and RMSE" {
    _prepare_model c_diag
    _seed_state c_diag
    run knit ax show --campaign c_diag --diagnostics
    [ "$status" -eq 0 ]
    [[ "$output" == *"diagnostics:"* ]]
    [[ "$output" == *"cross-val R^2:  0.9"* ]]
    [[ "$output" == *"4 folds"* ]]
    [[ "$output" == *"cross-val RMSE: 1.5"* ]]
}

@test "ax show --diagnostics works on an optimize campaign too" {
    _prepare_optimize c_odiag
    _seed_state c_odiag
    run knit ax show --campaign c_odiag --diagnostics
    [ "$status" -eq 0 ]
    [[ "$output" == *"best:"* ]]
    [[ "$output" == *"cross-val R^2:  0.9"* ]]
}
