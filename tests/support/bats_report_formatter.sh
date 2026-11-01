#!/bin/bash
# Internal extended-TAP bridge. Never use process substitution for report fanout.
set -uo pipefail
support_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=lib/core/test_boundary.sh
source "$support_root/lib/core/test_boundary.sh"
part="${MOLE_TEST_BATS_PART_DIR:-}"
_mole_test_guard_mutation_path "$part/extended.tap" || exit $?
[[ "$support_root" == "${MOLE_TEST_RUN_ROOT:-}/repo" ]] || exit 16
console="${BATS_FORMATTER:-pretty}"
console_args=()
case "$console" in
    tap | tap13 | junit | pretty)
        console_path="$BATS_LIBEXEC/bats-format-$console"
        if [[ "$console" == pretty || "$console" == junit ]]; then
            console_args=(--base-path "$support_root")
        fi
        ;;
    /*) console_path="$console" ;;
    *)
        printf 'Bats report refused (unsupported-console): %s; set BATS_FORMATTER=tap/pretty or an executable absolute formatter path.\n' "$console" >&2
        exit 16
        ;;
esac
[[ -x "$console_path" && -x "$BATS_LIBEXEC/bats-format-junit" ]] || {
    printf 'Bats report refused (formatter-unavailable): inspect the selected formatter and Bats installation.\n' >&2
    exit 16
}
tee "$part/extended.tap" | "$console_path" ${console_args[@]+"${console_args[@]}"}
stream_rc=("${PIPESTATUS[@]}")
python3 -B "$support_root/tests/support/bats_report.py" validate "$part/extended.tap" "$part/counts.json"
validator_rc=$?
"$BATS_LIBEXEC/bats-format-junit" --base-path "$support_root" < "$part/extended.tap" > "$part/report.xml"
junit_rc=$?
printf '%s %s %s %s\n' "${stream_rc[0]}" "${stream_rc[1]}" "$validator_rc" "$junit_rc" > "$part/formatter-status"
for status in "${stream_rc[@]}" "$validator_rc" "$junit_rc"; do
    if [[ $status -eq 124 || $status -ge 128 ]]; then exit "$status"; fi
done
for status in "${stream_rc[@]}" "$validator_rc" "$junit_rc"; do
    if [[ $status -ne 0 ]]; then
        printf 'Bats report failed: tee=%s console=%s validator=%s junit=%s; inspect %s\n' \
            "${stream_rc[0]}" "${stream_rc[1]}" "$validator_rc" "$junit_rc" "$part" >&2
        exit "$status"
    fi
done
