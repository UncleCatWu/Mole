#!/bin/bash
# Shared private CLI build: production CLI with explicit native-provider fixtures.

MOLE_CLI_SUPPORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=lib/core/test_boundary.sh
source "$MOLE_CLI_SUPPORT_ROOT/lib/core/test_boundary.sh"

mole_build_go_cli_helpers() {
    local helper_dir="$1"
    [[ "$MOLE_CLI_SUPPORT_ROOT" == "${MOLE_TEST_RUN_ROOT:-}/repo" &&
        -n "${MOLE_TEST_SANDBOX_ACTIVE:-}" &&
        "$MOLE_TEST_SANDBOX_ACTIVE" == "${MOLE_TEST_BOUNDARY_TOKEN:-}" ]] || {
        printf 'CLI helper build requires the private sandbox source snapshot\n' >&2
        return 16
    }
    _mole_test_guard_mutation_path "$helper_dir/overlay.json" || return $?
    _mole_test_guard_mutation_path "${GOCACHE:-}/cli-helper-cache" || return $?
    _mole_test_guard_mutation_path "${TMPDIR%/}/cli-helper-tmp" || return $?
    python3 -B - "$MOLE_CLI_SUPPORT_ROOT" "$helper_dir" << 'PY' || return $?
import json
from pathlib import Path
import re
import sys

project, destination = map(Path, sys.argv[1:])
replacements = {}
bindings = {
    'metrics.go': [('host.Info()', 'statusFixtureHostInfo()')],
    'metrics_memory.go': [('mem.VirtualMemory()', 'statusFixtureMemory()'),
                          ('mem.SwapMemory()', 'statusFixtureSwap()')],
    'metrics_network.go': [('net.Interfaces()', 'statusFixtureInterfaces()')],
}
for filename, sites in bindings.items():
    original = project / 'cmd/status' / filename
    source = original.read_text()
    # Bind executable source only. Comments cannot satisfy a changed call site.
    code = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    for native, fixture in sites:
        assert code.count(native) == 1, (filename, native, code.count(native))
        lines = source.splitlines(keepends=True)
        matches = [i for i, line in enumerate(lines)
                   if native in line and not line.lstrip().startswith('//')]
        assert len(matches) == 1, (filename, native, matches)
        i = matches[0]
        lines[i] = lines[i].replace(native, fixture)
        source = ''.join(lines)
    target = destination / filename
    target.write_text(source)
    replacements[str(original)] = str(target)
replacements[str(project / 'cmd/status/zz_cli_native_fixture.go')] = str(project / 'tests/fixtures/status_cli_native.go.txt')
(destination / 'overlay.json').write_text(json.dumps({'Replace': replacements}, sort_keys=True) + '\n')
print('CLI source binding: 4 exact native call sites; Collector/main/watch/JSON source retained', file=sys.stderr)
PY
    (cd "$MOLE_CLI_SUPPORT_ROOT" && go build -o "$helper_dir/analyze-go" ./cmd/analyze) || return $?
    (cd "$MOLE_CLI_SUPPORT_ROOT" && go build -overlay "$helper_dir/overlay.json" -o "$helper_dir/status-go" ./cmd/status) || return $?
    export MOLE_TEST_ANALYZE_BIN="$helper_dir/analyze-go"
    export MOLE_TEST_STATUS_BIN="$helper_dir/status-go"
}
