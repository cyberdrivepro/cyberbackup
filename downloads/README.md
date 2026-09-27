# CyberVPS downloads

This directory is used to store downloaded backup archives during restore operations.
It is a temporary staging area and should not be committed to Git.

After restore:
- downloaded backup archive (e.g., cybervps-backup-YYYYMMDD-HHMMSS.tar.zst)
- latest.json
- SHA256SUMS
- downloaded from remote or local source

This directory may be cleaned up after successful restore.
