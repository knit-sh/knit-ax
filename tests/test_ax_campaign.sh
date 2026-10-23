#!/usr/bin/env bats
#
# Campaign-model tests: "ax prepare" writes campaigns/<name>/ and records the
# optimizations row; duplicate prepare and missing-campaign optimize fatal; and
# "ax list" / "ax show" report a prepared campaign from disk. These exercise the
# prepare and reporting verbs without a live Ax process (no loop is driven here;
# resume and the trial call edges are covered live in the knit integration test).

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    # Put the experiment root (where campaigns/ lands) inside the throwaway DB dir.
    _KNIT_PREFIX="${KNIT_AX_TEST_DB_DIR}/.knit"
    CAMPAIGNS="${KNIT_AX_TEST_DB_DIR}/campaigns"
    # A submit-mode training job with a declared objective output and a varying
    # parameter, so "ax prepare" can resolve the objective and build a spec.
    knit_register "submit__1__train" knit_empty "Training job (submit)."
    knit_with_optional "lr:real"        "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_optional "epochs:integer" "10"   "epochs"
    knit_with_table    "train"
    knit_with_output   "val_loss:real"  ""     "validation loss"
    knit_done
}

teardown() {
    knit_ax_test_db_teardown
}

_prepare_demo() {
    knit ax prepare --campaign demo --objective val_loss --minimize \
        --trials 8 --parallel 2 --seed 7 -- submit -- train --lr @sweep --epochs 20
}

# ---------- ax prepare ----------

@test "prepare creates the campaign directory with definition and status" {
    run _prepare_demo
    [ "$status" -eq 0 ]
    [ -d "${CAMPAIGNS}/demo" ]
    [ -f "${CAMPAIGNS}/demo/definition.json" ]
    [ -f "${CAMPAIGNS}/demo/status" ]
    [ "$(cat "${CAMPAIGNS}/demo/status")" = "prepared" ]
}

@test "prepare writes the knobs and the downstream line into definition.json" {
    _prepare_demo
    local def
    def="$(cat "${CAMPAIGNS}/demo/definition.json")"
    [ "$(jq -r '.campaign'     <<<"$def")" = "demo" ]
    [ "$(jq -r '.objective'    <<<"$def")" = "val_loss" ]
    [ "$(jq -r '.sense'        <<<"$def")" = "minimize" ]
    [ "$(jq -r '.minimize'     <<<"$def")" = "true" ]
    [ "$(jq -r '.trials'       <<<"$def")" = "8" ]
    [ "$(jq -r '.parallel'     <<<"$def")" = "2" ]
    [ "$(jq -r '.seed'         <<<"$def")" = "7" ]
    [ "$(jq -r '.opt_id'       <<<"$def")" = "demo" ]
    # The downstream argv is stored verbatim as a JSON array.
    [ "$(jq -r '.downstream[0]' <<<"$def")" = "submit" ]
    [ "$(jq -r '.downstream | index("train")' <<<"$def")" != "null" ]
    [ "$(jq -r '.downstream | index("@sweep")' <<<"$def")" != "null" ]
}

@test "prepare maximize is reflected in sense" {
    knit ax prepare --campaign up --objective val_loss --maximize --trials 4 \
        -- submit -- train --lr @sweep
    [ "$(jq -r '.sense' <<<"$(cat "${CAMPAIGNS}/up/definition.json")")" = "maximize" ]
}

@test "prepare records the optimizations row under the campaign id" {
    _prepare_demo
    local row
    row=$("${_KNIT_SQLITE_EXE}" "${_KNIT_DATABASE}" \
        "SELECT campaign||'|'||trials||'|'||status||'|'||sense FROM optimizations WHERE id='demo';")
    [ "$row" = "demo|8|prepared|minimize" ]
}

@test "prepare fatals when the campaign already exists" {
    _prepare_demo
    run _prepare_demo
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

# ---------- ax optimize (pre-loop guards) ----------

@test "optimize on a missing campaign fatals with a helpful message" {
    run knit ax optimize --campaign nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no campaign"* ]]
    [[ "$output" == *"ax prepare"* ]]
}

# ---------- ax list / ax show ----------

@test "list reports a prepared campaign" {
    _prepare_demo
    run knit ax list
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"* ]]
    [[ "$output" == *"prepared"* ]]
}

@test "list on an empty experiment says there are no campaigns" {
    run knit ax list
    [ "$status" -eq 0 ]
    [[ "$output" == *"no campaigns"* ]]
}

@test "list --verbose shows the objective and the command" {
    _prepare_demo
    run knit ax list --verbose
    [ "$status" -eq 0 ]
    [[ "$output" == *"val_loss"* ]]
    [[ "$output" == *"submit"* ]]
    [[ "$output" == *"train"* ]]
}

@test "show reports one campaign's detail" {
    _prepare_demo
    run knit ax show --campaign demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"* ]]
    [[ "$output" == *"prepared"* ]]
    [[ "$output" == *"val_loss"* ]]
    [[ "$output" == *"minimize"* ]]
    [[ "$output" == *"8"* ]]
}

@test "show on a missing campaign fatals" {
    run knit ax show --campaign ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"no campaign"* ]]
}
