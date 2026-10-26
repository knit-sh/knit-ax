#!/usr/bin/env bats
#
# MB4 tests for _knit_ax_build_spec_json: search-space extraction.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    _KNIT_JQ_EXE="jq"
    # Register a test command "train" with known parameters and outputs.
    knit_register "train" knit_empty "Training job."
    knit_with_optional "lr:real"        "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_optional "batch:integer"  "32"   "batch size"    --domain '{16,32,64}'
    knit_with_optional "optimizer:string" "sgd" "optimizer"
    knit_with_optional "epochs:integer" "10"   "epochs"
    knit_with_optional "dropout:real"   "0.0"  "dropout"
    knit_with_output   "val_loss:real"  ""     "validation loss"
    knit_done
    # Register a "submit__1__train" variant for submit-mode tests.
    knit_register "submit__1__train" knit_empty "Training job (submit)."
    knit_with_optional "lr:real"        "0.01" "learning rate" --domain '[1e-5..1.0]' --log
    knit_with_optional "batch:integer"  "32"   "batch size"    --domain '{16,32,64}'
    knit_with_optional "epochs:integer" "10"   "epochs"
    knit_with_output   "val_loss:real"  ""     "validation loss"
    knit_done
    # Register a no-domain command for the "no varying parameter" test.
    knit_register "fixedcmd" knit_empty "All-fixed command."
    knit_with_optional "x:real"    "0.0" "x-value"
    knit_with_optional "y:integer" "1"   "y-value"
    knit_with_output   "z:real"    ""    "output"
    knit_done
    # Register a command with a non-numeric output for the objective-type test.
    knit_register "labeler" knit_empty "String-output command."
    knit_with_optional "x:real" "0" "x" --domain '[0..1]'
    knit_with_output   "label:string" "" "predicted label"
    knit_done
    # A command with a glob domain (config) plus a plain string param (data) that
    # a glob token is given to explicitly, for the @glob paths.
    knit_register "globcmd" knit_empty "Command with a glob domain."
    knit_with_optional "config:string" "default.yaml" "config file" --domain '@glob:*.glomtest'
    knit_with_optional "data:string"   "d"            "data file"
    knit_with_output   "val_loss:real" ""             "validation loss"
    knit_done
    # A command whose glob domain matches nothing in the fixture directory.
    knit_register "globnomatch" knit_empty "Command whose glob domain matches nothing."
    knit_with_optional "config:string" "x" "config file" --domain '@glob:*.nomatch_xyz'
    knit_with_output   "val_loss:real" "" "validation loss"
    knit_done
    # A fixture directory holding the files the glob tests match. Bats runs each
    # test in its own subshell, so a test may cd here without disturbing others.
    KNIT_AX_GLOB_DIR="$(mktemp -d)"
    : > "${KNIT_AX_GLOB_DIR}/alpha.glomtest"
    : > "${KNIT_AX_GLOB_DIR}/beta.glomtest"
}

teardown() {
    rm -rf "${KNIT_AX_GLOB_DIR:-}"
    knit_ax_test_db_teardown
}

# ---------- helper: run build_spec_json and parse output ----------

_spec() {
    # Usage: _spec <objective> <minimize> <seed> <sobol> [downstream tokens...]
    local obj="$1" min="$2" seed="$3" sobol="$4"
    shift 4
    _knit_ax_build_spec_json "${obj}" "${min}" "${seed}" "${sobol}" "$@"
}

# ---------- @sweep tokens use the declared domain ----------

@test "lr @sweep becomes a float RangeParameter with log_scale=true" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train --lr @sweep --epochs 20)
    local kind vtype log
    kind=$(jq -r '.parameters[] | select(.name=="lr") | .ax'          <<<"$spec")
    vtype=$(jq -r '.parameters[] | select(.name=="lr") | .value_type' <<<"$spec")
    log=$(jq -r   '.parameters[] | select(.name=="lr") | .log_scale'  <<<"$spec")
    [ "$kind"  = "range" ]
    [ "$vtype" = "float" ]
    [ "$log"   = "true" ]
    # Check bounds are numeric: lo < 0.001, hi == 1.0.
    [ "$(jq '.parameters[] | select(.name=="lr") | .bounds[0] < 0.001' <<<"$spec")" = "true" ]
    [ "$(jq '.parameters[] | select(.name=="lr") | .bounds[1] == 1'    <<<"$spec")" = "true" ]
}

@test "batch @sweep becomes an ordered int ChoiceParameter" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train --batch @sweep --epochs 20)
    local kind vtype ordered
    kind=$(jq -r    '.parameters[] | select(.name=="batch") | .ax'       <<<"$spec")
    vtype=$(jq -r   '.parameters[] | select(.name=="batch") | .value_type' <<<"$spec")
    ordered=$(jq -r '.parameters[] | select(.name=="batch") | .ordered'  <<<"$spec")
    vals=$(jq -r    '.parameters[] | select(.name=="batch") | .values|join(",")' <<<"$spec")
    [ "$kind"    = "choice" ]
    [ "$vtype"   = "int" ]
    [ "$ordered" = "true" ]
    [ "$vals"    = "16,32,64" ]
}

