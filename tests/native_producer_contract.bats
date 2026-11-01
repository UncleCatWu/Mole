#!/usr/bin/env bats
run_native_case() {
    run env HOME="$MOLE_TEST_RUN_ROOT/native-$1" /bin/bash tests/support/native_producer_case.sh "$1"
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *'OWNED_NATIVE_CLOSURE='* ]]
}
@test "native completed recursive AppSupport size admits exact previews" {
    run_native_case app_complete
    [[ "$output" == *'LATER_SECTION'* ]]
}
@test "native AppSupport find prefix timeout discards plan and preserves partial later sections" {
    run_native_case app_scan
    [[ "$output" == *'LATER_SECTION'* && "$output" == *'Potential space:'*'+'* ]]
}
@test "native AppSupport du timeout keeps item and counts only completed sibling" {
    run_native_case app_du
    [[ "$output" == *'LATER_SECTION'* && "$output" == *'Potential space:'*'+'* ]]
}
@test "native project recursive completed producer preserves depth prune and sorted consumer domain" {
    run_native_case project_complete
}
@test "native project recursive prefix timeout never reaches consumer sink" {
    run_native_case project_scan
}
@test "native backend SIGINT remains sticky before any candidate sizing or later section" {
    run_native_case app_signal
    [[ "$output" != *'LATER_SECTION'* && "$output" != *'SIZE:'* && "$output" != *'PREVIEW:'* && "$output" != *'SINK:'* ]]
}
