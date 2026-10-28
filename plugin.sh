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
# knit build that includes the Phase-A public search-core API. The search-core
# symbols it relies on include knit_search_loop, knit_search_launch,
# knit_search_scan, knit_search_parse_token, knit_search_resolve_fill,
# knit_search_resolve_target, knit_search_read_objective,
# knit_search_group_forward, knit_parameter_space, knit_parameter_type,
# knit_command_parameters, knit_command_outputs, knit_command_table,
# knit_command_run_after and knit_output_type.
#
# The plugin uses only knit's public API (knit_* functions).

# Absolute path to this plugin's own directory, captured at source time so the
# Ax driver script (ax_driver.py) can be located when the coprocess starts,
# regardless of the experiment's working directory.
_KNIT_AX_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

knit_import uv

# A campaign lives on disk under <experiment>/campaigns/<name>/ (a sibling of
# setups/ and jobs/), so it is portable and reproducible. Declare that tree for
# "knit bundle". The glob form (rather than a bare "campaigns") is deliberate: a
# literal required path that does not exist is fatal at bundle time, which would
# break "knit bundle" for an experiment that imports ax but has prepared no
# campaign yet; a glob that matches nothing only warns.
knit_bundle_requires "campaigns/*"

# ------------------------------------------------------------------------------
# @fn _knit_ax_campaigns_root()
#
# Store the absolute path of the experiment's campaigns directory
# (<experiment_root>/campaigns) in the caller-named variable. The default knit
# prefix is <experiment_root>/.knit, so stripping the trailing /.knit recovers
# the experiment root the campaigns tree sits beside.
#
# @param[out] __knit_ret Name of the variable to hold the campaigns root path.
# ------------------------------------------------------------------------------
_knit_ax_campaigns_root() {
    local -n __knit_ret=$1
    local prefix
    prefix="$(knit_prefix)"
    __knit_ret="${prefix%/.knit}/campaigns"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_campaign_dir()
#
# Store the absolute path of one campaign's directory
# (<experiment_root>/campaigns/<name>) in the caller-named variable.
#
# @param[out] __knit_ret Name of the variable to hold the campaign directory.
# @param[in] name The campaign name.
# ------------------------------------------------------------------------------
_knit_ax_campaign_dir() {
    local -n __knit_ret=$1
    local name="$2"
    local root
    _knit_ax_campaigns_root root
    __knit_ret="${root}/${name}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_campaign_progress()
#
# Read a campaign's recorded progress from its on-disk result.json (written by
# "ax optimize" at the end of each run): the number of trials done and the best
# objective value so far. Both outputs are empty when the campaign has no
# result.json yet (prepared but never run). "ax list" and "ax show" read this
# rather than the database, so they need no Ax process and no SQL.
#
# @param[out] __knit_ret1 Trials done so far (empty when unknown).
# @param[out] __knit_ret2 Best objective value so far (empty when unknown).
# @param[in] name The campaign name.
# ------------------------------------------------------------------------------
_knit_ax_campaign_progress() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local name="$3"
    __knit_ret1=""
    __knit_ret2=""
    local dir
    _knit_ax_campaign_dir dir "${name}"
    local result="${dir}/result.json"
    [[ -f "${result}" ]] || return 0
    local json
    json="$(<"${result}")"
    __knit_ret1=$(knit_jq -r '.trials_done // ""' <<<"${json}")
    __knit_ret2=$(knit_jq -r '.best.objective // ""' <<<"${json}")
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_mode_from_downstream()
#
# Resolve the search-loop mode from the downstream command line's dispatcher:
# "submit"/"prepare" run one scheduler job per trial (job mode), "run" runs one
# app per trial inside the current allocation (app mode). Any other leading
# dispatcher is a fatal. Stores "job" or "app" in the caller-named variable.
#
# @param[out] __knit_ret Name of the variable to hold the mode ("job"/"app").
# @param[in] ... The downstream tokens (after the outer "--").
# ------------------------------------------------------------------------------
_knit_ax_mode_from_downstream() {
    local -n __knit_ret=$1
    shift
    # shellcheck disable=SC2034 # mangled/target are unused here; only dispatcher
    local mangled dispatcher target
    knit_search_resolve_target mangled dispatcher target "$@"
    case "${dispatcher}" in
        submit|prepare) __knit_ret="job" ;;
        run)            __knit_ret="app" ;;
        *) knit_fatal "ax: the downstream must be a 'submit' or 'run' line (got '%s')." "${dispatcher}" ;;
    esac
}

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
# ax_driver.py targets the AxClient service API (ax-platform>=0.4.0), which has
# been stable across the 0.4→1.x→2.x lineage. A full manifest (rather than the
# knit_with_uv_specs sugar) is used to pin requires-python to the 3.12 line.
#
# The window is bounded on BOTH sides on purpose. The floor keeps it off Python
# the dependencies reject (every ax-platform that satisfies the version floor
# needs >=3.10, the current line needs >=3.11), so a host 3.9 — common on login
# nodes and CI images — cannot resolve it; pinning here makes uv fetch a managed
# interpreter instead. The ceiling keeps it off Python too NEW for the native
# wheels: with only an open floor, uv (which builds on managed interpreters, see
# knit-uv) picks the newest managed CPython, and PyTorch — pulled in by
# ax-platform via botorch — publishes no wheels for a just-released Python
# (e.g. torch has no 3.15 wheel), so the sync fails "no wheel for the current
# platform". 3.12 is a well-supported PyTorch target with wheels on every
# platform knit runs on.
knit_with_uv_env <<'EOF'
[project]
name = "knit-ax-driver"
version = "1.0.0"
requires-python = ">=3.12,<3.13"
dependencies = [
    "ax-platform>=0.4.0",
    "numpy",
]
EOF
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_ax_ensure_driver()
#
# Ensure the _ax-driver setup is built, building it on demand when the
# instance directory does not exist yet. Stores the path to the built
# instance directory in the caller-named variable.
#
# When the environment is missing, the build is announced with knit_info and its
# output is wrapped in a frame (knit_framed_run), so the long uv install does not
# dump raw output; the frame shows live only at trace level and closes afterward,
# matching how the rest of knit provisions. knit_framed_run runs the build as the
# first stage of a pipe, i.e. in a subshell, so the venv activation from the uv
# before-callback stays confined and does not leak into the dispatcher process
# (which would spill into every trial).
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
        knit_info "ax: installing the Ax driver environment (one-time; this may take a few minutes)..."
        knit_framed_run "ax: install Ax driver environment" \
            knit setup --name _ax-driver -- _ax-driver || return 1
        knit_info "ax: Ax driver environment ready."
    fi
    __knit_ret="${driver_dir}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_build_driver_at_bootstrap()
