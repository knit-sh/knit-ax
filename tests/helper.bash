#!/usr/bin/env bash
#
# Shared helpers for the knit-ax plugin test suite.
#
# The suite needs a knit.sh that includes the Phase-A public search-core API
# (knit_search_loop, knit_search_launch, knit_search_scan, etc.) but does NOT
# itself register an "ax" or "uv" environment manager — the plugin provides
# those. Point KNIT_SH at such a build before running bats:
#
#     KNIT_SH=/path/to/knit.sh bats tests/

# Source knit.sh (from KNIT_SH) and then the plugin, so a test can call the
# plugin's verbs and knit's public API. Sets KNIT_OFFLINE=1 so that the
# transitive "knit_import uv" inside plugin.sh defers gracefully without
# touching the network (unit tests have no .knit directory and need no live uv
# environment). Skips when KNIT_SH is unusable.
knit_ax_test_load() {
    if [[ -z "${KNIT_SH:-}" || ! -r "${KNIT_SH}" ]]; then
        skip "set KNIT_SH to a readable knit.sh build with Phase-A search-core API"
    fi
    # shellcheck disable=SC1090
    source "${KNIT_SH}"
    KNIT_OFFLINE=1
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../plugin.sh"
    KNIT_OFFLINE=0
}

# A throwaway sqlite-backed DB for tests that need a bootstrapped experiment
# (command registration with a table, provenance recording, etc.).
knit_ax_test_db_setup() {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
    _KNIT_SQLITE_EXE="sqlite3"
    KNIT_AX_TEST_DB_DIR="$(mktemp -d)"
    _KNIT_DATABASE="${KNIT_AX_TEST_DB_DIR}/knit.db"
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_create_metadata_table
}

knit_ax_test_db_teardown() {
    rm -rf "${KNIT_AX_TEST_DB_DIR:-}"
    _KNIT_IS_BOOTSTRAPPED=""
}
