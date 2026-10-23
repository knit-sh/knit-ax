#!/usr/bin/env bats
#
# MB5 tests: objective resolution (_knit_ax_resolve_objective) and the collector
# callback (_knit_ax_collect) reading the objective from a seeded DB through
# knit_search_read_objective.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    # A job target (submit mode): declares val_loss in its own table.
    knit_register "submit__1__train" knit_empty "Training job (submit)."
    knit_with_optional "lr:real"       "0.01" "learning rate" --domain '[1e-5..1.0]'
    knit_with_output   "val_loss:real" ""     "validation loss"
    knit_with_table    "train"
    knit_done
    # An app target (run mode): declares throughput in its own table.
    knit_register "run__1__bench" knit_empty "Bench app (run)."
    knit_with_optional "msg_size:integer" "64" "message size" --domain '{64,128}'
    knit_with_output   "throughput:real"  ""   "throughput"
    knit_with_table    "bench"
    knit_done
    # A target that declares a hyphenated output (column folds to underscores).
    knit_register "submit__1__hyp" knit_empty "Hyphen-output job."
    knit_with_output "val-loss:real" "" "validation loss"
    knit_with_table  "hyp"
    knit_done
}

teardown() {
    knit_ax_test_db_teardown
}

# ---------- _knit_ax_resolve_objective: default leaf-first ----------

@test "resolve picks the job target's table for a declared output" {
    local tbl col
    _knit_ax_resolve_objective tbl col "val_loss" submit -- train --lr @sweep
    [ "$tbl" = "train" ]
    [ "$col" = "val_loss" ]
}

@test "resolve picks the app target's table in run mode" {
    local tbl col
    _knit_ax_resolve_objective tbl col "throughput" run --procs 4 -- bench --msg-size @sweep
    [ "$tbl" = "bench" ]
    [ "$col" = "throughput" ]
}

@test "resolve normalizes a hyphenated objective to the underscore column" {
    local tbl col
    _knit_ax_resolve_objective tbl col "val-loss" submit -- hyp
    [ "$tbl" = "hyp" ]
    [ "$col" = "val_loss" ]
}

# ---------- _knit_ax_resolve_objective: segment override ----------

@test "override table:output forces the named segment" {
    local tbl col
    _knit_ax_resolve_objective tbl col "train:val_loss" submit -- train --lr @sweep
    [ "$tbl" = "train" ]
    [ "$col" = "val_loss" ]
}

@test "override can name the dispatcher segment by its table" {
    # The jobs table declares a "state" output (submit's placement columns).
    local tbl col
    _knit_ax_resolve_objective tbl col "jobs:state" submit -- train --lr @sweep
    [ "$tbl" = "jobs" ]
    [ "$col" = "state" ]
}

@test "override naming an undeclared output is fatal" {
    run _knit_ax_resolve_objective tbl col "train:nope" submit -- train
    [ "$status" -ne 0 ]
    [[ "$output" == *"no output"* ]]
}

@test "override naming a segment not in the chain is fatal" {
    run _knit_ax_resolve_objective tbl col "ghost:val_loss" submit -- train
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in the downstream chain"* ]]
}

# ---------- _knit_ax_resolve_objective: validations ----------

@test "an objective no segment declares is fatal" {
    run _knit_ax_resolve_objective tbl col "missing" submit -- train
    [ "$status" -ne 0 ]
    [[ "$output" == *"no segment"* ]]
}

@test "an empty objective spec is fatal" {
    run _knit_ax_resolve_objective tbl col "" submit -- train
    [ "$status" -ne 0 ]
}

# ---------- _knit_ax_collect: read via the provenance call-edge walk ----------

_seed_chain() {
    # The train table already exists (auto-created at registration, since the
    # test DB is marked bootstrapped). Add the jobs row (the launch id), the
    # provenance table, and a "call" edge jobs --call--> train body row.
    _knit_sqlite3 "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, state TEXT);"
    _knit_sqlite3 "CREATE TABLE IF NOT EXISTS ${_KNIT_PROV_TABLE} (source_id TEXT, target_id TEXT, edge_type TEXT);"
    _knit_sqlite3 "INSERT INTO jobs VALUES ('job-1','completed');"
    _knit_sqlite3 "INSERT INTO ${_KNIT_PROV_TABLE} (source_id,target_id,edge_type) VALUES ('job-1','body-1','call');"
}

@test "collect reads the objective from the descendant body row" {
    _seed_chain
    _knit_sqlite3 "INSERT INTO train (id, val_loss) VALUES ('body-1', 0.25);"
    local _knit_ax_obj_table="train" _knit_ax_obj_column="val_loss"
    local obj
    _knit_ax_collect obj "job-1"
    [ "$obj" = "0.25" ]
}

@test "collect signals failure on a NULL objective column" {
    _seed_chain
    _knit_sqlite3 "INSERT INTO train (id) VALUES ('body-1');"  # val_loss NULL
    local _knit_ax_obj_table="train" _knit_ax_obj_column="val_loss"
    local obj
    run _knit_ax_collect obj "job-1"
    [ "$status" -ne 0 ]
}

@test "collect signals failure when no objective row is reachable" {
    _seed_chain  # body-1 edge exists but no row was inserted into train
    local _knit_ax_obj_table="train" _knit_ax_obj_column="val_loss"
    local obj
    run _knit_ax_collect obj "job-1"
    [ "$status" -ne 0 ]
}

@test "collect reads an objective recorded directly in the dispatcher table" {
    _seed_chain
    local _knit_ax_obj_table="jobs" _knit_ax_obj_column="state"
    local obj
    _knit_ax_collect obj "job-1"
    [ "$obj" = "completed" ]
}
