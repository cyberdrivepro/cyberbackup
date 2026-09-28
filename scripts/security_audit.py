#!/usr/bin/env python3
"""Reject interactive escalation, broad kills and unverified pipe-to-shell installs."""
import sys
from pathlib import Path
from tree_sitter import Language, Parser
import tree_sitter_bash
from bash_audit import walk

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
parser = Parser(Language(tree_sitter_bash.language()))
errors = []
for path in root.rglob('*'):
    if not path.is_file() or any(p in {'.git', 'tests', 'target', '.venv', 'node_modules', '__pycache__'} for p in path.relative_to(root).parts):
        continue
    if path.suffix not in {'.sh', ''}:
        continue
    data = path.read_bytes()
    if path.suffix != '.sh' and not data.startswith(b'#!/'):
        continue
    for node in walk(parser.parse(data).root_node):
        if node.type == 'command':
            n = node.child_by_field_name('name')
            if n is None:
                continue
            name = n.text.decode().strip('\"\'')
            args = [c.text.decode() for c in node.named_children if c.type not in {'command_name', 'file_redirect'}]
            text = node.text.decode()
            bad = name in {'su', 'pkill', 'killall'}
            if name == 'sudo':
                bad = not args or args[0] != '-n' or '-S' in args
                if args and args[0] == '-n' and args[1:] != ['true']:
                    bad = path.name not in {'privilege.sh', 'packages.sh', 'installer.sh', 'install.sh'}
            if name in {'apt', 'apt-get', 'dnf', 'yum', 'apk', 'pacman', 'zypper'} and path.name not in {'packages.sh', 'install.sh', 'installer.sh'}:
                bad = any(a in {'install', 'add', 'update', 'upgrade', '-S', '-Syu'} for a in args)
            if bad:
                errors.append(f'{path.relative_to(root)}:{node.start_point.row+1}: prohibited privilege/process command')
        if node.type == 'pipeline':
            names = [n.child_by_field_name('name').text.decode() for n in node.named_children if n.type == 'command' and n.child_by_field_name('name')]
            if any(n in {'curl', 'wget'} for n in names) and any(n in {'sh', 'bash'} for n in names):
                errors.append(f'{path.relative_to(root)}:{node.start_point.row+1}: unverified download piped to shell')
print('\n'.join(errors) if errors else 'PASS: authorized privilege and process policy')
sys.exit(bool(errors))
