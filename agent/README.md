# CyberAgent native foundation

This Rust CLI runs directly on Linux and Windows. It is a local administration foundation, not yet a remote agent daemon. The existing Telegram Python agent is independent.

```text
cargo build --release --manifest-path agent/Cargo.toml
cyberagent status
cyberagent doctor
cyberagent identity
cyberagent exec --timeout 30 -- PROGRAM ARGUMENTS
cyberagent nodes add worker01 ssh://example.invalid
cyberagent nodes list
cyberagent pair create --expires 300
cyberagent pair redeem --controller laptop --public-key BASE64_KEY
cyberagent pair controllers
cyberagent pair revoke laptop
cyberagent secret set NAME
cyberagent secret get NAME --show
cyberagent secret list
cyberagent secret delete NAME
```

`pair redeem` and `secret set` read their sensitive inputs from stdin, not process arguments. Pairing output intentionally displays a one-time invitation to its local owner. Invitations have 256 bits of randomness, expire, are stored only as SHA-256 hashes, and are consumed transactionally once. Pairing registers an Ed25519 controller public key locally; it does not open a listener or claim a controller connection has been established. Existing controller identities are never silently replaced.

Identity private keys remain local. Linux stores secrets in owner-only 0600 files under a 0700 directory. Windows applies protected owner ACLs and encrypts secrets with current-user DPAPI; it reads actual process-token elevation without requesting UAC. No default password exists. `secret get` requires `--show`, and replacing an existing secret requires explicit deletion first.

State is current-user scoped: Linux `${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/agent`, Windows `%LOCALAPPDATA%/CyberVPS/agent`. `--state-dir` overrides it. `agent.sqlite` uses transactional migrations and contains local node metadata, process outcomes, controller trust records, and pairing hashes. It is separate from the Python control plane's fleet database. Public status/doctor commands do not create state.

Execution accepts a program plus argv, clears the inherited environment, and restores a small documented baseline (PATH, HOME, USERPROFILE, SYSTEMROOT, WINDIR, TEMP, TMP, LANG, LC_ALL). `--env NAME` allows additional explicit variables. It does not invoke a shell unless the operator explicitly selects a shell executable. Output streams directly to the current terminal, without unbounded capture. SQLite records the executable and outcome; argument values and environment values are not logged. Timeout returns 124. Unix timeout terminates the newly created child process group; Windows terminates the owned child process handle. Descendant processes detached from those boundaries are not supervised by this foundation.

Limitations reported in `status`: no relay, PTY/ConPTY, network server, durable scheduler, automatic update, or restart supervisor. Node health is UNKNOWN until a real probe is implemented. Native cgroup fields currently describe the root cgroup mount only; the Bash doctor has the full nested/v1 effective-resource detector. This binary does not promise provider durability or kernel privileges.

Validation at integration: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test`. Unit tests cover migration persistence, identity stability, secret protection/traversal, replay/expiry rejection, explicit exit statuses, and timeout behavior.