# ---------- explicit literal tokens ----------

@test "explicit {sgd,adam} becomes a categorical str ChoiceParameter" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train \
        --optimizer '{sgd,adam}' --epochs 20)
    local kind vtype ordered vals
    kind=$(jq -r    '.parameters[] | select(.name=="optimizer") | .ax'          <<<"$spec")
    vtype=$(jq -r   '.parameters[] | select(.name=="optimizer") | .value_type'  <<<"$spec")
    ordered=$(jq -r '.parameters[] | select(.name=="optimizer") | .ordered'     <<<"$spec")
    vals=$(jq -r    '.parameters[] | select(.name=="optimizer") | .values|join(",")' <<<"$spec")
    [ "$kind"    = "choice" ]
    [ "$vtype"   = "str" ]
    [ "$ordered" = "false" ]
    [ "$vals"    = "sgd,adam" ]
}

@test "explicit [0.1..0.9] becomes a float RangeParameter without log_scale" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train \
        --dropout '[0.1..0.9]' --epochs 20)
    local kind vtype log lo hi
    kind=$(jq -r  '.parameters[] | select(.name=="dropout") | .ax'          <<<"$spec")
    vtype=$(jq -r '.parameters[] | select(.name=="dropout") | .value_type'  <<<"$spec")
    log=$(jq -r   '.parameters[] | select(.name=="dropout") | .log_scale'   <<<"$spec")
    lo=$(jq -r    '.parameters[] | select(.name=="dropout") | .bounds[0]'   <<<"$spec")
    hi=$(jq -r    '.parameters[] | select(.name=="dropout") | .bounds[1]'   <<<"$spec")
    [ "$kind"  = "range" ]
    [ "$vtype" = "float" ]
    [ "$log"   = "false" ]
    [ "$lo"    = "0.1" ]
    [ "$hi"    = "0.9" ]
}

@test "explicit {2,4,8} of integer type becomes an ordered int ChoiceParameter" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train \
        --batch '{2,4,8}' --epochs 20)
    local vtype ordered
    vtype=$(jq -r   '.parameters[] | select(.name=="batch") | .value_type' <<<"$spec")
    ordered=$(jq -r '.parameters[] | select(.name=="batch") | .ordered'    <<<"$spec")
    [ "$vtype"   = "int" ]
    [ "$ordered" = "true" ]
}

# ---------- @glob tokens and @glob: domains expand to str choices ----------

@test "explicit @glob token becomes a categorical str ChoiceParameter over matched files" {
    cd "${KNIT_AX_GLOB_DIR}"
    local spec
    spec=$(_spec "val_loss" "true" "" "" globcmd --data '@glob:*.glomtest')
    local kind vtype ordered vals
    kind=$(jq -r    '.parameters[] | select(.name=="data") | .ax'         <<<"$spec")
    vtype=$(jq -r   '.parameters[] | select(.name=="data") | .value_type' <<<"$spec")
    ordered=$(jq -r '.parameters[] | select(.name=="data") | .ordered'    <<<"$spec")
    vals=$(jq -r    '.parameters[] | select(.name=="data") | .values|sort|join(",")' <<<"$spec")
    [ "$kind"    = "choice" ]
    [ "$vtype"   = "str" ]
    [ "$ordered" = "false" ]
    [ "$vals"    = "alpha.glomtest,beta.glomtest" ]
}

@test "glob domain with @sweep becomes a categorical str ChoiceParameter over matched files" {
    cd "${KNIT_AX_GLOB_DIR}"
    local spec
    spec=$(_spec "val_loss" "true" "" "" globcmd --config @sweep)
    local kind vtype ordered vals
    kind=$(jq -r    '.parameters[] | select(.name=="config") | .ax'         <<<"$spec")
    vtype=$(jq -r   '.parameters[] | select(.name=="config") | .value_type' <<<"$spec")
    ordered=$(jq -r '.parameters[] | select(.name=="config") | .ordered'    <<<"$spec")
    vals=$(jq -r    '.parameters[] | select(.name=="config") | .values|sort|join(",")' <<<"$spec")
    [ "$kind"    = "choice" ]
    [ "$vtype"   = "str" ]
    [ "$ordered" = "false" ]
    [ "$vals"    = "alpha.glomtest,beta.glomtest" ]
}

@test "an explicit @glob matching no files is fatal" {
    cd "${KNIT_AX_GLOB_DIR}"
    run _spec "val_loss" "true" "" "" globcmd --data '@glob:*.nomatch_xyz'
    [ "$status" -ne 0 ]
    [[ "$output" == *"matched no files"* ]]
}

