# CyberVPS logs

This directory holds operation logs for the CyberVPS recovery system.

Logs:
- cybervps.log: main entry script log
- backup-now.log: backup operation log
- restore.log: restore operation log
- fresh-install.log: fresh install operation log
- verify.log: verify operation log
- upload.log: upload operation log
- download.log: download operation log

Logs are rotated and kept for a configurable retention period.
They should not be committed to Git.
