# CyberVPS Cross-Host Migration Guide

This guide details how to migrate an active user-space hosting stack from one Linux VPS to another, even when hostnames, usernames, architectures, or Linux distributions differ.

---

## 1. Migration Overview

Traditional backups often fail when moving across VPS instances due to:
- Hardcoded home directory paths (`/home/user1` vs `/home/user2`)
- Port conflicts with existing users on shared hosts
- Incompatible precompiled binaries across CPU architectures (x86_64 vs ARM64)
- Differences in C standard libraries (glibc vs musl)

CyberVPS solves these challenges by separating **portable configuration and application source** from **platform-specific compiled runtimes**.

---

## 2. Migration Step-by-Step

### Step 1: Create Backup on Source VPS
On the source VPS, create a full portable snapshot:
```bash
cd ~/cyberbackup
bash ./backup-now.sh
```
The snapshot will be saved in `downloads/cybervps-backup-YYYYMMDD-HHMMSS.tar.zst`.

### Step 2: Transfer Archive to Destination VPS
Transfer the archive and metadata to the destination VPS using SCP, Rsync, or remote storage:
```bash
scp downloads/cybervps-backup-*.tar.* dest-vps:~/cyberbackup/downloads/
```

### Step 3: Run Migration on Destination VPS
On the destination VPS, run:
```bash
cd ~/cyberbackup
bash ./migrate.sh --archive downloads/cybervps-backup-YYYYMMDD-HHMMSS.tar.zst
```
Or use option **[3] Migrate Backup From Another VPS** in `bash cybervps.sh`.

---

## 3. How Differences Are Reconciled

| Attribute | Source VPS | Destination VPS | Reconciled By |
|---|---|---|---|
| **User & Home** | `alice` (`/home/alice`) | `bob` (`/home/bob`) | Managed path translator updates config files without touching project source code. |
| **Ports** | `8080`, `6380` | Already in use by another user | Dynamic port allocator discovers free unprivileged localhost ports and updates configs. |
| **Architecture** | `x86_64` | `aarch64` | Skips host-specific binaries; downloads and installs ARM64-native runtimes (Micromamba, Go, Cloudflared). |
| **Distribution** | Debian 12 | Ubuntu 24.04 / AlmaLinux | Uses distribution-agnostic user-space package manager (Micromamba/Conda-forge). |

---

## 4. Post-Migration Verification
After migration finishes:
```bash
bash ./verify.sh
```
Confirm that all components report `PASS` or expected `OPTIONAL` states.
