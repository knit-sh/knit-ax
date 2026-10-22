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

knit_register "ax" knit_empty "Ax Bayesian-optimization commands."
knit_done