@test "a glob domain matching no files is fatal" {
    cd "${KNIT_AX_GLOB_DIR}"
    run _spec "val_loss" "true" "" "" globnomatch --config @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"matched no files"* ]]
}

# ---------- _knit_ax_value_type inference (empty knit type) ----------

@test "value_type infers int for all-integer values when the type is empty" {
    local vt
    _knit_ax_value_type vt "" 2 4 8
    [ "$vt" = "int" ]
}

@test "value_type infers float for a mix of integer and decimal values" {
    local vt
    _knit_ax_value_type vt "" 1 2.5 3
    [ "$vt" = "float" ]
}

@test "value_type infers str for non-numeric values" {
    local vt
    _knit_ax_value_type vt "" sgd adam
    [ "$vt" = "str" ]
}

@test "value_type infers str when one member of a numeric list is non-numeric" {
    local vt
    _knit_ax_value_type vt "" 1 2 three
    [ "$vt" = "str" ]
}

@test "value_type infers str when there are no values to infer from" {
    local vt
    _knit_ax_value_type vt ""
    [ "$vt" = "str" ]
}

@test "value_type honors an explicit knit type over value inference" {
    local vt
    _knit_ax_value_type vt "string" 1 2 3
    [ "$vt" = "str" ]
    _knit_ax_value_type vt "real" 1 2 3
    [ "$vt" = "float" ]
    _knit_ax_value_type vt "integer" 1.5 2.5
    [ "$vt" = "int" ]
}

# ---------- fixed parameters are not in the spec ----------

@test "fixed --epochs 20 does not appear in parameters" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train --lr @sweep --epochs 20)
    local cnt
    cnt=$(jq '.parameters | map(select(.name=="epochs")) | length' <<<"$spec")
    [ "$cnt" = "0" ]
}

# ---------- BO-specific: real --range is a first-class dimension ----------

@test "fill sweep includes lr even without an explicit @sweep token" {
    local spec
    # With --fill sweep (BO default), lr has a declared domain → it varies.
    spec=$(_spec "val_loss" "true" "" "" train --epochs 20)
    local cnt
    cnt=$(jq '.parameters | map(select(.name=="lr")) | length' <<<"$spec")
    [ "$cnt" = "1" ]
}

@test "real range domain yields a float RangeParameter (not a fatal)" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train --lr @sweep --epochs 20)
    local kind vtype
    kind=$(jq -r  '.parameters[] | select(.name=="lr") | .ax'          <<<"$spec")
    vtype=$(jq -r '.parameters[] | select(.name=="lr") | .value_type'  <<<"$spec")
    [ "$kind"  = "range" ]
    [ "$vtype" = "float" ]
}

# ---------- submit mode: resolves the job inside the downstream ----------

@test "submit -- train downstream resolves to the job parameters" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" submit -- train --lr @sweep --epochs 10)
    local cnt
    cnt=$(jq '.parameters | length' <<<"$spec")
    [ "$cnt" -ge 1 ]
    local kind
    kind=$(jq -r '.parameters[] | select(.name=="lr") | .ax' <<<"$spec")
    [ "$kind" = "range" ]
}

# ---------- objective in the spec ----------

@test "objective name and minimize are in the spec" {
    local spec
    spec=$(_spec "val_loss" "true" "42" "4" train --lr @sweep --epochs 20)
    local obj_name minimize
    obj_name=$(jq -r  '.objective.name'     <<<"$spec")
    minimize=$(jq -r  '.objective.minimize' <<<"$spec")
    [ "$obj_name" = "val_loss" ]
    [ "$minimize" = "true" ]
}

@test "seed and sobol_trials appear in spec when set" {
    local spec
    spec=$(_spec "val_loss" "false" "42" "4" train --lr @sweep --epochs 20)
    [ "$(jq '.seed'         <<<"$spec")" = "42" ]
    [ "$(jq '.sobol_trials' <<<"$spec")" = "4" ]
}

@test "seed and sobol_trials are absent from spec when empty" {
    local spec
    spec=$(_spec "val_loss" "true" "" "" train --lr @sweep --epochs 20)
    [ "$(jq 'has("seed")'         <<<"$spec")" = "false" ]
    [ "$(jq 'has("sobol_trials")' <<<"$spec")" = "false" ]
}

# ---------- validations ----------

@test "no varying parameter is fatal" {
    # fixedcmd has no declared domains; providing only scalar values → nothing varies.
    run _spec "z" "true" "" "" fixedcmd --x 0.5 --y 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"no parameter varies"* ]]
}

@test "non-numeric objective type is fatal" {
    # labeler declares "label:string" as its output; using it as the objective
    # must fatal because string is not a numeric type.
    run _spec "label" "true" "" "" labeler --x @sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"string"* ]]
}