#
# Build the private _ax-driver environment at bootstrap, on the login node where
# the network is reachable, rather than lazily on the first "ax optimize". In app
# mode "ax optimize" runs from inside a job body on a compute node, which often
# has no outbound network; an on-demand build there would fail, so the Ax
# environment must already exist before the job starts. Building it at bootstrap
# (a login-node step) guarantees that.
#
# Best-effort: a failed build warns rather than failing the whole bootstrap, and
# _knit_ax_ensure_driver still rebuilds on demand from "ax optimize" as a
# fallback (for an experiment bootstrapped before it imported ax, say).
# ------------------------------------------------------------------------------
_knit_ax_build_driver_at_bootstrap() {
    local prefix
    _knit_ax_ensure_driver prefix \
        || knit_warning "ax: could not pre-build the _ax-driver environment at bootstrap; it will be built on first 'ax optimize'."
}

# Run the pre-build after every "bootstrap" (the uv binary the driver needs is
# provisioned by bootstrap itself, so this runs once that is in place).
knit_command_run_after "bootstrap" _knit_ax_build_driver_at_bootstrap

# Enum type for the optimization sense (minimize / maximize).
knit_enum "ax_sense" "minimize" "maximize"

# Enum type for the on-failure policy (ignore / penalize).
knit_enum "ax_on_failure" "ignore" "penalize"

