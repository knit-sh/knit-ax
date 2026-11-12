#!/usr/bin/env bats
#
# "ax predict" tests: the command surface, the command-mirroring validation
# (command shape, fixed-token mismatch, out-of-domain axis value), the point
# construction, and the output forms (bare mean, --variance / --std / --interval,
# --json). The Ax brain is replaced by the deterministic fake driver
# (tests/fake_ax_driver.py), whose predict returns mean = sum of the point's
# numeric coordinates and sem = 2.0, so an exact value can be asserted without
# fitting a real model. Real-Ax predict is exercised by tests/test_ax_protocol.py.

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

    # A submit-mode job: one varying real parameter (x), one fixed real
    # parameter (y), and a declared objective output. prepare needs the
    # registration to resolve the objective and build the spec.
    knit_register "submit__1__train" knit_empty "Surrogate training job."
    knit_with_optional "x:real" "" "x knob" --domain '[0..12]'
    knit_with_optional "y:real" "5" "fixed y"
    knit_with_table    "train"
    knit_with_output   "score:real" "" "surrogate score"
    knit_done

    _install_predict_seams
}

teardown() {
    knit_ax_test_db_teardown
}

# ---------- seams ----------

# Replace the two externals a predict touches: the driver-env build (returns a
# throwaway prefix) and the coprocess launch (runs the deterministic fake driver
# with no venv). Everything else — validation, point building, output — is real.
_install_predict_seams() {
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

# Prepare a campaign over the given downstream command.
_prepare() {
    local camp="$1"; shift
    knit ax prepare --campaign "${camp}" --objective score --max-trials 5 \
        -- "$@"
}

# Seed a minimal, fake-driver-loadable state.json so predict's resume succeeds.
# (prepare writes no state; only a run would. The fake driver's predict reads
# only spec.objective.name, so a trivial state suffices.)
_seed_state() {
    local camp="$1" obj="${2:-score}"
    printf '{"spec":{"objective":{"name":"%s"}},"next_idx":0,"trials":{}}\n' \
        "${obj}" > "${CAMPAIGNS}/${camp}/state.json"
}

# ---------- command surface ----------

@test "ax predict is registered after lazy discovery" {
    knit ax --help > /dev/null 2>&1 || true
    _knit_set_find _KNIT_COMMANDS "ax__1__predict"
}

@test "ax predict --help shows --campaign, the output flags, and the dispatcher form" {
    run knit ax predict --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--campaign"* ]]
    [[ "$output" == *"--variance"* ]]
    [[ "$output" == *"--std"* ]]
    [[ "$output" == *"--interval"* ]]
    [[ "$output" == *"--json"* ]]
}

@test "ax predict on a missing campaign fatals" {
    run knit ax predict --campaign nope -- submit -- train --x 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"no campaign"* ]]
}

@test "ax predict without a command after -- fatals" {
    _prepare c_nocmd submit -- train --x '[0..12]'
    _seed_state c_nocmd
    run knit ax predict --campaign c_nocmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"command is required"* ]]
}

@test "ax predict before any trial fatals (no fitted model)" {
    _prepare c_notrial submit -- train --x '[0..12]'
    run knit ax predict --campaign c_notrial -- submit -- train --x 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"no trials yet"* ]]
}

# ---------- validation: the three fatals ----------

@test "ax predict rejects a different command shape" {
    _prepare c_shape submit -- train --x '[0..12]'
    _seed_state c_shape
    run knit ax predict --campaign c_shape -- run -- train --x 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match the command expected by the campaign"* ]]
}

@test "ax predict rejects a fixed token that differs" {
    _prepare c_fixed submit -- train --x '[0..12]' --y 5
    _seed_state c_fixed
    run knit ax predict --campaign c_fixed -- submit -- train --x 5 --y 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"--y 7"* ]]
    [[ "$output" == *"--y 5"* ]]
}

@test "ax predict rejects an extra fixed token not in the campaign" {
    _prepare c_extra submit -- train --x '[0..12]'
    _seed_state c_extra
    run knit ax predict --campaign c_extra -- submit -- train --x 5 --y 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"--y 7"* ]]
}

@test "ax predict rejects a range axis value out of bounds" {
    _prepare c_oob submit -- train --x '[0..12]'
    _seed_state c_oob
    run knit ax predict --campaign c_oob -- submit -- train --x 20
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the campaign's domain"* ]]
}

@test "ax predict rejects a non-numeric range axis value" {
    _prepare c_nan submit -- train --x '[0..12]'
    _seed_state c_nan
    run knit ax predict --campaign c_nan -- submit -- train --x abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the campaign's domain"* ]]
}

@test "ax predict rejects a choice axis value not in the set" {
    _prepare c_choice submit -- train --x '{1,2,4}'
    _seed_state c_choice
    run knit ax predict --campaign c_choice -- submit -- train --x 3
    [ "$status" -ne 0 ]
    [[ "$output" == *"not one of the campaign's values"* ]]
}

@test "ax predict requires a value for every varying axis" {
    _prepare c_missing submit -- train --x '[0..12]'
    _seed_state c_missing
    run knit ax predict --campaign c_missing -- submit -- train
    [ "$status" -ne 0 ]
    [[ "$output" == *"no value for"* ]]
    [[ "$output" == *"--x"* ]]
}

# ---------- happy path: output forms ----------

@test "ax predict prints the bare mean by default" {
    _prepare c_bare submit -- train --x '[0..12]'
    _seed_state c_bare
    run knit ax predict --campaign c_bare -- submit -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == "5" ]]
}

@test "ax predict accepts an in-set choice axis value" {
    _prepare c_cok submit -- train --x '{1,2,4}'
    _seed_state c_cok
    run knit ax predict --campaign c_cok -- submit -- train --x 4
    [ "$status" -eq 0 ]
    [[ "$output" == "4" ]]
}

@test "ax predict --variance appends the posterior variance" {
    _prepare c_var submit -- train --x '[0..12]'
    _seed_state c_var
    run knit ax predict --campaign c_var --variance -- submit -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"var 4"* ]]
}

@test "ax predict --std --interval appends the std and the 95% interval" {
    _prepare c_si submit -- train --x '[0..12]'
    _seed_state c_si
    run knit ax predict --campaign c_si --std --interval -- submit -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"95% CI 1.08"* ]]
    [[ "$output" == *"8.92"* ]]
}

@test "ax predict --json emits a structured object" {
    _prepare c_json submit -- train --x '[0..12]'
    _seed_state c_json
    run knit ax predict --campaign c_json --json -- submit -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == *'"objective":"score"'* ]]
    [[ "$output" == *'"mean":5'* ]]
    [[ "$output" == *'"sem":2'* ]]
    [[ "$output" == *'"variance":4'* ]]
    [[ "$output" == *'"ci95":[1.08,8.92]'* ]]
}

@test "ax predict works on a --model campaign" {
    _prepare_model() {
        knit ax prepare --campaign c_model --objective score --model --max-trials 5 \
            -- submit -- train --x '[0..12]'
    }
    _prepare_model
    _seed_state c_model
    run knit ax predict --campaign c_model -- submit -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == "5" ]]
}

@test "ax predict sums both varying axes into the point" {
    # Two axes: the dispatcher's --nodes and the target's --x. The fake driver
    # returns the sum of the point's coordinates, proving both reached the point.
    _prepare c_two submit --nodes '{1,2,4}' -- train --x '[0..12]'
    _seed_state c_two
    run knit ax predict --campaign c_two -- submit --nodes 2 -- train --x 5
    [ "$status" -eq 0 ]
    [[ "$output" == "7" ]]
}
