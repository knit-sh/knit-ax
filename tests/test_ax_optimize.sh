#!/usr/bin/env bats
#
# MB1 tests for the "ax:optimize" command skeleton: registration, "--help",
# the full option surface, and the no-downstream fatal.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
}

teardown() {
    knit_ax_test_db_teardown
}

@test "ax:optimize is registered after lazy discovery" {
    # Trigger discovery via --help; then confirm the command is in the table.
    knit ax --help > /dev/null 2>&1 || true
    _knit_set_find _KNIT_COMMANDS "ax__1__optimize"
}

@test "ax optimize --help exits 0" {
    run knit ax optimize --help
    [ "$status" -eq 0 ]
}

@test "ax optimize --help shows the dispatcher usage" {
    run knit ax optimize --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"optimize"* ]]
    [[ "$output" == *"downstream"* ]]
}

@test "ax optimize --help shows all key options" {
    run knit ax optimize --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--objective"* ]]
    [[ "$output" == *"--minimize"* ]]
    [[ "$output" == *"--maximize"* ]]
    [[ "$output" == *"--trials"* ]]
    [[ "$output" == *"--parallel"* ]]
    [[ "$output" == *"--seed"* ]]
    [[ "$output" == *"--on-failure"* ]]
    [[ "$output" == *"--group"* ]]
    [[ "$output" == *"--sobol-trials"* ]]
    [[ "$output" == *"--resume"* ]]
}

@test "ax optimize with no downstream fatals" {
    run knit ax optimize
    [ "$status" -ne 0 ]
    [[ "$output" == *"downstream"* ]]
}

@test "ax optimize with -- but no command fatals" {
    run knit ax optimize --
    [ "$status" -ne 0 ]
    [[ "$output" == *"downstream"* ]]
}
