# CyberVPS payload

This directory holds extracted backup payload during restore operations.
It is a temporary staging area and should not be committed to Git.

After restore:
- staging/ contains extracted files from the backup archive
- manifest/ (inside staging) contains manifests from the backup
- files/ (inside staging) contains backed up files

This directory is cleaned up after successful restore.
