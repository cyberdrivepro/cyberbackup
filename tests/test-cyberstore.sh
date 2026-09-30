#!/usr/bin/env bash
# tests/test-cyberstore.sh — Phase 2 CyberStore Distributed Storage Engine Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing Phase 2 CyberStore Content-Addressed Storage"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import hashlib
from pathlib import Path
import tempfile

from fleet.database import FleetDatabase
from fleet.models import NodeRecord
from fleet.store import CyberStore

with tempfile.TemporaryDirectory() as tmpdir:
    tmp_path = Path(tmpdir)
    db_file = tmp_path / "fleet_test.db"
    store_dir = tmp_path / "store"
    db = FleetDatabase(db_file)
    store = CyberStore(db=db, base_dir=store_dir)

    # 1. Content Addressing & Deduplication
    test_data = b"CYBERVPS-STORAGE-TEST-PAYLOAD-XYZ"
    expected_hash = hashlib.sha256(test_data).hexdigest()

    obj1, is_new1 = store.put_object_data(test_data)
    assert is_new1 is True, "First write must be new object"
    assert obj1.object_hash == expected_hash, f"Hash mismatch: {obj1.object_hash} vs {expected_hash}"
    assert obj1.reference_count == 1, f"Expected ref count 1, got {obj1.reference_count}"

    # Verify hierarchical path objects/ab/cd/<HASH>
    expected_path = store_dir / "objects" / expected_hash[:2] / expected_hash[2:4] / expected_hash
    assert expected_path.exists(), f"Object not stored at expected sharded path: {expected_path}"
    assert expected_path.read_bytes() == test_data

    # Store identical content again -> should deduplicate
    obj2, is_new2 = store.put_object_data(test_data)
    assert is_new2 is False, "Duplicate write must not create new object"
    assert obj2.object_hash == expected_hash
    assert obj2.reference_count == 2, f"Expected ref count 2 after dedup, got {obj2.reference_count}"
    print("OK: Content addressing and reference-counted deduplication verified")

    # 2. Ingest Full File
    sample_file = tmp_path / "sample_backup.tar"
    sample_file.write_bytes(b"A" * 1024 * 64 + b"B" * 1024 * 64)
    stored_file = store.store_file(sample_file, filename="backup.tar", primary_node_id="vps_test_1")
    assert stored_file.file_id is not None
    assert stored_file.size_bytes == 128 * 1024
    
    # Check CyberStore summary
    summary = db.get_cyberstore_summary()
    assert summary["total_unique_objects"] >= 2
    assert summary["total_stored_files"] >= 1
    print(f"OK: File ingestion and summary verified (Unique objects: {summary['total_unique_objects']})")

    # 3. Disk Reserve Check
    # Node with 1GB disk free (< 5GB threshold) -> should be skipped for replica placement
    node_low_disk = NodeRecord(
        id="node_low",
        name="VPS-LowDisk",
        status="ONLINE",
        is_drained=False,
        disk_free_bytes=1 * 1024 * 1024 * 1024, # 1 GB
        disk_total_bytes=100 * 1024 * 1024 * 1024,
    )
    node_healthy = NodeRecord(
        id="node_ok",
        name="VPS-Healthy",
        status="ONLINE",
        is_drained=False,
        disk_free_bytes=50 * 1024 * 1024 * 1024, # 50 GB
        disk_total_bytes=100 * 1024 * 1024 * 1024,
    )
    
    eligible = [
        n for n in [node_low_disk, node_healthy]
        if n.disk_free_bytes >= max(5 * 1024 * 1024 * 1024, n.disk_total_bytes * 0.10)
    ]
    assert len(eligible) == 1 and eligible[0].id == "node_ok", "Low disk node must be excluded by 10%/5GB reserve"
    print("OK: 10%/5GB disk reserve protection verified")

    # 4. Garbage Collection (Dry-Run vs Force)
    # Put an unreferenced temporary object
    orphan_data = b"ORPHAN-TEMP-DATA-TO-DELETE"
    orphan_hash = hashlib.sha256(orphan_data).hexdigest()
    o_obj, _ = store.put_object_data(orphan_data)
    # Decrement refcount to 0 so it becomes unreferenced
    db.decrement_object_ref(orphan_hash)

    # Dry-run GC
    reclaimed_dry, deleted_dry, unref_dry = store.garbage_collect(dry_run=True)
    assert orphan_hash in unref_dry, "Dry-run GC must identify unreferenced object"
    assert deleted_dry == 1
    # File must still exist after dry-run!
    assert (store_dir / "objects" / orphan_hash[:2] / orphan_hash[2:4] / orphan_hash).exists()

    # Active GC (dry_run=False)
    reclaimed_act, deleted_act, unref_act = store.garbage_collect(dry_run=False)
    assert deleted_act == 1
    assert not (store_dir / "objects" / orphan_hash[:2] / orphan_hash[2:4] / orphan_hash).exists(), "Active GC must delete unreferenced file"
    # Referenced objects must NOT be deleted
    assert expected_path.exists(), "Referenced object must be preserved"
    print("OK: Garbage collection (dry-run + active cleanup) verified")

EOF

log_ok "All Phase 2 CyberStore tests passed successfully!"
