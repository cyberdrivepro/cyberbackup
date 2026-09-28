"""Audit Bash command nodes, including substitutions and extensionless scripts.

Dynamic commands are recorded in JSON, not falsely reported as resolved.
Tests cannot contribute definitions to production resolution. Heredocs are data.
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path
import sys

try:
    from tree_sitter import Language, Parser
    import tree_sitter_bash
except ImportError:
    sys.exit('Missing audit dependency: python3 -m pip install -r requirements-dev.txt')


def walk(node):
    yield node
    for child in node.named_children:
        yield from walk(child)


def audit(root):
    parser = Parser(Language(tree_sitter_bash.language()))
    allow = set(Path(__file__).with_name('external-commands.txt').read_text().splitlines())
    files, definitions, calls, errors = {}, defaultdict(list), [], []
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root).as_posix()
        if not path.is_file() or any(p in {'.git', 'target', '.venv', 'node_modules', '__pycache__', 'payload'} for p in path.relative_to(root).parts):
            continue
        if path.suffix not in {'.sh', ''}:
            continue
        data = path.read_bytes()
        if path.suffix != '.sh' and not data.startswith((b'#!/usr/bin/env bash', b'#!/bin/bash', b'#!/bin/sh')):
            continue
        tree = parser.parse(data)
        record = files[rel] = {'defined': [], 'called': [], 'external': [], 'dynamic': []}
        for node in walk(tree.root_node):
            if node.type == 'function_definition':
                name = node.child_by_field_name('name').text.decode()
                definitions[name].append((rel, node.start_point.row + 1))
                record['defined'].append(name)
            elif node.type == 'command':
                name_node = node.child_by_field_name('name')
                if name_node is None:
                    continue
                name = name_node.text.decode()
                if any(c in name for c in '$`'):
                    record['dynamic'].append(name)
                    continue
                name = name.strip('\"\'')
                if '/' in name or name in {'.', ':', '['}:
                    continue
                record['called'].append(name)
                calls.append((rel, node.start_point.row + 1, name))
            elif node.type == 'ERROR' or node.is_missing:
                errors.append(f'{rel}:{node.start_point.row + 1}: Bash parse error')
    production = {name for name, sites in definitions.items() if any(not p.startswith('tests/') for p, _ in sites)}
    for rel, line, name in calls:
        if name in allow:
            files[rel]['external'].append(name)
        elif name not in production and name not in files[rel]['defined']:
            errors.append(f'{rel}:{line}: UNDEFINED INTERNAL FUNCTION / unlisted executable: {name}')
    warnings = []
    called = {c[2] for c in calls}
    for name, sites in definitions.items():
        libs = sorted({p for p, _ in sites if p.startswith('lib/')})
        if len(libs) > 1:
            errors.append(f'DUPLICATE DEFINITION: {name}: {libs}')
        if name not in called:
            warnings.append(f'UNUSED INTERNAL FUNCTION (dynamic callers possible): {name}')
    return {'files': files, 'errors': sorted(set(errors)), 'warnings': warnings,
            'definitions': len(definitions), 'script_count': len(files)}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parent.parent)
    cli.add_argument('--json', action='store_true')
    args = cli.parse_args()
    report = audit(args.root)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Indexed {report['script_count']} Bash scripts and {report['definitions']} functions.")
        for error in report['errors']:
            print(error)
        print(f"{'FAIL' if report['errors'] else 'PASS'}: {len(report['errors'])} errors; {len(report['warnings'])} unused-function warnings")
    return bool(report['errors'])


if __name__ == '__main__':
    sys.exit(main())

