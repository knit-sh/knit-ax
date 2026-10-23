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
# Entry point for "ax optimize". Splits the downstream command off the first
# "--" and fatals when no downstream is given. The Ax optimization loop will be
# wired in later milestones.
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
    # Optimization loop wired in MB6.
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