# Registration of the ax command group. Its subcommands (prepare, optimize,
# list, show) are registered lazily by _knit_ax_discover the first time any of
# them is reached, so sourcing the plugin does not build the subtree up front.
knit_register "ax" knit_empty "Ax Bayesian-optimization commands."
knit_with_subcommand_discovery _knit_ax_discover
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_ax_discover()
#
# Register the ax subcommands. Called lazily the first time a subcommand is
# resolved, listed in "--help", or walked by "describe". The surface is a
# prepare -> optimize split over first-class, named, on-disk campaigns, mirroring
# knit's own prepare -> submit drain: "ax prepare" defines and records a campaign
# (running nothing), "ax optimize" starts or resumes its ask/tell loop, and
# "ax list" / "ax show" report status. A campaign is addressed by --campaign
# <name> and stored under campaigns/<name>/.
#
# @param[in] parent The parent command's display name (unused).
# ------------------------------------------------------------------------------
_knit_ax_discover() {
    # --- ax prepare: define and record a campaign (runs no trials) -----------
    knit_register "ax:prepare" _knit_ax_prepare \
        "Define and record a Bayesian-optimization campaign (runs no trials)."
    # prepare records the campaign's "optimizations" data row (its id is the
    # campaign name) but is transparent to the provenance graph: the trials that
    # "ax optimize" launches later carry the only call edges into that node.
    knit_without_provenance
    # The campaign identity and the trial-job group stamp (jobs.group = <name>).
    # Unique: prepare fatals if campaigns/<name>/ already exists. Recorded.
    knit_with_required "campaign:string" \
        "Campaign name: the campaigns/<name>/ directory and the trial-job group stamp (must be unique)."
    # Recorded options (auto-create columns in the optimizations table).
    knit_with_optional "objective:string" "" \
        "Which declared output to optimize; [table:]<output>."
    knit_with_optional "trials:integer" "" \
        "Total trial budget."
    knit_with_optional "parallel:integer" "1" \
        "Max trials in flight (job mode only; app mode runs sequentially)."
    knit_with_optional "seed:integer" "" \
        "Ax RNG seed; recorded for reproducibility."
    # Control-only options (parsed, validated, shown in help, stored in the
    # campaign's definition.json rather than as table columns).
    knit_with_flag "minimize" \
        "Minimize the objective (default)." --no-record
    knit_with_flag "maximize" \
        "Maximize the objective." --no-record
    knit_with_optional "sobol-trials:integer" "" \
        "Quasi-random exploration trials before the GP model engages." --no-record
    knit_with_optional "on-failure:ax_on_failure" "ignore" \
        "Drop failed trials from the model (ignore) or tell Ax a fixed penalty value (penalize)." \
        --no-record
    knit_with_optional "penalty:real" "" \
        "Objective penalty applied to failed trials when --on-failure is penalize." \
        --no-record
    knit_with_dispatch "downstream" \
        "A knit command (submit or run, with search-syntax values) to optimize over."
    knit_with_table "optimizations"
    # Programmatic output columns: set at prepare (sense/status) and updated by
    # "ax optimize" on the same row as the campaign progresses.
    knit_with_output "sense:ax_sense" "" \
        "Optimization sense: minimize or maximize."
    knit_with_output "status:string" "" \
        "Campaign status: prepared, running, completed, or failed."
    knit_with_output "best_id:string" "" \
        "Row id of the best trial."
    knit_with_output "best_objective:real" "" \
        "Objective value of the best trial."
    knit_done

    # --- ax optimize: start or resume the loop for a prepared campaign -------
    knit_register "ax:optimize" _knit_ax_optimize \
        "Start or resume Bayesian optimization for a prepared campaign."
    # A control command: it re-attaches to the campaign's existing optimizations
    # row (it records no row of its own), so it stays out of the provenance graph.
    knit_without_provenance
    knit_with_required "campaign:string" \
        "The campaign to run or resume (its campaigns/<name>/ directory must exist)."
    knit_done

    # --- ax list: one line per campaign --------------------------------------
    knit_register "ax:list" _knit_ax_list \
        "List Bayesian-optimization campaigns."
    knit_without_provenance
    knit_with_flag "verbose" \
        "Also show each campaign's objective and command." --no-record
    knit_done

    # --- ax show: one campaign's detail --------------------------------------
    knit_register "ax:show" _knit_ax_show \
        "Show one Bayesian-optimization campaign's detail."
    knit_without_provenance
    knit_with_required "campaign:string" \
        "The campaign to show."
    knit_done
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_prepare()
#
# Entry point for "ax prepare". Validates the request, resolves the objective and
# builds the Ax search-space spec eagerly (so a bad objective or an empty space
# fails now, not at run time), then writes the campaign to disk under
# campaigns/<name>/ and records its "optimizations" row. It runs no trials. The
# campaign name is unique: a pre-existing campaigns/<name>/ is a fatal.
#
# The downstream line and every knob are persisted in definition.json, the
# portable source of truth that "ax optimize" replays. The row's id is the
# campaign name (set with knit_set_row_id), so "ax optimize" can re-attach to the
# same row by id and the trials can call-edge to it.
#
# @param[in] ... All arguments as expanded by the CLI framework.
# ------------------------------------------------------------------------------
_knit_ax_prepare() {
    local args=("$@")
    local idx
    idx=$(knit_extra_index "${args[@]}")
    local -a downstream
    downstream=("${args[@]:idx}")
    if [[ ${#downstream[@]} -eq 0 ]]; then
        knit_fatal \
            "ax prepare: a downstream command is required after -- (e.g. \"-- submit -- <job> [OPTS]\")."
    fi

    # --- options ---
    local campaign objective maximize_flag seed sobol trials parallel
    local on_failure penalty
    campaign=$(knit_get_parameter "campaign" "${args[@]}")
    objective=$(knit_get_parameter "objective" "${args[@]}")     || objective=""
    maximize_flag=$(knit_get_parameter "maximize" "${args[@]}")  || maximize_flag="false"
    seed=$(knit_get_parameter "seed" "${args[@]}")               || seed=""
    sobol=$(knit_get_parameter "sobol-trials" "${args[@]}")      || sobol=""
    trials=$(knit_get_parameter "trials" "${args[@]}")           || trials=""
    parallel=$(knit_get_parameter "parallel" "${args[@]}")       || parallel="1"
    on_failure=$(knit_get_parameter "on-failure" "${args[@]}")   || on_failure="ignore"
    penalty=$(knit_get_parameter "penalty" "${args[@]}")         || penalty=""

    [[ -z "${objective}" ]] && knit_fatal "ax prepare: --objective is required."
    [[ -z "${trials}" ]] && knit_fatal "ax prepare: --trials is required (the BO trial budget)."
    (( trials > 0 )) || knit_fatal "ax prepare: --trials must be a positive integer (got '%s')." "${trials}"
    (( parallel > 0 )) || knit_fatal "ax prepare: --parallel must be a positive integer (got '%s')." "${parallel}"
    if [[ "${on_failure}" == "penalize" && -z "${penalty}" ]]; then
        knit_fatal "ax prepare: --on-failure penalize requires --penalty <value> (the objective value told to Ax for a failed trial)."
    fi

    local minimize="true"
    [[ "${maximize_flag}" == "true" ]] && minimize="false"
    local sense="minimize"
    [[ "${minimize}" == "false" ]] && sense="maximize"

    # --- loop mode (for the app-mode --parallel guard; fail fast at prepare) ---
    local mode
    _knit_ax_mode_from_downstream mode "${downstream[@]}"
    if [[ "${mode}" == "app" ]] && (( parallel > 1 )); then
        knit_fatal "ax prepare: --parallel > 1 is not supported in app mode (app trials share one allocation); use --parallel 1."
    fi

    # --- resolve the objective and build the spec now, so errors surface here ---
    # shellcheck disable=SC2034 # obj_table/obj_column prove the objective resolves
    local obj_table obj_column
    _knit_ax_resolve_objective obj_table obj_column "${objective}" "${downstream[@]}"
    local spec
    spec=$(_knit_ax_build_spec_json "${objective}" "${minimize}" "${seed}" \
        "${sobol}" "${downstream[@]}") || exit $?

    # --- create the campaign directory (no-clobber) ---
    local dir
    _knit_ax_campaign_dir dir "${campaign}"
    if [[ -e "${dir}" ]]; then
        knit_fatal "ax prepare: campaign '%s' already exists (%s); choose another --campaign name." \
            "${campaign}" "${dir}"
    fi
    mkdir -p "${dir}" \
        || knit_fatal "ax prepare: could not create campaign directory '%s'." "${dir}"

    # --- write the portable definition and the status marker ---
    # Build the downstream argv array from a NUL-delimited stream rather than
    # jq's --args: --args treats a bare "--" as its own end-of-arguments marker
    # and silently drops it, which would lose the inner "-- <job>" separator a
    # "submit -- <job>" / "run -- <app>" line depends on.
    # "printf '%s\0'" leaves a trailing NUL after the last token. jq 1.7
    # splits that into a trailing empty element (so a blind "[:-1]" drops it),
    # but jq 1.6 (the system jq on many clusters) does NOT, so "[:-1]" there
    # chops the real last token (e.g. a parameter's "@sweep"). Drop the trailing
    # element only when it is the empty artifact, so both jq versions agree.
    local downstream_json
    downstream_json=$(printf '%s\0' "${downstream[@]}" \
        | knit_jq -Rsc 'split("\u0000") | if (length > 0 and .[-1] == "") then .[:-1] else . end')
    # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
    knit_jq -n \
        --arg  campaign  "${campaign}" \
        --arg  objective "${objective}" \
        --argjson minimize "${minimize}" \
        --arg  sense     "${sense}" \
        --argjson trials   "${trials}" \
        --argjson parallel "${parallel}" \
        --argjson seed     "${seed:-null}" \
        --argjson sobol    "${sobol:-null}" \
        --arg  on_failure "${on_failure}" \
        --argjson penalty  "${penalty:-null}" \
        --arg  opt_id    "${campaign}" \
        --argjson downstream "${downstream_json}" \
        '{campaign:$campaign, objective:$objective, minimize:$minimize,
          sense:$sense, trials:$trials, parallel:$parallel, seed:$seed,
          sobol_trials:$sobol, on_failure:$on_failure, penalty:$penalty,
          downstream:$downstream, opt_id:$opt_id}' > "${dir}/definition.json"
    printf 'prepared\n' > "${dir}/status"

    # --- record the optimizations row under the campaign id ---
    # The campaign name is the row id (and the opt-id), so "ax optimize" can
    # re-attach to this row and the trials can call-edge to it. campaign /
    # objective / trials / parallel / seed are auto-recorded from the options
    # above; sense and status are set here.
    knit_set_row_id "${campaign}"
    knit_output "sense" "${sense}"
    knit_output "status" "prepared"

    knit_info "ax prepare: campaign '%s' prepared (%s trials, objective '%s', %s)." \
        "${campaign}" "${trials}" "${objective}" "${sense}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_optimize()
#
# Entry point for "ax optimize". Reads a prepared campaign's definition, starts
# the Ax driver as a coprocess (with its venv activation confined to the
# coprocess subshell), and drives the shared search-core loop: each trial is
# proposed by Ax (ask), launched by the loop, read back (collect), and reported
# to Ax (observe). The first call and every resume are the same operation — the
# loop runs from wherever the campaign's state.json sits (0 trials the first
# time, K later), for the remaining budget. At budget it is a no-op.
#
# The campaign's optimizations row is updated in place (by the campaign id, with
# knit_db_update_row) as the run progresses: status running -> completed/failed,
# plus best_id/best_objective. Each trial carries an automatic "call" edge from
# that row, stamped through the public KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND
# context (ax optimize records no row of its own and is transparent to the graph,
# so the campaign node is the trials' in-graph source).
#
# @param[in] ... All arguments as expanded by the CLI framework.
# ------------------------------------------------------------------------------
_knit_ax_optimize() {
    local campaign
    campaign=$(knit_get_parameter "campaign" "$@")

    local dir
    _knit_ax_campaign_dir dir "${campaign}"
    if [[ ! -d "${dir}" ]]; then
        knit_fatal "ax optimize: no campaign '%s' (%s). Run 'ax prepare --campaign %s -- <downstream>' first." \
            "${campaign}" "${dir}" "${campaign}"
    fi
    local deffile="${dir}/definition.json"
    [[ -f "${deffile}" ]] \
        || knit_fatal "ax optimize: campaign '%s' has no definition.json." "${campaign}"

    # --- read back the stored definition ---
    local def
    def="$(<"${deffile}")"
    local objective minimize trials parallel seed sobol
    # on_failure / penalty are read by _knit_ax_observe via dynamic scope.
    # shellcheck disable=SC2034
    local on_failure penalty
    # Join on a non-whitespace delimiter (SOH, ): a whitespace delimiter
    # such as a tab is collapsed by "read", so an empty seed/sobol field would
    # shift every later field left (e.g. on_failure landing in seed).
    IFS=$'\001' read -r objective minimize trials parallel seed sobol on_failure penalty \
        < <(knit_jq -r '[ .objective, (.minimize|tostring), (.trials|tostring),
                          (.parallel|tostring), ((.seed // "")|tostring),
                          ((.sobol_trials // "")|tostring), .on_failure,
                          ((.penalty // "")|tostring) ] | join("\u0001")' <<<"${def}")
    local -a downstream
    mapfile -t downstream < <(knit_jq -r '.downstream[]' <<<"${def}")

    # --- loop mode ---
    local mode
    _knit_ax_mode_from_downstream mode "${downstream[@]}"
    if [[ "${mode}" == "app" ]] && (( parallel > 1 )); then
        knit_fatal "ax optimize: --parallel > 1 is not supported in app mode; re-prepare the campaign with --parallel 1."
    fi

    # --- objective table/column (read by _knit_ax_collect via dynamic scope) ---
    # shellcheck disable=SC2034
    local _knit_ax_obj_table _knit_ax_obj_column
    _knit_ax_resolve_objective _knit_ax_obj_table _knit_ax_obj_column \
        "${objective}" "${downstream[@]}"

    # --- search-space spec (used on a fresh campaign's init) ---
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
    # shellcheck disable=SC2034
    for ((ax_i=0; ax_i<${#axes[@]}; ax_i++)); do
        read -r ax_kind ax_slot ax_name <<< "${axes[ax_i]}"
        case "${ax_kind}" in
            literal|sweep) slot_by_param["${ax_name}"]="${ax_slot}" ;;
        esac
    done

    # The campaign name is the trial-job group stamp (read by _knit_ax_ask).
    # shellcheck disable=SC2034
    local group="${campaign}"
    # Trial index -> child row id, filled by _knit_ax_observe (dynamic scope) and
    # read after the loop to record best_id (Ax's "best" gives only its own index).
    local -A _knit_ax_trial_row=()

    # --- start the Ax coprocess (activation confined to its subshell) ---
    local driver_prefix
    _knit_ax_ensure_driver driver_prefix \
        || knit_fatal "ax optimize: could not build the _ax-driver environment."
    local driver_log="${dir}/ax-driver.log"
    _knit_ax_start_driver "${driver_prefix}" "${driver_log}"
    # Reap the coprocess on a normal exit and also on an interrupt or a walltime
    # kill (SIGINT/SIGTERM), so the graceful shutdown+wait is never skipped. The
    # signal handler exits (143) so the loop does not resume against a dead
    # coprocess; the EXIT trap is cleared first to avoid a double shutdown.
    trap '_knit_ax_shutdown' EXIT
    trap '_knit_ax_shutdown; trap - EXIT; exit 143' INT TERM

    # --- init a fresh campaign, or resume from its persisted state ---
    local state_path="${dir}/state.json"
    local resp done_trials op
    if [[ -f "${state_path}" ]]; then
        op="resume"
        local resume_req
        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
        resume_req=$(knit_jq -cn --arg p "${state_path}" \
            '{cmd:"resume",path:$p,state_path:$p}')
        _knit_ax_rpc resp "${resume_req}"
    else
        op="initialize"
        local init_req
        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
        init_req=$(knit_jq -cn --argjson spec "${spec}" --arg sp "${state_path}" \
            '{cmd:"init",spec:$spec,state_path:$sp}')
        _knit_ax_rpc resp "${init_req}"
    fi
    # Fail loudly if the driver could not init/resume: a non-ok response has no
    # usable n_trials, and silently treating it as 0 would re-run the whole
    # budget on top of a campaign's already-recorded trials.
    if [[ "$(knit_jq -r '.status // "error"' <<<"${resp}")" != "ok" ]]; then
        knit_fatal "ax optimize: the Ax driver failed to %s campaign '%s': %s (see %s)" \
            "${op}" "${campaign}" "$(knit_jq -r '.error // "unknown error"' <<<"${resp}")" \
            "${driver_log}"
    fi
    done_trials=$(knit_jq -r '.n_trials // 0' <<<"${resp}")

    # --- already at budget: nothing to do ---
    if (( done_trials >= trials )); then
        knit_info "ax optimize: campaign '%s' already at budget (%s/%s); nothing to do." \
            "${campaign}" "${done_trials}" "${trials}"
        _knit_ax_finish "${dir}" "${campaign}" "completed" "${done_trials}"
        _knit_ax_shutdown
        trap - EXIT INT TERM
        return 0
    fi
    local remaining=$(( trials - done_trials ))

    printf 'running\n' > "${dir}/status"
    knit_db_update_row "optimizations" "${campaign}" "status=running"

    # --- drive the shared search-core loop for the remaining budget ---
    # Stamp the trials' provenance source as the campaign row through the public
    # KNIT_SOURCE_ID / KNIT_SOURCE_COMMAND context, so each trial gets a "call"
    # edge from the optimizations node. Saved and restored around the loop so the
    # context does not leak into anything this process runs afterwards (e.g. a job
    # body that drives the loop and then runs more commands).
    local _saved_src_id="${KNIT_SOURCE_ID:-}" _saved_src_cmd="${KNIT_SOURCE_COMMAND:-}"
    export KNIT_SOURCE_ID="${campaign}" KNIT_SOURCE_COMMAND="ax optimize"
    local loop_status=0
    knit_search_loop --mode "${mode}" \
        --ask _knit_ax_ask --collect _knit_ax_collect --observe _knit_ax_observe \
        --parallel "${parallel}" --budget "${remaining}" || loop_status=$?
    export KNIT_SOURCE_ID="${_saved_src_id}" KNIT_SOURCE_COMMAND="${_saved_src_cmd}"

    # --- resolve the best trial and record the final campaign state ---
    local best_resp best_obj best_idx best_id="" total_done
    _knit_ax_rpc best_resp '{"cmd":"best"}'
    best_obj=$(knit_jq -r '.best.objective // empty' <<<"${best_resp}")
    best_idx=$(knit_jq -r '.best.index // empty' <<<"${best_resp}")
    total_done=$(knit_jq -r '.n_trials // 0' <<<"${best_resp}")
    if [[ -n "${best_idx}" && -v _knit_ax_trial_row["${best_idx}"] ]]; then
        best_id="${_knit_ax_trial_row[${best_idx}]}"
    fi

    local final_status="completed"
    (( loop_status != 0 )) && final_status="failed"
    _knit_ax_finish "${dir}" "${campaign}" "${final_status}" "${total_done}" \
        "${best_id}" "${best_idx}" "${best_obj}"
    [[ -n "${best_obj}" ]] \
        && knit_info "ax optimize: best objective = %s (trial %s)." "${best_obj}" "${best_idx}"

    _knit_ax_shutdown
    trap - EXIT INT TERM
    return "${loop_status}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_finish()
#
# Record a campaign's final state at the end of an "ax optimize" run, in both
# places a campaign lives: the on-disk mirror (the status file and result.json,
# which "ax list"/"ax show" read without a database or an Ax process) and the
# optimizations DB row (updated by campaign id, the provenance graph node queried
# by "knit query"). Both are written so a resumed run and a completed run leave a
# consistent record.
#
# @param[in] dir       The campaign directory.
# @param[in] campaign  The campaign name (the row id).
# @param[in] status    Final status ("completed" or "failed").
# @param[in] trials_done Trials recorded in the Ax experiment so far.
# @param[in] best_id   Row id of the best trial (empty when none).
# @param[in] best_idx  Ax trial index of the best trial (empty when none).
# @param[in] best_obj  Objective value of the best trial (empty when none).
# ------------------------------------------------------------------------------
_knit_ax_finish() {
    local dir="$1" campaign="$2" status="$3" trials_done="$4"
    local best_id="${5:-}" best_idx="${6:-}" best_obj="${7:-}"
    printf '%s\n' "${status}" > "${dir}/status"
    # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
    knit_jq -n \
        --argjson trials_done "${trials_done:-0}" \
        --argjson bidx "${best_idx:-null}" \
        --argjson bobj "${best_obj:-null}" \
        --arg  bid  "${best_id}" \
        '{trials_done:$trials_done, best:{index:$bidx, objective:$bobj, id:$bid}}' \
        > "${dir}/result.json"
    knit_db_update_row "optimizations" "${campaign}" \
        "status=${status}" "best_id=${best_id}" "best_objective=${best_obj}"
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_list()
#
# Entry point for "ax list". Prints one line per campaign under campaigns/ — its
# name, status, trials-done/budget, and current best — read entirely from the
# campaign directories (no Ax process, no database). With --verbose it also prints
# each campaign's objective/sense and its stored command line.
#
# @param[in] ... All arguments as expanded by the CLI framework.
# ------------------------------------------------------------------------------
_knit_ax_list() {
    local verbose
    verbose=$(knit_get_parameter "verbose" "$@") || verbose="false"

    local root
    _knit_ax_campaigns_root root
    local found="false" dir name status def budget objective sense
    local done_n best
    for dir in "${root}"/*/; do
        [[ -d "${dir}" ]] || continue
        dir="${dir%/}"
        found="true"
        name="${dir##*/}"
        status="unknown"
        [[ -f "${dir}/status" ]] && status="$(<"${dir}/status")"
        def=""; budget=""; objective=""; sense=""
        if [[ -f "${dir}/definition.json" ]]; then
            def="$(<"${dir}/definition.json")"
            IFS=$'\t' read -r budget objective sense \
                < <(knit_jq -r '[ ((.trials // "")|tostring), (.objective // ""),
                                  (.sense // "") ] | @tsv' <<<"${def}")
        fi
        _knit_ax_campaign_progress done_n best "${name}"
        printf '%-24s  %-10s  %s/%s  best=%s\n' \
            "${name}" "${status}" "${done_n:-0}" "${budget:-?}" "${best:-—}"
        if [[ "${verbose}" == "true" && -n "${def}" ]]; then
            local -a ds
            mapfile -t ds < <(knit_jq -r '.downstream[]' <<<"${def}")
            printf '    objective: %s (%s)\n' "${objective}" "${sense}"
            printf '    command:   %s\n' "${ds[*]}"
        fi
    done
    [[ "${found}" == "false" ]] && knit_info "ax list: no campaigns yet."
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_show()
#
# Entry point for "ax show". Prints one campaign's detail — the stored command,
# status, objective/sense, trials-done/budget, parallelism, seed, current best,
# and opt-id — read from its campaign directory (no Ax process, no database).
#
# @param[in] ... All arguments as expanded by the CLI framework.
# ------------------------------------------------------------------------------
_knit_ax_show() {
    local campaign
    campaign=$(knit_get_parameter "campaign" "$@")

    local dir
    _knit_ax_campaign_dir dir "${campaign}"
    [[ -d "${dir}" ]] || knit_fatal "ax show: no campaign '%s' (%s)." "${campaign}" "${dir}"
    local deffile="${dir}/definition.json"
    [[ -f "${deffile}" ]] || knit_fatal "ax show: campaign '%s' has no definition.json." "${campaign}"

    local def
    def="$(<"${deffile}")"
    local status="unknown"
    [[ -f "${dir}/status" ]] && status="$(<"${dir}/status")"
    local objective sense trials parallel seed opt_id
    IFS=$'\t' read -r objective sense trials parallel seed opt_id \
        < <(knit_jq -r '[ .objective, .sense, (.trials|tostring),
                          (.parallel|tostring), ((.seed // "")|tostring),
                          .opt_id ] | @tsv' <<<"${def}")
    local -a ds
    mapfile -t ds < <(knit_jq -r '.downstream[]' <<<"${def}")
    local done_n best
    _knit_ax_campaign_progress done_n best "${campaign}"

    printf 'campaign:   %s\n' "${campaign}"
    printf 'status:     %s\n' "${status}"
    printf 'objective:  %s (%s)\n' "${objective}" "${sense}"
    printf 'trials:     %s/%s\n' "${done_n:-0}" "${trials}"
    printf 'parallel:   %s\n' "${parallel}"
    [[ -n "${seed}" ]] && printf 'seed:       %s\n' "${seed}"
    printf 'best:       %s\n' "${best:-—}"
    printf 'opt-id:     %s\n' "${opt_id}"
    printf 'command:    %s\n' "${ds[*]}"
    return 0
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
# @fn _knit_ax_choice_json()
#
# Build a ChoiceParameter JSON object for parameter <name> of value type
# <vtype> over the given candidate values. Numeric types ("int"/"float") are
# ordered and their values emitted as JSON numbers; "str" is unordered and its
# values emitted verbatim.
#
# @param[out] 1 The variable receiving the JSON object.
# @param[in] name The parameter name.
# @param[in] vtype The Ax value type ("int", "float", or "str").
# @param[in] ... The candidate values.
# ------------------------------------------------------------------------------
_knit_ax_choice_json() {
    local -n __knit_ret=$1
    local name="$2" vtype="$3"
    shift 3
    local ordered="false"
    [[ "${vtype}" == "int" || "${vtype}" == "float" ]] && ordered="true"
    if [[ "${vtype}" == "str" ]]; then
        # shellcheck disable=SC2016 # $ARGS/$name are jq variables, not shell
        __knit_ret=$(knit_jq -cn \
            --arg     name    "${name}" \
            --argjson ordered "${ordered}" \
            '{"name":$name,"ax":"choice","value_type":"str",
              "ordered":$ordered,
              "values":$ARGS.positional}' \
            --args "$@")
    else
        # shellcheck disable=SC2016 # $ARGS/$name/$vtype are jq variables, not shell
        __knit_ret=$(knit_jq -cn \
            --arg     name    "${name}" \
            --arg     vtype   "${vtype}" \
            --argjson ordered "${ordered}" \
            '{"name":$name,"ax":"choice","value_type":$vtype,
              "ordered":$ordered,
              "values":[$ARGS.positional[]|tonumber]}' \
            --args "$@")
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_ax_glob_values()
#
# Expand the shell glob <pattern> into the array variable named by <out>, with
# nullglob temporarily enabled so a non-matching pattern yields no entries
# rather than the literal pattern. Fatals when the pattern matches no files.
#
# @param[out] 1 The array variable receiving the matched paths.
# @param[in] pattern The glob pattern to expand.
# ------------------------------------------------------------------------------
_knit_ax_glob_values() {
    # shellcheck disable=SC2178 # nameref output used as an array
    local -n __knit_ret_vals=$1
    local pattern="$2"
    local had_nullglob="off"
    shopt -q nullglob && had_nullglob="on"
    shopt -s nullglob
    # shellcheck disable=SC2206 # intentional glob expansion
    __knit_ret_vals=( ${pattern} )
    [[ "${had_nullglob}" == "off" ]] && shopt -u nullglob
    if [[ ${#__knit_ret_vals[@]} -eq 0 ]]; then
        knit_fatal "ax optimize: glob '%s' matched no files." "${pattern}"
    fi
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
    # shellcheck disable=SC2034 # template is a required output slot; only axes/rawtokens/seen_map used
    local -a template axes rawtokens
    local -A seen_map
    knit_search_scan template axes rawtokens seen_map "" "${downstream[@]}"

    # Build a name→axis-index map for explicit literal-token axes.
    local -A axis_by_param=()
    local ax_i ax_kind ax_name
    for ((ax_i=0; ax_i<${#axes[@]}; ax_i++)); do
        read -r ax_kind _ ax_name <<< "${axes[ax_i]}"
        [[ "${ax_kind}" == "literal" ]] && axis_by_param["${ax_name}"]="${ax_i}"
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
                        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
                        pj=$(knit_jq -cn \
                            --arg  name  "${param}" \
                            --arg  vtype "${vtype}" \
                            --argjson lo   "${tok_desc[lo]}" \
                            --argjson hi   "${tok_desc[hi]}" \
                            '{"name":$name,"ax":"range","value_type":$vtype,
                              "bounds":[$lo,$hi],"log_scale":false}')
                        ;;
                    list)
                        local vtype
                        _knit_ax_value_type vtype "${ptype}" "${tok_vals[@]}"
                        _knit_ax_choice_json pj "${param}" "${vtype}" "${tok_vals[@]}"
                        ;;
                    glob)
                        local -a gvals
                        _knit_ax_glob_values gvals "${tok_desc[glob]}"
                        _knit_ax_choice_json pj "${param}" "str" "${gvals[@]}"
                        ;;
                esac
                ax_params_json+=("${pj}")
                ;;

            sweep)
                # Use the declared domain from knit_parameter_space.
                local vtype
                _knit_ax_value_type vtype "${dt}" "${dvals[@]}"
                local pj
                case "${dk}" in
                    range)
                        # shellcheck disable=SC2016 # $name/$vtype/$lo/$hi/$log are jq variables, not shell
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
                        _knit_ax_choice_json pj "${param}" "${vtype}" "${dvals[@]}"
                        ;;
                    glob)
                        local -a gvals
                        _knit_ax_glob_values gvals "${dglob}"
                        _knit_ax_choice_json pj "${param}" "str" "${gvals[@]}"
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

    # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
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
# The coprocess stdout carries the RPC responses (read by _knit_ax_rpc), so it
# must stay clean. Its stderr carries the Ax library's own logging (and any
# Python traceback on a crash), which would otherwise land on the terminal; it is
# redirected (appended) to <log> so the optimize output stays quiet and the log
# is there to inspect when the driver fails.
#
# @param[in] driver_prefix The built _ax-driver instance directory (holds
#   .activate.sh).
# @param[in] log Path the driver's stderr is appended to (per-campaign log file).
# ------------------------------------------------------------------------------
_knit_ax_start_driver() {
    local driver_prefix="$1"
    local log="$2"
    local plugin_dir="${_KNIT_AX_PLUGIN_DIR}"
    # The activation lives only in this subshell; exec replaces it with python so
    # no activated shell lingers. stderr -> log keeps the Ax library's logging off
    # the terminal; stdout stays the RPC pipe.
    coproc AX_DRIVER {
        # shellcheck disable=SC1091
        source "${driver_prefix}/.activate.sh"
        exec python "${plugin_dir}/ax_driver.py" 2>>"${log}"
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
# @param[in] $2 The trial's child row id (stashed so the campaign can resolve
#   best_id after the loop; the objective itself arrives in $4).
# @param[in] $3 The trial's terminal status ("completed" or "failed").
# @param[in] $4 The objective value (empty on a failed/NULL trial).
# @return 0 always (continue the campaign).
# ------------------------------------------------------------------------------
_knit_ax_observe() {
    local tag="$1" uuid="$2" status="$3" objective="$4"
    # Map this trial's Ax index to its recorded child row id, so _knit_ax_optimize
    # can record best_id once Ax names the best trial by index. _knit_ax_trial_row
    # comes from the enclosing _knit_ax_optimize frame through dynamic scope.
    # shellcheck disable=SC2154
    [[ -n "${uuid}" ]] && _knit_ax_trial_row["${tag}"]="${uuid}"
    local req
    # on_failure / penalty come from the enclosing _knit_ax_optimize frame.
    # shellcheck disable=SC2154
    if [[ "${status}" == "completed" && -n "${objective}" ]]; then
        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
        req=$(knit_jq -cn --argjson i "${tag}" --argjson o "${objective}" \
            '{cmd:"tell",index:$i,objective:$o,status:"ok"}')
    elif [[ "${on_failure}" == "penalize" && -n "${penalty}" ]]; then
        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
        req=$(knit_jq -cn --argjson i "${tag}" --argjson o "${penalty}" \
            '{cmd:"tell",index:$i,objective:$o,status:"penalized"}')
    else
        # shellcheck disable=SC2016 # $-names in the filter are jq variables, not shell
        req=$(knit_jq -cn --argjson i "${tag}" \
            '{cmd:"tell",index:$i,status:"failed"}')
    fi
    local resp
    _knit_ax_rpc resp "${req}"
    return 0
}
