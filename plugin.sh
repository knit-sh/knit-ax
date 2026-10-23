#!/bin/bash
#
# plugin.sh — the knit-ax plugin.
#
# Knit sources this file after it sources knit.sh, so every public knit function
# is available. The plugin registers Bayesian-optimization commands under the
# "ax" namespace, backed by the Ax platform (Meta's adaptive experimentation
# framework). Import it at the top of an experiment, after "source knit.sh":
#
#     source knit.sh
#     knit_import ax               # github.com/knit-sh/knit-ax
#
# knit-ax depends on knit-uv (Python environment management) and requires a
# knit build that includes the Phase-A public search-core API (knit_search_loop,
# knit_search_launch, knit_search_scan, knit_search_resolve_fill,
# knit_search_group_forward, knit_command_outputs, knit_command_table).
#
# The plugin uses only knit's public API (knit_* functions).

# Absolute path to this plugin's own directory, captured at source time so the
# Ax driver script (ax_driver.py) can be located when the coprocess starts,
# regardless of the experiment's working directory.
_KNIT_AX_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

knit_import uv

# ------------------------------------------------------------------------------
# @fn _knit_ax_driver_setup()
#
# Setup body for the private _ax-driver uv environment. The uv directives
# registered below install everything via their own before/after callbacks;
# nothing extra is needed in the body.
# ------------------------------------------------------------------------------
_knit_ax_driver_setup() { :; }

knit_register_setup "_ax-driver" _knit_ax_driver_setup \
    "Internal: Ax BO environment (knit-ax private, not user-facing)."
_knit_is_builtin
# ax_driver.py targets the AxClient service API (ax-platform>=0.4.0), which
# has been stable across the 0.4→1.x→2.x lineage.
knit_with_uv_specs "ax-platform>=0.4.0" "numpy"
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_ax_ensure_driver()
#
# Ensure the _ax-driver setup is built, building it on demand when the
# instance directory does not exist yet. Stores the path to the built
# instance directory in the caller-named variable.
#
# The build runs in a subshell so the venv activation from the uv
# before-callback stays confined and does not leak into the dispatcher
# process (which would spill into every trial).
#
# @param[out] __knit_ret  Name of the variable to hold the instance path.
# @return 0 on success, non-zero on build failure.
# ------------------------------------------------------------------------------
_knit_ax_ensure_driver() {
    local -n __knit_ret=$1
    local prefix
    prefix="$(knit_prefix)"
    # Default setup root is <experiment_root>/setups; strip trailing /.knit
    # from the prefix to recover the experiment root.
    local driver_dir="${prefix%/.knit}/setups/_ax-driver"
    if [[ ! -d "${driver_dir}" ]]; then
        ( knit setup --name _ax-driver -- _ax-driver ) || return 1
    fi
    __knit_ret="${driver_dir}"
}

# Enum type for the optimization sense (minimize / maximize).
knit_enum "ax_sense" "minimize" "maximize"

# Enum type for the on-failure policy (ignore / penalize).
knit_enum "ax_on_failure" "ignore" "penalize"

