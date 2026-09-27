# CyberVPS scripts

This directory holds helper and internal scripts used by the CyberVPS recovery system.

Scripts:
- detect-backup.sh: detect local backup archive
- verify-backup.sh: verify backup archive integrity and SHA256
- extract-backup.sh: extract backup into staging directory
- restore-micromamba.sh: restore or recreate micromamba hosting environment
- restore-python.sh: restore Python packages from pip-freeze.txt
- restore-node.sh: restore Node, npm global tools
- restore-rust.sh: restore Rust toolchain
- restore-go.sh: restore Go installation
- restore-redis.sh: restore Redis user service
- restore-nginx.sh: restore nginx
- restore-supervisor.sh: restore supervisor configuration
- restore-pm2.sh: restore PM2
- restore-cloudflared.sh: restore cloudflared
- restore-hosting-scripts.sh: restore helper commands (hosting-start etc.)
- restore-shell.sh: restore shell configuration idempotently
- restore-login-recovery.sh: restore login-triggered recovery
- start-hosting.sh: start hosting stack after restore
- verify-services.sh: verify services after restore
- cleanup-staging.sh: clean up temporary staging directory
- create-pre-restore-backup.sh: create pre-restore backup of existing config
- detect-secrets.sh: detect sensitive files
- encrypt-secrets.sh: encrypt secrets
- decrypt-secrets.sh: decrypt secrets
- package-shared.sh: package shared directory separately
- upload-backup.sh: upload backup to remote
- download-backup.sh: download backup from remote
- generate-manifests.sh: regenerate manifests from current system
- disaster-simulation.sh: simulate disaster without deleting data

These scripts are called by the main entry points (cybervps.sh, backup-now.sh, restore.sh, fresh-install.sh).
