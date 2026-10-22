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
    # Optimization loop not yet implemented.
}
