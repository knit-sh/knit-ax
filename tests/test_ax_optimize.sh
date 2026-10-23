#!/usr/bin/env bats
#
# Command-surface tests for the campaign model: the prepare -> optimize split and
# the list / show reporting verbs, their registration, "--help", and option
# surfaces. Behavior (writing the campaign, recording the row, resume) lives in
# test_ax_campaign.sh.

load helper

setup() {
    knit_ax_test_load
    knit_ax_test_db_setup
}

teardown() {
    knit_ax_test_db_teardown
}

@test "ax subcommands are registered after lazy discovery" {
    knit ax --help > /dev/null 2>&1 || true
    _knit_set_find _KNIT_COMMANDS "ax__1__prepare"
    _knit_set_find _KNIT_COMMANDS "ax__1__optimize"
    _knit_set_find _KNIT_COMMANDS "ax__1__list"
    _knit_set_find _KNIT_COMMANDS "ax__1__show"
}

@test "ax prepare --help exits 0 and shows the dispatcher usage" {
    run knit ax prepare --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"prepare"* ]]
    [[ "$output" == *"downstream"* ]]
}

@test "ax prepare --help shows all key options" {
    run knit ax prepare --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--campaign"* ]]
    [[ "$output" == *"--objective"* ]]
    [[ "$output" == *"--minimize"* ]]
    [[ "$output" == *"--maximize"* ]]
    [[ "$output" == *"--trials"* ]]
    [[ "$output" == *"--parallel"* ]]
    [[ "$output" == *"--seed"* ]]
    [[ "$output" == *"--on-failure"* ]]
    [[ "$output" == *"--sobol-trials"* ]]
}

@test "ax prepare dropped the old --group and --resume options" {
    run knit ax prepare --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"--group"* ]]
    [[ "$output" != *"--resume"* ]]
}

@test "ax optimize --help exits 0 and takes only --campaign" {
    run knit ax optimize --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--campaign"* ]]
    # the OPTIMIZE ARGS live on prepare now, not optimize
    [[ "$output" != *"--objective"* ]]
    [[ "$output" != *"--trials"* ]]
}

@test "ax list --help exits 0 and shows --verbose" {
    run knit ax list --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--verbose"* ]]
}

@test "ax show --help exits 0 and shows --campaign" {
    run knit ax show --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--campaign"* ]]
}

@test "ax prepare with no downstream fatals" {
    run knit ax prepare --campaign c1 --objective val_loss --trials 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"downstream"* ]]
}

@test "ax prepare with -- but no command fatals" {
    run knit ax prepare --campaign c1 --objective val_loss --trials 5 --
    [ "$status" -ne 0 ]
    [[ "$output" == *"downstream"* ]]
}

@test "ax optimize without --campaign fatals" {
    run knit ax optimize
    [ "$status" -ne 0 ]
}
