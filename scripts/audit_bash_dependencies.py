#!/usr/bin/env python3
"""
scripts/audit_bash_dependencies.py — Static function call and dependency auditor
Verifies that every user-defined function called in shell scripts has a valid
definition within the repository.
"""
import os
import re
import sys

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

TARGET_FILES = [
    "cybervps.sh", "fresh-install.sh", "restore.sh", "migrate.sh",
    "backup-now.sh", "upload-backup.sh", "download-backup.sh", "verify.sh",
    "lib/common.sh", "lib/detect.sh", "lib/execution.sh", "lib/install.sh",
    "lib/lock.sh", "lib/logging.sh", "lib/migration.sh", "lib/ports.sh",
    "lib/remote.sh", "lib/restore.sh", "lib/services.sh", "lib/ui.sh",
    "lib/verify.sh", "lib/archive.sh", "lib/architecture.sh", "lib/backup.sh",
    "installers/micromamba.sh", "installers/python.sh", "installers/node.sh",
    "installers/rust.sh", "installers/go.sh", "installers/redis.sh",
    "installers/nginx.sh", "installers/cloudflared.sh",
    "scripts/cybervps-export-diagnostics.sh", "scripts/root-command-guard.sh",
    "scripts/secret-check.sh"
]

# 1. Collect all defined functions across repo
defined_functions = set()
fn_regex1 = re.compile(r'^\s*(?:function\s+)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{', re.MULTILINE)
fn_regex2 = re.compile(r'^\s*function\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\{', re.MULTILINE)

for root, _, files in os.walk(REPO_DIR):
    if ".git" in root or "payload" in root or "tmp" in root:
        continue
    for f in files:
        if f.endswith(".sh"):
            p = os.path.join(root, f)
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                txt = fh.read()
            for m in fn_regex1.finditer(txt):
                defined_functions.add(m.group(1))
            for m in fn_regex2.finditer(txt):
                defined_functions.add(m.group(1))

# Standard tools and shell builtins
KNOWN_SYSTEM = {
    "[", "[[", "alias", "awk", "base64", "basename", "bash", "bc", "bind", "break",
    "builtin", "caller", "cat", "cd", "chmod", "chown", "clear", "command", "compgen",
    "complete", "continue", "cp", "crontab", "curl", "cut", "date", "declare", "df",
    "diff", "dirname", "dirs", "disown", "echo", "enable", "eval", "exec", "exit",
    "export", "false", "fc", "fg", "find", "flock", "free", "getconf", "getopts",
    "git", "go", "grep", "gzip", "hash", "head", "help", "history", "hostname",
    "id", "jobs", "kill", "ldconfig", "ldd", "let", "ln", "local", "ls", "mkdir",
    "mktemp", "mv", "netstat", "node", "nohup", "nproc", "npm", "openssl", "popd",
    "printf", "pushd", "pwd", "python", "python3", "read", "readarray", "readonly",
    "return", "rm", "rmdir", "rsync", "rustc", "rustup", "screen", "sed", "set",
    "sha256sum", "shasum", "shift", "shopt", "sleep", "sort", "source", "split",
    "ss", "ssh", "stat", "su", "sudo", "suspend", "sync", "systemctl", "tail",
    "tar", "tee", "test", "times", "tmux", "touch", "tput", "tr", "trap", "true",
    "type", "typeset", "ulimit", "umask", "unalias", "uname", "uniq", "unset",
    "wait", "wc", "wget", "which", "whoami", "xargs", "zstd", "micromamba", "cargo",
    "cloudflared", "redis-server", "redis-cli", "nginx", "pip", "pip3", "pnpm", "yarn",
    "pm2", "sh", "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
    "until", "do", "done", "in", "select", "function", ".", ":", "!", "du", "file"
}

# 2. Extract and check custom function calls
# Custom calls match identifiers like ensure_*, install_*, ui_*, log_*, run_*, init_*, etc.
CUSTOM_CALL_PATTERN = re.compile(
    r'\b((?:ensure|install|cybervps|ui|_ui|log|_log|run|is|check|setup|handle|parse|atomic|find|reserve|load|get|disable|verify|interpret|with|acquire|release|init)_[a-zA-Z0-9_]+)\b'
)

errors = []

for rel_path in TARGET_FILES:
    full_path = os.path.join(REPO_DIR, rel_path.replace("/", os.sep))
    if not os.path.exists(full_path):
        continue

    with open(full_path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    in_heredoc = False
    heredoc_delim = ""

    for line_idx, raw_line in enumerate(lines, 1):
        line = raw_line.strip()

        # Handle heredoc
        if not in_heredoc:
            m = re.search(r'<<-?\s*[\'"]?([a-zA-Z0-9_]+)[\'"]?', line)
            if m:
                in_heredoc = True
                heredoc_delim = m.group(1)
        else:
            if line == heredoc_delim:
                in_heredoc = False
            continue

        if not line or line.startswith("#"):
            continue

        # Skip function definition headers (they define, not call)
        if re.match(r'^(?:function\s+)?[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{', line):
            continue

        # Skip variable assignment statements
        if re.match(r'^(?:local\s+|export\s+)?[a-zA-Z_][a-zA-Z0-9_]*(?:\[[^\]]*\])?(\+)?=', line):
            # But the right-hand side might contain a command substitution $(func)
            sub_matches = re.findall(r'\$\(\s*([a-zA-Z_][a-zA-Z0-9_]*)\b', line)
            for sm in sub_matches:
                if sm not in KNOWN_SYSTEM and sm not in defined_functions:
                    errors.append((rel_path, line_idx, sm, line))
            continue

        # Search for custom function calls
        for match in CUSTOM_CALL_PATTERN.finditer(line):
            fn = match.group(1)
            # Ignore if part of a variable name like $foo_bar or "${foo_bar}"
            start = match.start()
            if start > 0 and line[start-1] in ('$', '{'):
                continue
            if fn in defined_functions or fn in KNOWN_SYSTEM:
                continue

            errors.append((rel_path, line_idx, fn, line))

print("=== CyberVPS Function Dependency Auditor ===")
print(f"Indexed {len(defined_functions)} function definitions across repository.")

if errors:
    print(f"\n[FAIL] Found {len(errors)} undefined function reference(s):")
    for rpath, lnum, fn, ltxt in errors:
        print(f"  {rpath}:{lnum} -> '{fn}' is called without a definition:")
        print(f"    Line: {ltxt}")
    sys.exit(1)
else:
    print("\n[PASS] All function calls resolve to verified definitions.")
    sys.exit(0)
