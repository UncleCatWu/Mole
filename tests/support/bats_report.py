#!/usr/bin/env python3
"""Validate captured extended TAP and merge official JUnit report parts."""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def validate(tap, receipt):
    lines = tap.read_text().splitlines()
    plan = re.fullmatch(r'1\.\.(\d+)', lines[0]) if lines else None
    results = [re.match(r'^(not ok|ok) (\d+) (.*)$', line) for line in lines]
    results = [item for item in results if item]
    expected = int(plan[1]) if plan else 0
    skipped = sum(item[1] == 'ok' and ' # skip' in item[3] for item in results)
    failed = sum(item[1] == 'not ok' for item in results)
    complete = (expected > 0 and sum(bool(re.fullmatch(r'1\.\.\d+', line)) for line in lines) == 1 and len(results) == expected and
                sorted(int(item[2]) for item in results) == list(range(1, expected + 1)) and
                any(line.startswith('suite ') for line in lines) and
                all(re.search(r' in \d+ms(?: #|$)', item[3]) for item in results))
    counts = dict(expected=expected, completed=len(results), passed=len(results)-failed-skipped,
                  failed=failed, skipped=skipped, complete=complete)
    receipt.write_text(json.dumps(counts, sort_keys=True) + '\n')
    if not complete:
        print('Bats report refused (incomplete-stream): inspect plan/results/timings in ' + str(tap), file=sys.stderr)
    return 0 if complete else 1


def merge(report_dir):
    manifest = report_dir / 'parts'
    paths = [Path(line) for line in manifest.read_text().splitlines()] if manifest.exists() else []
    aggregate = dict(expected=0, completed=0, passed=0, failed=0, skipped=0, complete=bool(paths), parts=len(paths))
    document = ET.Element('testsuites')
    seconds = 0.0
    for path in paths:
        assert path.parent == report_dir and not path.is_symlink(), 'report part escaped its private root'
        try:
            counts = json.loads((path / 'counts.json').read_text())
            statuses = [int(x) for x in (path / 'formatter-status').read_text().split()]
            bats_rc = int((path / 'bats-exit-status').read_text())
            assert len(statuses) == 4
            part = ET.parse(path / 'report.xml').getroot()
            xml_counts = dict(completed=sum(int(s.get('tests', 0)) for s in part),
                              failed=sum(int(s.get('failures', 0)) for s in part),
                              skipped=sum(int(s.get('skipped', 0)) for s in part))
            assert all(xml_counts[key] == counts[key] for key in xml_counts), 'JUnit and TAP counts disagree'
            aggregate['complete'] &= counts['complete'] and all(rc == 0 for rc in statuses) and bats_rc in (0, 1)
            for key in ('expected', 'completed', 'passed', 'failed', 'skipped'):
                aggregate[key] += counts[key]
            for suite in part:
                document.append(suite)
                seconds += float(suite.get('time', 0))
        except (OSError, ValueError, AssertionError, ET.ParseError) as error:
            aggregate['complete'] = False
            print('Bats report part incomplete: ' + str(path) + ': ' + str(error), file=sys.stderr)
    document.set('time', f'{seconds:.3f}')
    ET.indent(document)
    ET.ElementTree(document).write(report_dir / 'report.xml', encoding='utf-8', xml_declaration=True)
    (report_dir / 'summary.json').write_text(json.dumps(aggregate, sort_keys=True) + '\n')
    print('Bats report counts: ' + json.dumps(aggregate, sort_keys=True))
    return 0 if aggregate['complete'] and aggregate['expected'] > 0 else 1


if sys.argv[1] == 'validate':
    sys.exit(validate(Path(sys.argv[2]), Path(sys.argv[3])))
elif sys.argv[1] == 'merge':
    sys.exit(merge(Path(sys.argv[2])))
else:
    raise ValueError('unsupported private report operation')
