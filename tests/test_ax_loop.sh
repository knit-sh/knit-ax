#!/usr/bin/env bats
#
# MB6 tests: the ask/tell loop wiring. The Ax coprocess is stubbed at the single
# RPC seam (_knit_ax_rpc), so these exercise the proposer logic — line
# reconstruction, ask, observe, and the prepare-time validations — without a
# live Ax process or scheduler. End-to-end convergence lives in MB8.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    _KNIT_JQ_EXE="jq"
}

teardown() {
    knit_ax_test_db_teardown
}

# ---------- _knit_ax_reconstruct ----------

@test "reconstruct replaces an @sweep slot in place" {
    local -a template=(submit -- train --lr @sweep --epochs 20)
    local -A slot_by_param=([lr]=4)   # index of the @sweep token
    local -a argv
    _knit_ax_reconstruct argv '{"lr":0.03}' template slot_by_param
    [ "${argv[4]}" = "0.03" ]
    [ "${argv[3]}" = "--lr" ]
    [ "${argv[5]}" = "--epochs" ]
    # no extra tokens appended
    [ "${#argv[@]}" -eq 7 ]
}

@test "reconstruct appends a domain-only varying parameter" {
    local -a template=(submit -- train --epochs 20)
    local -A slot_by_param=()         # lr has no token (fill sweep)
    local -a argv
    _knit_ax_reconstruct argv '{"lr":0.03}' template slot_by_param
    # original tokens preserved, then "--lr 0.03" appended
    [ "${argv[0]}" = "submit" ]
    [ "${argv[-2]}" = "--lr" ]
    [ "${argv[-1]}" = "0.03" ]
}

@test "reconstruct handles several parameters (slot + append)" {
    local -a template=(submit -- train --lr @sweep)
    local -A slot_by_param=([lr]=4)
    local -a argv
    _knit_ax_reconstruct argv '{"lr":0.1,"batch":64}' template slot_by_param
    [ "${argv[4]}" = "0.1" ]
    # batch has no slot -> appended
    local joined="${argv[*]}"
    [[ "$joined" == *"--batch 64"* ]]
}

# ---------- _knit_ax_ask ----------

@test "ask reconstructs the next trial and returns its index as the tag" {
    local -a template=(submit -- train --lr @sweep --epochs 20)
    local -A slot_by_param=([lr]=4)
    local group=""
    # Stub the RPC: return one trial.
    _knit_ax_rpc() { local -n __r=$1; __r='{"trials":[{"index":7,"params":{"lr":0.05}}]}'; }
    local tag
    local -a argv
    _knit_ax_ask tag argv
    [ "$tag" = "7" ]
    [ "${argv[4]}" = "0.05" ]
}

@test "ask splices --group in job mode" {
    local -a template=(submit -- train --lr @sweep)
    local -A slot_by_param=([lr]=4)
    local group="camp1"
    _knit_ax_rpc() { local -n __r=$1; __r='{"trials":[{"index":0,"params":{"lr":0.05}}]}'; }
    local tag
    local -a argv
    _knit_ax_ask tag argv
    [ "${argv[0]}" = "submit" ]
    [ "${argv[1]}" = "--group" ]
    [ "${argv[2]}" = "camp1" ]
}

@test "ask returns non-zero when Ax proposes no trial" {
    local -a template=(submit -- train)
    local -A slot_by_param=()
    local group=""
    _knit_ax_rpc() { local -n __r=$1; __r='{"trials":[]}'; }
    local tag
    local -a argv
    run _knit_ax_ask tag argv
    [ "$status" -ne 0 ]
}

# ---------- _knit_ax_observe ----------

# Capture the request the observe callback sends.
_capture_rpc() { _knit_ax_rpc() { local -n __r=$1; _TEST_REQ="$2"; __r='{"status":"ok"}'; }; }

@test "observe tells Ax a completed trial with its objective" {
    local on_failure="ignore" penalty=""
    _capture_rpc
    _knit_ax_observe 3 some-uuid completed 0.25
    [ "$(jq -r '.cmd'       <<<"$_TEST_REQ")" = "tell" ]
    [ "$(jq -r '.index'     <<<"$_TEST_REQ")" = "3" ]
    [ "$(jq -r '.status'    <<<"$_TEST_REQ")" = "ok" ]
    [ "$(jq -r '.objective' <<<"$_TEST_REQ")" = "0.25" ]
}

@test "observe tells failed under --on-failure ignore (failed status)" {
    local on_failure="ignore" penalty=""
    _capture_rpc
    _knit_ax_observe 3 some-uuid failed ""
    [ "$(jq -r '.status'       <<<"$_TEST_REQ")" = "failed" ]
    [ "$(jq -r 'has("objective")' <<<"$_TEST_REQ")" = "false" ]
}

@test "observe tells failed when the objective is empty (NULL) even if completed" {
    local on_failure="ignore" penalty=""
    _capture_rpc
    _knit_ax_observe 3 some-uuid completed ""
    [ "$(jq -r '.status' <<<"$_TEST_REQ")" = "failed" ]
}

@test "observe tells a penalty value under --on-failure penalize" {
    local on_failure="penalize" penalty="99"
    _capture_rpc
    _knit_ax_observe 5 some-uuid failed ""
    [ "$(jq -r '.status'    <<<"$_TEST_REQ")" = "penalized" ]
    [ "$(jq -r '.objective' <<<"$_TEST_REQ")" = "99" ]
    [ "$(jq -r '.index'     <<<"$_TEST_REQ")" = "5" ]
}

@test "observe always returns 0 (a bad trial never aborts the campaign)" {
    local on_failure="ignore" penalty=""
    _capture_rpc
    run _knit_ax_observe 3 some-uuid failed ""
    [ "$status" -eq 0 ]
}

# ---------- prepare-time validations (no coprocess reached) ----------
# The OPTIMIZE ARGS and their validation moved from the old single "optimize"
# dispatcher onto "ax prepare", which fails fast before any campaign is written.

@test "prepare fatals without --objective" {
    run knit ax prepare --campaign c1 --trials 5 -- submit -- train --lr @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"objective"* ]]
}

@test "prepare fatals without --trials" {
    run knit ax prepare --campaign c1 --objective val_loss -- submit -- train --lr @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"trials"* ]]
}

@test "prepare rejects --parallel > 1 in app mode" {
    run knit ax prepare --campaign c1 --objective throughput --trials 5 --parallel 2 \
        -- run --procs 4 -- bench --msg-size @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"parallel"* ]]
    [[ "$output" == *"app mode"* ]]
}

@test "prepare rejects a non-submit/run downstream" {
    run knit ax prepare --campaign c1 --objective z --trials 5 -- somebare --x @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"submit"* ]]
    [[ "$output" == *"run"* ]]
}
