# Contributing to CyberVPS

Thank you for your interest in contributing to CyberVPS!

CyberVPS is an open-source portable non-root Linux VPS recovery and hosting toolkit. To maintain safety, portability, and quality across heterogeneous Linux environments, all contributions must adhere to the following principles.

---

## 1. Absolute Development Rules

1. **Strictly Rootless:** Never introduce `sudo`, `su`, or package manager commands (`apt`, `dnf`, `yum`, `pacman`). All functionality must execute within ordinary unprivileged user space.
2. **Provider Compliance:** Never add binary renaming, process disguise mechanisms, or watchdog bypasses designed to circumvent host limitations. If a feature is constrained by a hosting provider, detect it and fall back gracefully.
3. **Localhost First:** All default network listeners must bind exclusively to `127.0.0.1`.
4. **Zero Hardcoded Identities:** Never hardcode usernames, home paths, or provider hostnames in code. Use dynamic detection via `lib/detect.sh`.
5. **No Secrets or Archives in Git:** Never commit `.env` files, credentials, or backup archives (`*.tar.*`).

---

## 2. Development Workflow

### Prerequisites
- Bash 4.4+
- Standard POSIX utilities (`tar`, `awk`, `sed`, `grep`, `openssl`)
- Git

### Running Tests Locally
Before proposing changes, run the automated test suite:
```bash
bash ./tests/run-tests.sh
```
All unit tests must pass.

### Running Secret Verification
Verify that your changes introduce no credentials or forbidden files:
```bash
bash ./scripts/secret-check.sh
```

---

## 3. Commit Guidelines
- Use descriptive commit messages following the Conventional Commits specification:
  - `feat: ...` for new capabilities
  - `fix: ...` for bug fixes
  - `refactor: ...` for structural improvements
  - `docs: ...` for documentation
  - `test: ...` for test suite additions
  - `security: ...` for hardening and vulnerability mitigations
- Group related changes into logical units.
