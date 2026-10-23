#!/usr/bin/env bats
#
# MB2 tests for the private _ax-driver uv setup: registration, builtin
# marking, the ensure-built helper path, and activation confinement.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
    _KNIT_TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR:-}"
    unset KNIT_SETUP_PREFIX
    knit_ax_test_db_teardown
}

# ---------- registration ----------

@test "_ax-driver is registered in _KNIT_SETUPS" {
    [[ -v _KNIT_SETUPS[_ax_driver] ]]
}

@test "_ax-driver is marked builtin" {
    local cmd
    _knit_command_mangle cmd "setup:_ax-driver"
    local builtin_var="_KNIT_CMD_${cmd}_is_builtin"
    [[ "${!builtin_var}" == "true" ]]
}

@test "_ax-driver --help exits 0" {
    # Invoke help directly via the internal command dispatcher (the public
    # "knit setup" dispatcher requires --name which needs a real experiment
    # tree; help only needs the registration to be present).
    run _knit_invoke_command "setup" "_ax-driver" "--help"
    [ "$status" -eq 0 ]
}

@test "_ax-driver declares uv manifest and lock columns (requires KNIT_UV_SH)" {
    declare -F knit_with_uv_specs \
        || skip "knit_with_uv_specs not available; set KNIT_UV_SH to knit-uv/plugin.sh"
    local cmd
    _knit_command_mangle cmd "setup:_ax-driver"
    # Force table creation now that the DB is bootstrapped. The table is
    # normally ensured lazily on first invocation; doing it directly here
    # avoids running the full build in a unit test.
    local table_var="_KNIT_CMD_${cmd}_table"
    _knit_db_setup_table "${cmd}" "${!table_var}"
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" \
        "PRAGMA table_info('${!table_var}');" 2>/dev/null \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__uv_manifest__* ]]
    [[ "${names}" == *__uv_lock__* ]]
}

# ---------- ensure-built helper ----------

@test "_knit_ax_ensure_driver returns the instance path when already built" {
    # Arrange: set _KNIT_PREFIX to a temp .knit dir and create the instance.
    local saved_prefix="${_KNIT_PREFIX}"
    local fake_knit="${_KNIT_TEST_TMPDIR}/.knit"
    mkdir -p "${_KNIT_TEST_TMPDIR}/setups/_ax-driver"
    _KNIT_PREFIX="${fake_knit}"
    local result
    _knit_ax_ensure_driver result
    _KNIT_PREFIX="${saved_prefix}"
    [[ "${result}" == "${_KNIT_TEST_TMPDIR}/setups/_ax-driver" ]]
}

@test "_knit_ax_ensure_driver builds the instance when it is absent" {
    command -v knit_with_uv_env >/dev/null 2>&1 \
        || skip "uv directives not available; set KNIT_UV_SH to knit-uv/plugin.sh"
    # Point _KNIT_PREFIX at a fresh experiment tree (no instance yet) and confirm
    # that _knit_ax_ensure_driver creates it on demand and returns the correct
    # path, exercising the absent -> "knit setup" -> dir-created path.
    local saved_prefix="${_KNIT_PREFIX}"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/ondemand/.knit"

    # Keep the build light and hermetic. A real _ax-driver build would provision
    # uv (a network download that itself needs jq) and run "uv sync" to install
    # Ax — neither of which belongs in a unit test. Pre-create the uv tool dir so
    # knit_env_ensure_provisioned short-circuits (no download), and stub the uv
    # env verbs so the "build" only lays down the directory, manifest, and lock
    # the setup dispatcher records. The subshell "knit setup" runs in inherits
    # these overrides. (NOTE: offline alone does not suffice — KNIT_OFFLINE=1
    # defers only the knit_import uv import, not the setup's uv-env build.)
    mkdir -p "${_KNIT_PREFIX}/uv"
    knit_uv_install_env() {
        local env_dir="$1" manifest="$2"
        mkdir -p "${env_dir}"
        cp "${manifest}" "${env_dir}/pyproject.toml" 2>/dev/null || :
        printf 'version = 1\n' > "${env_dir}/uv.lock"
    }
    knit_uv_activation() { :; }

    local result
    _knit_ax_ensure_driver result
    _KNIT_PREFIX="${saved_prefix}"
    [[ "${result}" == "${_KNIT_TEST_TMPDIR}/ondemand/setups/_ax-driver" ]]
    [[ -d "${_KNIT_TEST_TMPDIR}/ondemand/setups/_ax-driver" ]]
}

# ---------- activation confinement ----------

@test "_ax-driver .activate.sh is subshell-confinable" {
    # A uv .activate.sh sources the venv activate script, which only exports
    # PATH and VIRTUAL_ENV; both vanish when the subshell exits.
    local fake_venv="${_KNIT_TEST_TMPDIR}/uv-env/.venv"
    mkdir -p "${fake_venv}/bin"
    # Fake activate script that exports a unique marker.
    cat > "${fake_venv}/bin/activate" <<'EOF'
export KNIT_AX_DRIVER_MARKER=activated
export VIRTUAL_ENV="${_KNIT_TEST_TMPDIR}/uv-env/.venv"
export PATH="${VIRTUAL_ENV}/bin:${PATH:-}"
EOF
    local activate_sh="${_KNIT_TEST_TMPDIR}/.activate.sh"
    # Simulate what knit_uv_activation writes (source the venv activate).
    printf 'source %q\n' "${fake_venv}/bin/activate" > "${activate_sh}"
    # Record parent env state before the subshell.
    local before_marker="${KNIT_AX_DRIVER_MARKER:-}"
    local before_path="${PATH:-}"
    local before_venv="${VIRTUAL_ENV:-}"
    # Source inside a subshell; the parent must be unchanged afterward.
    ( source "${activate_sh}"; : )
    [ "${KNIT_AX_DRIVER_MARKER:-}" = "${before_marker}" ]
    [ "${PATH:-}" = "${before_path}" ]
    [ "${VIRTUAL_ENV:-}" = "${before_venv}" ]
}
