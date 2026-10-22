#!/usr/bin/env bats
#
# Smoke tests: sourcing the plugin registers the "ax" command group.

load helper

setup() {
    knit_ax_test_load
}

@test "sourcing the plugin registers the ax command group" {
    [[ -v _KNIT_COMMANDS[ax] ]]
}

@test "ax --help exits 0 and mentions ax" {
    run knit ax --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"ax"* ]]
}