# Registration of the ax command group. Its subcommands (optimize, and future
# ones) are registered lazily by _knit_ax_discover the first time any of them
# is reached, so sourcing the plugin does not build the subtree up front.
knit_register "ax" knit_empty "Ax Bayesian-optimization commands."
knit_with_subcommand_discovery _knit_ax_discover
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_ax_discover()
#
# Register the ax subcommands. Called lazily the first time a subcommand is
# resolved, listed in "--help", or walked by "describe".
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_ax_discover() {
    knit_register "ax:optimize" _knit_ax_optimize \
        "Run Bayesian optimization over a job or app's parameter space."
    # Recorded options (auto-create columns in the optimizations table).
    knit_with_optional "group:string" "" \
        "Campaign label; recorded and forwarded to submitted jobs."
    knit_with_optional "objective:string" "" \
        "Which declared output to optimize; [table:]<output>. Inferred when the chain has exactly one output."
    knit_with_optional "trials:integer" "" \
        "Total trial budget."
    knit_with_optional "parallel:integer" "1" \
        "Max trials in flight (job mode only; app mode runs sequentially)."
    knit_with_optional "seed:integer" "" \
        "Ax RNG seed; recorded for reproducibility."
    # Control-only options (parsed, validated, shown in help, but not stored).
    knit_with_flag "minimize" \
        "Minimize the objective (default)." --no-record
    knit_with_flag "maximize" \
        "Maximize the objective." --no-record
    knit_with_optional "sobol-trials:integer" "" \
        "Quasi-random exploration trials before the GP model engages." --no-record
    knit_with_optional "resume:string" "" \
        "Continue a prior optimization by its opt-id; with no id resumes the --group campaign." \
        --no-record
    knit_with_optional "on-failure:ax_on_failure" "ignore" \
        "Drop failed trials from the model (ignore) or tell Ax a fixed penalty value (penalize)." \
        --no-record
    knit_with_optional "penalty:real" "" \
        "Objective penalty applied to failed trials when --on-failure is penalize." \
        --no-record
    knit_with_dispatch "downstream" \
        "A knit command (submit or run, with search-syntax values) to optimize over."
    knit_with_table "optimizations"
    # Programmatic output columns set by the body during the campaign.
    knit_with_output "sense:ax_sense" "" \
        "Optimization sense: minimize or maximize."
    knit_with_output "status:string" "" \
        "Campaign status: running, completed, or failed."
    knit_with_output "best_id:string" "" \
        "Row id of the best trial."
    knit_with_output "best_objective:real" "" \
        "Objective value of the best trial."
    knit_done
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_optimize()
#
# Entry point for "ax optimize". Resolves the objective and the search space,
# starts the Ax driver as a coprocess (with its venv activation confined to the
# coprocess subshell), and drives the shared search-core loop: each trial is
# proposed by Ax (ask), launched by the loop, read back (collect), and reported
# to Ax (observe). The downstream dispatcher picks the loop mode — "submit" /
# "prepare" run in job mode, "run" in app mode.
#
# @param[in] ... All arguments as expanded by the CLI framework.
# ------------------------------------------------------------------------------
_knit_ax_optimize() {
    local args=("$@")
    local idx
    idx=$(knit_extra_index "${args[@]}")
    local -a downstream
    downstream=("${args[@]:idx}")
    if [[ ${#downstream[@]} -eq 0 ]]; then
        knit_fatal \
            "ax optimize: a downstream command is required after -- (e.g. \"-- submit -- <job> [OPTS]\")."
    fi

    # --- options ---
    local objective maximize_flag seed sobol trials parallel group
    objective=$(knit_get_parameter "objective" "${args[@]}")     || objective=""
    maximize_flag=$(knit_get_parameter "maximize" "${args[@]}")  || maximize_flag="false"
    seed=$(knit_get_parameter "seed" "${args[@]}")               || seed=""
    sobol=$(knit_get_parameter "sobol-trials" "${args[@]}")      || sobol=""
    trials=$(knit_get_parameter "trials" "${args[@]}")           || trials=""
    parallel=$(knit_get_parameter "parallel" "${args[@]}")       || parallel="1"
    # group/on_failure/penalty are read by the ask/observe callbacks via dynamic
    # scope (the search-core proposer state contract).
    # shellcheck disable=SC2034
    group=$(knit_get_parameter "group" "${args[@]}")             || group=""
    # shellcheck disable=SC2034
    local on_failure penalty
    # shellcheck disable=SC2034
    on_failure=$(knit_get_parameter "on-failure" "${args[@]}")   || on_failure="ignore"
    # shellcheck disable=SC2034
    penalty=$(knit_get_parameter "penalty" "${args[@]}")         || penalty=""

    [[ -z "${objective}" ]] && knit_fatal "ax optimize: --objective is required."
    [[ -z "${trials}" ]] && knit_fatal "ax optimize: --trials is required (the BO trial budget)."

    local minimize="true"
    [[ "${maximize_flag}" == "true" ]] && minimize="false"

    # --- loop mode from the downstream dispatcher ---
    local mangled dispatcher target
    knit_search_resolve_target mangled dispatcher target "${downstream[@]}"
    local mode
    case "${dispatcher}" in
        submit|prepare) mode="job" ;;
        run)            mode="app" ;;
        *) knit_fatal "ax optimize: the downstream must be a 'submit' or 'run' line (got '%s')." "${dispatcher}" ;;
    esac
    if [[ "${mode}" == "app" ]] && (( parallel > 1 )); then
        knit_fatal "ax optimize: --parallel > 1 is not supported in app mode (app trials share one allocation); use --parallel 1."
    fi

    # --- objective table/column (read by _knit_ax_collect via dynamic scope) ---
    # shellcheck disable=SC2034
    local _knit_ax_obj_table _knit_ax_obj_column
    _knit_ax_resolve_objective _knit_ax_obj_table _knit_ax_obj_column \
        "${objective}" "${downstream[@]}"

    # --- search-space spec (MB4); a bad objective/space fatals in the subshell ---
    local spec
    spec=$(_knit_ax_build_spec_json "${objective}" "${minimize}" "${seed}" \
        "${sobol}" "${downstream[@]}") || exit $?

    # --- scan the downstream into a template + the varying-slot map, read by
    # _knit_ax_ask/_knit_ax_reconstruct via dynamic scope ---
    # shellcheck disable=SC2034
    local -a template axes rawtokens
    local -A seen_map
    knit_search_scan template axes rawtokens seen_map "" "${downstream[@]}"
    local -A slot_by_param=()
    local ax_i ax_kind ax_slot ax_name
    # slot_by_param is consumed by _knit_ax_ask through dynamic scope, which the
    # linter cannot see; suppress the unused-variable warning on the fill loop.
    # shellcheck disable=SC2034
    for ((ax_i=0; ax_i<${#axes[@]}; ax_i++)); do
        read -r ax_kind ax_slot ax_name <<< "${axes[ax_i]}"
        case "${ax_kind}" in
            literal|sweep) slot_by_param["${ax_name}"]="${ax_slot}" ;;
        esac
    done

    # --- start the Ax coprocess (activation confined to its subshell) ---
    local driver_prefix
    _knit_ax_ensure_driver driver_prefix \
        || knit_fatal "ax optimize: could not build the _ax-driver environment."
    _knit_ax_start_driver "${driver_prefix}"
    trap '_knit_ax_shutdown' EXIT

    # init the driver with the search-space spec
    local init_req resp
    init_req=$(knit_jq -cn --argjson spec "${spec}" '{cmd:"init",spec:$spec}')
    _knit_ax_rpc resp "${init_req}"

    # --- drive the shared search-core loop ---
    knit_search_loop --mode "${mode}" \
        --ask _knit_ax_ask --collect _knit_ax_collect --observe _knit_ax_observe \
        --parallel "${parallel}" --budget "${trials}"

    # Report the best trial (recorded on the parent row in MB7).
    local best_resp best_obj
    _knit_ax_rpc best_resp '{"cmd":"best"}'
    best_obj=$(knit_jq -r '.best.objective // empty' <<<"${best_resp}")
    [[ -n "${best_obj}" ]] && knit_info "ax optimize: best objective = %s" "${best_obj}"

    _knit_ax_shutdown
    trap - EXIT
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_value_type()
#
# Map a knit parameter type string to the Ax value_type string used in the
# search-space JSON. When the knit type is empty (explicit token with no
# declared type) the function infers from the values: all-integer → "int",
# all-numeric → "float", otherwise "str".
#
# @param[out] __knit_ret Variable to receive the Ax value type ("float", "int",
#   or "str").
# @param[in] knit_type The knit declared type (may be empty).
# @param[in] ... The candidate values (used only when knit_type is empty).
# ------------------------------------------------------------------------------
_knit_ax_value_type() {
    local -n __knit_ret=$1
    local ktype="$2"
    shift 2
    case "${ktype}" in
        real)    __knit_ret="float"; return ;;
        integer) __knit_ret="int";   return ;;
        string)  __knit_ret="str";   return ;;
    esac
    # Empty type or enum: infer from the provided values.
    local all_int="true" all_num="true" v
    for v in "$@"; do
        [[ "${v}" =~ ^-?[0-9]+$ ]] || all_int="false"
        [[ "${v}" =~ ^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || all_num="false"
    done
    if [[ "${all_int}" == "true" && $# -gt 0 ]]; then __knit_ret="int"
    elif [[ "${all_num}" == "true" && $# -gt 0 ]]; then __knit_ret="float"
    else __knit_ret="str"; fi
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_build_spec_json()
#
# Build the Ax search-space JSON spec from the downstream command line. Resolves
# the target command, scans the downstream tokens, classifies each parameter
# (varying vs. fixed), maps each varying parameter to the correct Ax parameter
# type (RangeParameter or ChoiceParameter), validates, and writes the spec JSON
# to stdout. Fatals when no parameter varies or the objective output is not of a
# numeric type.
#
# @param[in] objective The objective output name, possibly "table:name".
# @param[in] minimize "true" to minimize, "false" to maximize.
# @param[in] seed RNG seed (empty → omitted from spec).
# @param[in] sobol_trials Sobol initialization count (empty → omitted).
# @param[in] ... The downstream tokens (after the outer "--").
# ------------------------------------------------------------------------------
_knit_ax_build_spec_json() {
    local objective="$1" minimize="$2" seed="$3" sobol_trials="$4"
    shift 4
    local -a downstream=("$@")

    # 1. Resolve the target command.
    # shellcheck disable=SC2034 # dispatcher is an output slot; only mangled/target used here
    local mangled dispatcher target
    knit_search_resolve_target mangled dispatcher target "${downstream[@]}"
    if [[ -z "${mangled}" ]]; then
        knit_fatal "ax optimize: cannot determine which command to introspect for search-space extraction (no target after --)."
    fi

    # 2. Scan the downstream tokens: template, axes, raw tokens, seen map.
    # shellcheck disable=SC2034 # tmpl is a required output slot; only axes/rawtokens/seen_map used
    local -a tmpl axes rawtokens
    local -A seen_map
    knit_search_scan tmpl axes rawtokens seen_map "" "${downstream[@]}"

    # Build a name→axis-index map for explicit literal-token axes.
    local -A axis_by_param=()
    local i axis_kind aname
    for ((i=0; i<${#axes[@]}; i++)); do
        read -r axis_kind _ aname <<< "${axes[i]}"
        [[ "${axis_kind}" == "literal" ]] && axis_by_param["${aname}"]="${i}"
    done

    # 3. List target parameters and classify each one.
    local -a params ax_params_json=()
    knit_command_parameters params "${mangled}"

    local param token has_domain resolved ptype
    for param in "${params[@]}"; do
        token="${seen_map[${param}]:-unspecified}"

        # Check for a declared domain without calling a private function.
        has_domain="false"
        local dk dt dlo dhi dlog dglob
        # shellcheck disable=SC2034 # dstep is a required output slot; Ax uses bounds not step
        local dstep
        local -a dvals
        if knit_parameter_space dk dt dlo dhi dvals dstep dlog dglob \
                "${mangled}" "${param}"; then
            has_domain="true"
        fi

        knit_search_resolve_fill resolved "sweep" "${token}" "${has_domain}"

        case "${resolved}" in
            default) continue ;;

            explicit)
                # Plain scalar (e.g. --epochs 20) → fixed, skip.
                [[ ! -v axis_by_param["${param}"] ]] && continue

                # Literal token: inspect the raw token to determine Ax type.
                local ai="${axis_by_param[${param}]}"
                local raw="${rawtokens[${ai}]}"
                local -A tok_desc
                local -a tok_vals
                knit_search_parse_token tok_desc tok_vals "${raw}"

                knit_parameter_type ptype "${mangled}" "${param}" || ptype=""

                local pj
                case "${tok_desc[kind]}" in
                    range)
                        local vtype
                        # For [lo..hi] without a type hint, infer from the bounds.
                        _knit_ax_value_type vtype "${ptype}" \
                            "${tok_desc[lo]}" "${tok_desc[hi]}"
                        pj=$(knit_jq -cn \
                            --arg  name  "${param}" \
                            --arg  vtype "${vtype}" \
                            --argjson lo   "${tok_desc[lo]}" \
                            --argjson hi   "${tok_desc[hi]}" \
                            '{"name":$name,"ax":"range","value_type":$vtype,
                              "bounds":[$lo,$hi],"log_scale":false}')
                        ;;
                    list)
                        local vtype ordered
                        _knit_ax_value_type vtype "${ptype}" "${tok_vals[@]}"
                        ordered="false"
                        [[ "${vtype}" == "int" || "${vtype}" == "float" ]] && ordered="true"
                        if [[ "${vtype}" == "str" ]]; then
                            pj=$(knit_jq -cn \
                                --arg  name    "${param}" \
                                --argjson ordered "${ordered}" \
                                '{"name":$name,"ax":"choice","value_type":"str",
                                  "ordered":$ordered,
                                  "values":$ARGS.positional}' \
                                --args "${tok_vals[@]}")
                        else
                            pj=$(knit_jq -cn \
                                --arg  name    "${param}" \
                                --arg  vtype   "${vtype}" \
                                --argjson ordered "${ordered}" \
                                '{"name":$name,"ax":"choice","value_type":$vtype,
                                  "ordered":$ordered,
                                  "values":[$ARGS.positional[]|tonumber]}' \
                                --args "${tok_vals[@]}")
                        fi
                        ;;
                    glob)
                        local had_nullglob="off"
                        shopt -q nullglob && had_nullglob="on"
                        shopt -s nullglob
                        # shellcheck disable=SC2206 # intentional glob expansion
                        local -a gvals=( ${tok_desc[glob]} )
                        [[ "${had_nullglob}" == "off" ]] && shopt -u nullglob
                        if [[ ${#gvals[@]} -eq 0 ]]; then
                            knit_fatal "ax optimize: glob '%s' matched no files." \
                                "${tok_desc[glob]}"
                        fi
                        pj=$(knit_jq -cn \
                            --arg name "${param}" \
                            '{"name":$name,"ax":"choice","value_type":"str",
                              "ordered":false,
                              "values":$ARGS.positional}' \
                            --args "${gvals[@]}")
                        ;;
                esac
                ax_params_json+=("${pj}")
                ;;

            sweep)
                # Use the declared domain from knit_parameter_space.
                local vtype ordered
                _knit_ax_value_type vtype "${dt}" "${dvals[@]}"
                local pj
                case "${dk}" in
                    range)
                        pj=$(knit_jq -cn \
                            --arg  name  "${param}" \
                            --arg  vtype "${vtype}" \
                            --argjson lo   "${dlo}" \
                            --argjson hi   "${dhi}" \
                            --argjson log  "${dlog}" \
                            '{"name":$name,"ax":"range","value_type":$vtype,
                              "bounds":[$lo,$hi],"log_scale":$log}')
                        ;;
                    list)
                        ordered="false"
                        [[ "${vtype}" == "int" || "${vtype}" == "float" ]] && ordered="true"
                        if [[ "${vtype}" == "str" ]]; then
                            pj=$(knit_jq -cn \
                                --arg  name    "${param}" \
                                --argjson ordered "${ordered}" \
                                '{"name":$name,"ax":"choice","value_type":"str",
                                  "ordered":$ordered,
                                  "values":$ARGS.positional}' \
                                --args "${dvals[@]}")
                        else
                            pj=$(knit_jq -cn \
                                --arg  name    "${param}" \
                                --arg  vtype   "${vtype}" \
                                --argjson ordered "${ordered}" \
                                '{"name":$name,"ax":"choice","value_type":$vtype,
                                  "ordered":$ordered,
                                  "values":[$ARGS.positional[]|tonumber]}' \
                                --args "${dvals[@]}")
                        fi
                        ;;
                    glob)
                        local had_nullglob="off"
                        shopt -q nullglob && had_nullglob="on"
                        shopt -s nullglob
                        # shellcheck disable=SC2206 # intentional glob expansion
                        local -a gvals=( ${dglob} )
                        [[ "${had_nullglob}" == "off" ]] && shopt -u nullglob
                        if [[ ${#gvals[@]} -eq 0 ]]; then
                            knit_fatal "ax optimize: glob '%s' matched no files." \
                                "${dglob}"
                        fi
                        pj=$(knit_jq -cn \
                            --arg name "${param}" \
                            '{"name":$name,"ax":"choice","value_type":"str",
                              "ordered":false,
                              "values":$ARGS.positional}' \
                            --args "${gvals[@]}")
                        ;;
                esac
                ax_params_json+=("${pj}")
                ;;
        esac
    done

    # 4. Validate: at least one varying parameter.
    if [[ ${#ax_params_json[@]} -eq 0 ]]; then
        knit_fatal "ax optimize: no parameter varies in the downstream '%s'. Add a search token ({...}, [lo..hi], @sweep) or declare --domain for at least one parameter." \
            "${target}"
    fi

    # 5. Validate: the objective output must be real or integer.
    local obj_name="${objective##*:}"  # strip optional "table:" prefix
    if [[ -n "${obj_name}" ]]; then
        local otype=""
        knit_output_type otype "${mangled}" "${obj_name}" || true
        if [[ -n "${otype}" ]]; then
            case "${otype}" in
                real|integer) ;;
                *)
                    knit_fatal "ax optimize: objective '%s' has type '%s', but the objective must be 'real' or 'integer'." \
                        "${obj_name}" "${otype}"
                    ;;
            esac
        fi
    fi

    # 6. Emit the spec JSON.
    local params_arr
    params_arr=$(printf '%s\n' "${ax_params_json[@]}" | knit_jq -s '.')

    knit_jq -cn \
        --arg  obj_name  "${obj_name}" \
        --argjson minimize "${minimize}" \
        --argjson seed_v   "${seed:-null}" \
        --argjson sobol_v  "${sobol_trials:-null}" \
        --argjson params   "${params_arr}" \
        '{objective:{name:$obj_name,minimize:$minimize},
          seed:$seed_v, sobol_trials:$sobol_v,
          parameters:$params}
         | with_entries(select(.value != null))'
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_resolve_objective()
#
# Resolve which table and column hold the campaign objective, given the
# downstream command line and the --objective spec ("[segment:]<output>"). A
# trial is a chain of segments split on "--" — for Ax, the dispatcher
# (submit/run) and the target (job/app). The objective rarely lives in the
# dispatcher's own table (jobs/runs); it is usually a declared output of the
# target. The resolution follows the design's Objective rules:
#
#   - Default: walk the chain leaf-first (target, then dispatcher) and pick the
#     first segment that declares a knit_with_output of the requested name.
#   - Override: a "segment:" prefix forces the segment whose command display name
#     or table name matches, skipping the walk; the output must be declared there.
#
# Output names and DB columns fold hyphens to underscores, so the resolved column
# is the normalized output name. Fatals when the objective is absent or no
# segment declares it.
#
# @param[out] __knit_ret1 The table that holds the objective.
# @param[out] __knit_ret2 The objective column (normalized output name).
# @param[in] spec The --objective value ("[segment:]<output>").
# @param[in] ... The downstream tokens (after the outer "--").
# ------------------------------------------------------------------------------
_knit_ax_resolve_objective() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local spec="$3"
    shift 3
    local -a downstream=("$@")
    __knit_ret1=""
    __knit_ret2=""

    if [[ -z "${spec}" ]]; then
        knit_fatal "ax optimize: no objective given; pass --objective [table:]<output>."
    fi

    # Split "[segment:]output". Output names never contain ":".
    local seg="" out="${spec}"
    if [[ "${spec}" == *:* ]]; then
        seg="${spec%%:*}"
        out="${spec#*:}"
    fi
    local out_norm="${out//-/_}"
    local seg_norm="${seg//-/_}"

    local mangled dispatcher target
    knit_search_resolve_target mangled dispatcher target "${downstream[@]}"
    if [[ -z "${mangled}" ]]; then
        knit_fatal "ax optimize: cannot resolve the objective's command from the downstream (no target after --)."
    fi

    local target_table dispatcher_table
    knit_command_table target_table "${mangled}"
    knit_command_table dispatcher_table "${dispatcher}"

    # Chain segments, leaf (target) first. A bare command has a single segment
    # (its dispatcher display name equals the target).
    local -a seg_names=("${target}")
    local -a seg_tables=("${target_table}")
    local -a seg_mangled=("${mangled}")
    if [[ "${dispatcher}" != "${target}" ]]; then
        seg_names+=("${dispatcher}")
        seg_tables+=("${dispatcher_table}")
        seg_mangled+=("${dispatcher}")
    fi

    local i chosen=-1 o
    local -a outs
    if [[ -n "${seg}" ]]; then
        # Explicit segment: match by command display name or by table name.
        for ((i=0; i<${#seg_names[@]}; i++)); do
            if [[ "${seg_names[i]//-/_}" == "${seg_norm}" \
                  || "${seg_tables[i]}" == "${seg}" ]]; then
                chosen="${i}"; break
            fi
        done
        if [[ "${chosen}" -lt 0 ]]; then
            knit_fatal "ax optimize: --objective names segment '%s', which is not in the downstream chain." \
                "${seg}"
        fi
        knit_command_outputs outs "${seg_mangled[chosen]}"
        local found="false"
        for o in "${outs[@]}"; do
            [[ "${o}" == "${out_norm}" ]] && found="true" && break
        done
        if [[ "${found}" != "true" ]]; then
            knit_fatal "ax optimize: segment '%s' declares no output '%s'." \
                "${seg}" "${out}"
        fi
    else
        # Default: leaf-first; the first segment that declares the output wins.
        for ((i=0; i<${#seg_names[@]}; i++)); do
            knit_command_outputs outs "${seg_mangled[i]}"
            for o in "${outs[@]}"; do
                [[ "${o}" == "${out_norm}" ]] && { chosen="${i}"; break; }
            done
            [[ "${chosen}" -ge 0 ]] && break
        done
        if [[ "${chosen}" -lt 0 ]]; then
            knit_fatal "ax optimize: no segment in the downstream declares an output '%s'." \
                "${out}"
        fi
    fi

    __knit_ret1="${seg_tables[chosen]}"
    __knit_ret2="${out_norm}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_collect()
#
# The campaign's collector callback for knit_search_loop (the --collect hook):
# read one finished trial's objective by its recorded child row id. The loop runs
# it the moment a trial reaches a terminal state, before observe. The objective's
# table and column are resolved once by _knit_ax_optimize and read here through
# dynamic scope (_knit_ax_obj_table / _knit_ax_obj_column), matching the
# search-core proposer state contract (the sweep reads its policy the same way).
# A missing row or NULL/empty objective (a crashed trial) returns non-zero with an
# empty output, so _knit_ax_observe applies the --on-failure policy.
#
# @param[out] $1 The objective value (empty on failure).
# @param[in] $2 The trial's recorded child row id (from knit_search_launch).
# @return 0 when a non-empty objective was read, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_ax_collect() {
    local -n __knit_ret=$1
    local child_id="$2"
    __knit_ret=""
    # _knit_ax_obj_table / _knit_ax_obj_column come from the enclosing
    # _knit_ax_optimize frame through dynamic scope.
    # shellcheck disable=SC2154
    local tbl="${_knit_ax_obj_table}" col="${_knit_ax_obj_column}"
    local val
    if knit_search_read_objective val "${child_id}" "${tbl}" "${col}"; then
        __knit_ret="${val}"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_start_driver()
#
# Start the Ax driver (ax_driver.py) as a bash coprocess, activating the
# _ax-driver venv ONLY inside the coprocess subshell. The optimize process
# environment stays pristine so the venv never spills into the trials (in-process
# in app mode, or via the scheduler's environment propagation in job mode). The
# coprocess read/write file descriptors and its pid are saved in globals for the
# RPC helper and the shutdown trap.
#
# @param[in] driver_prefix The built _ax-driver instance directory (holds
#   .activate.sh).
# ------------------------------------------------------------------------------
_knit_ax_start_driver() {
    local driver_prefix="$1"
    local plugin_dir="${_KNIT_AX_PLUGIN_DIR}"
    # The activation lives only in this subshell; exec replaces it with python so
    # no activated shell lingers.
    coproc AX_DRIVER {
        # shellcheck disable=SC1091
        source "${driver_prefix}/.activate.sh"
        exec python "${plugin_dir}/ax_driver.py"
    }
    _KNIT_AX_RPC_OUT="${AX_DRIVER[0]}"
    _KNIT_AX_RPC_IN="${AX_DRIVER[1]}"
    _KNIT_AX_COPROC_PID="${AX_DRIVER_PID}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_rpc()
#
# Exchange one request/response with the Ax coprocess: write the request JSON as
# one line to the driver's stdin, read one response line from its stdout. The
# driver's protocol is strictly one response per request and the loop talks to it
# serially (ask then, per finished trial, tell), so no interleaving is possible.
# This is the single seam the unit tests stub to drive the proposer without a
# real Ax process.
#
# @param[out] $1 The response line (JSON).
# @param[in] $2 The request line (JSON).
# ------------------------------------------------------------------------------
_knit_ax_rpc() {
    local -n __knit_ret=$1
    local req="$2"
    printf '%s\n' "${req}" >&"${_KNIT_AX_RPC_IN}"
    IFS= read -r __knit_ret <&"${_KNIT_AX_RPC_OUT}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_shutdown()
#
# Tell the Ax coprocess to shut down and reap it, so no orphan Python process is
# left behind. Idempotent and best-effort: safe to call from the EXIT trap and
# again on the normal path. The driver exits immediately on the shutdown command.
# ------------------------------------------------------------------------------
_knit_ax_shutdown() {
    [[ -z "${_KNIT_AX_COPROC_PID}" ]] && return 0
    { printf '%s\n' '{"cmd":"shutdown"}' >&"${_KNIT_AX_RPC_IN}"; } 2>/dev/null || true
    wait "${_KNIT_AX_COPROC_PID}" 2>/dev/null || true
    _KNIT_AX_COPROC_PID=""
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_reconstruct()
#
# Build one trial's downstream command line from the scan template and Ax's
# proposed parameter values. A varying parameter that appeared as a token on the
# call site (a literal domain or an @sweep marker) has a template slot, so its
# value replaces that slot in place; a parameter that varies only through its
# declared domain (BO's --fill sweep default, no token) has no slot and is
# appended as "--<name> <value>". Parameter names fold hyphens to underscores;
# knit accepts either spelling on the resulting line.
#
# @param[out] $1 The reconstructed argv array.
# @param[in] $2 The proposed parameters as a JSON object ({"name":value,...}).
# @param[in] $3 Name of the scan template array.
# @param[in] $4 Name of the param->slot associative array.
# ------------------------------------------------------------------------------
_knit_ax_reconstruct() {
    # shellcheck disable=SC2178 # nameref output used as an array
    local -n __knit_ret=$1
    local params_json="$2"
    local -n __knit_tmpl=$3
    local -n __knit_slot=$4
    __knit_ret=("${__knit_tmpl[@]}")
    local name value norm
    while IFS=$'\t' read -r name value; do
        [[ -z "${name}" ]] && continue
        norm="${name//-/_}"
        if [[ -v __knit_slot["${norm}"] ]]; then
            __knit_ret["${__knit_slot[${norm}]}"]="${value}"
        else
            __knit_ret+=("--${norm}" "${value}")
        fi
    done < <(knit_jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"${params_json}")
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_ask()
#
# The campaign's ask callback for knit_search_loop (the --ask hook): request the
# next assignment from the Ax coprocess, reconstruct the downstream line with the
# proposed values spliced into the varying slots, splice --group in (job mode),
# and hand back the opaque tag (the Ax trial index) and the argv. The template,
# the param->slot map, and the group come from the enclosing _knit_ax_optimize
# frame through dynamic scope. Returns non-zero when Ax proposes no trial.
#
# @param[out] $1 The trial tag (the Ax trial index).
# @param[out] $2 The reconstructed downstream argv.
# @return 0 when a trial was produced, 1 when none is available.
# ------------------------------------------------------------------------------
_knit_ax_ask() {
    local -n __knit_ret_tag=$1
    # shellcheck disable=SC2178 # nameref output used as an array
    local -n __knit_ret_argv=$2
    local resp
    _knit_ax_rpc resp '{"cmd":"ask","n":1}'
    # Internal locals avoid the names a caller is likely to pass as the output
    # arguments (tag/argv), which would shadow the namerefs above.
    local trial_tag
    trial_tag=$(knit_jq -r '.trials[0].index // empty' <<<"${resp}")
    [[ -z "${trial_tag}" ]] && return 1
    local params
    params=$(knit_jq -c '.trials[0].params' <<<"${resp}")
    local -a trial_argv
    # template / slot_by_param / group come from the enclosing _knit_ax_optimize
    # frame through dynamic scope.
    # shellcheck disable=SC2154
    _knit_ax_reconstruct trial_argv "${params}" template slot_by_param
    # shellcheck disable=SC2154
    knit_search_group_forward trial_argv "${group}"
    __knit_ret_tag="${trial_tag}"
    __knit_ret_argv=("${trial_argv[@]}")
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_observe()
#
# The campaign's observe callback for knit_search_loop (the --observe hook): tell
# Ax one finished trial's outcome. A completed trial with a read objective is told
# as "ok"; a failed trial or a NULL/absent objective applies --on-failure —
# "ignore" tells Ax the trial failed (dropped from the model), "penalize" tells a
# fixed objective value so the model learns to avoid that region. The --on-failure
# policy and the penalty come from the enclosing _knit_ax_optimize frame through
# dynamic scope. Always returns 0: a single bad trial never aborts the campaign.
#
# @param[in] $1 The trial tag (the Ax trial index).
# @param[in] $2 The trial's child row id (unused; the objective arrives in $4).
# @param[in] $3 The trial's terminal status ("completed" or "failed").
# @param[in] $4 The objective value (empty on a failed/NULL trial).
# @return 0 always (continue the campaign).
# ------------------------------------------------------------------------------
_knit_ax_observe() {
    local tag="$1" status="$3" objective="$4"
    local req
    # on_failure / penalty come from the enclosing _knit_ax_optimize frame.
    # shellcheck disable=SC2154
    if [[ "${status}" == "completed" && -n "${objective}" ]]; then
        req=$(knit_jq -cn --argjson i "${tag}" --argjson o "${objective}" \
            '{cmd:"tell",index:$i,objective:$o,status:"ok"}')
    elif [[ "${on_failure}" == "penalize" && -n "${penalty}" ]]; then
        req=$(knit_jq -cn --argjson i "${tag}" --argjson o "${penalty}" \
            '{cmd:"tell",index:$i,objective:$o,status:"penalized"}')
    else
        req=$(knit_jq -cn --argjson i "${tag}" \
            '{cmd:"tell",index:$i,status:"failed"}')
    fi
    local resp
    _knit_ax_rpc resp "${req}"
    return 0
}
