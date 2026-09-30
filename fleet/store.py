"""
Phase 2: CyberStore — Content-Addressed Distributed Storage Engine.
Implements SHA-256 content addressing, deduplication, replica placement, background repair, and safe GC.
"""
import hashlib
import os
from pathlib import Path
import shutil
import time
from typing import Any, Dict, List, Optional, Tuple

from fleet.database import FleetDatabase
from fleet.models import NodeRecord, StorageObject, StorageReplica, StoredFile


class CyberStore:
    def __init__(self, db: FleetDatabase, base_dir: Optional[Path] = None):
        self.db = db
        if base_dir:
            self.base_dir = Path(base_dir)
        else:
            state_home = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
            self.base_dir = Path(state_home) / "cybervps" / "store"
        self.objects_dir = self.base_dir / "objects"
        self.objects_dir.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _get_object_path(self, object_hash: str) -> Path:
        """Derive 2-level hierarchical sharded directory path: objects/ab/cd/<HASH>."""
        prefix1 = object_hash[:2]
        prefix2 = object_hash[2:4]
        return self.objects_dir / prefix1 / prefix2 / object_hash

    def put_object_data(self, data: bytes, pinned: bool = False) -> Tuple[StorageObject, bool]:
        """
        Store binary data by SHA-256 hash.
        If hash already exists, deduplicate (increment reference count, do not re-write).
        Returns (StorageObject, is_new).
        """
        h = hashlib.sha256(data).hexdigest()
        dest = self._get_object_path(h)
        
        is_new = False
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temp_dest = dest.with_suffix(".tmp")
            with open(temp_dest, "wb") as f:
                f.write(data)
            temp_dest.rename(dest)
            is_new = True

        obj = self.db.upsert_storage_object(h, len(data), pinned=pinned)
        return obj, is_new

    def put_object_file(self, src_file: Path, pinned: bool = False) -> Tuple[StorageObject, bool]:
        """
        Stream a file into content-addressed storage.
        Deduplicates if SHA-256 hash matches an existing object.
        """
        if not src_file.exists():
            raise FileNotFoundError(f"Source file not found: {src_file}")

        # Compute SHA-256 streaming
        hasher = hashlib.sha256()
        with open(src_file, "rb") as f:
            while True:
                buf = f.read(128 * 1024)
                if not buf:
                    break
                hasher.update(buf)
        h = hasher.hexdigest()
        size = src_file.stat().st_size
        dest = self._get_object_path(h)

        is_new = False
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(src_file, dest)
            is_new = True

        obj = self.db.upsert_storage_object(h, size, pinned=pinned)
        return obj, is_new

    def get_object_path(self, object_hash: str) -> Optional[Path]:
        """Get local file path of a content-addressed object if present."""
        p = self._get_object_path(object_hash)
        return p if p.exists() else None

    def store_file(
        self,
        file_path: Path,
        filename: Optional[str] = None,
        replication_factor: int = 2,
        primary_node_id: str = "local"
    ) -> StoredFile:
        """
        Ingest a file into CyberStore, registering chunks and replicas.
        """
        file_path = Path(file_path)
        name = filename or file_path.name
        size = file_path.stat().st_size

        # Ingest whole object
        obj, _ = self.put_object_file(file_path)
        
        # Register primary replica
        rel_path = str(self._get_object_path(obj.object_hash).relative_to(self.base_dir))
        self.db.add_storage_replica(obj.object_hash, primary_node_id, rel_path, size)

        file_id = f"file_{hashlib.md5((name + str(time.time())).encode()).hexdigest()[:12]}"
        chunks = [{
            "chunk_index": 0,
            "object_hash": obj.object_hash,
            "start_byte": 0,
            "end_byte": max(0, size - 1)
        }]

        self.db.create_stored_file(
            file_id=file_id,
            filename=name,
            size_bytes=size,
            final_hash=obj.object_hash,
            replication_factor=replication_factor,
            chunks=chunks
        )

        return StoredFile(
            file_id=file_id,
            filename=name,
            size_bytes=size,
            final_hash=obj.object_hash,
            replication_factor=replication_factor,
            created_at=time.time(),
            status="HEALTHY"
        )

    def select_replica_nodes(
        self,
        object_hash: str,
        desired_replicas: int,
        online_nodes: List[NodeRecord],
        required_size: int
    ) -> List[NodeRecord]:
        """
        Select best target nodes to place additional replicas.
        Avoids placing on nodes that already hold a replica or have low disk reserve (<10% or <5GB).
        """
        existing_reps = {r["node_id"] for r in self.db.get_storage_replicas(object_hash)}
        needed = max(0, desired_replicas - len(existing_reps))
        if needed <= 0:
            return []

        candidates = []
        for n in online_nodes:
            if n.id in existing_reps or getattr(n, "is_drained", False):
                continue
            # Reserve 10% disk or minimum 5GB
            reserve = max(5 * 1024 * 1024 * 1024, int(n.disk_total_bytes * 0.10))
            if n.disk_free_bytes >= (required_size + reserve):
                candidates.append(n)

        # Sort candidates by most free disk headroom and reliability
        candidates.sort(key=lambda x: (x.disk_free_bytes, x.reliability_score), reverse=True)
        return candidates[:needed]

    def reconcile_replication(self, online_nodes: List[NodeRecord]) -> Dict[str, Any]:
        """
        Background maintenance task: finds under-replicated files and identifies placement targets.
        """
        under_rep = self.db.get_under_replicated_files()
        actions = []
        for f in under_rep:
            desired = f.get("replication_factor", 2)
            for c in f.get("chunks", []):
                targets = self.select_replica_nodes(c["object_hash"], desired, online_nodes, f["size_bytes"])
                if targets:
                    actions.append({
                        "file_id": f["file_id"],
                        "filename": f["filename"],
                        "object_hash": c["object_hash"],
                        "target_nodes": [t.id for t in targets]
                    })
        return {
            "under_replicated_count": len(under_rep),
            "rebalance_actions": actions
        }

    def rebalance_replicas(self, active_nodes: Optional[List[NodeRecord]] = None) -> int:
        """
        Reconcile and rebalance replicas across active nodes.
        Returns count of rebalance / repair actions planned.
        """
        if active_nodes is None:
            active_nodes = [NodeRecord(**n) for n in self.db.list_nodes() if n["status"] == "ONLINE" and not n.get("is_drained")]
        res = self.reconcile_replication(active_nodes)
        return len(res.get("rebalance_actions", []))

    def garbage_collect(self, dry_run: bool = True) -> Tuple[int, int, List[str]]:
        """
        Reclaim unreferenced objects (reference_count <= 0).
        Safely deletes disk files when dry_run is False.
        Returns: (reclaimed_bytes, deleted_count, unreferenced_hashes)
        """
        gc_result = self.db.garbage_collect_objects(dry_run=dry_run)
        hashes = gc_result.get("hashes", [])
        freed_bytes = gc_result.get("reclaimable_bytes", 0)
        deleted_files = len(hashes) if dry_run else 0

        if not dry_run:
            deleted_files = 0
            for h in hashes:
                p = self._get_object_path(h)
                if p.exists():
                    try:
                        p.unlink()
                        deleted_files += 1
                        # Clean up empty parent directories
                        if p.parent.exists() and not os.listdir(p.parent):
                            p.parent.rmdir()
                        if p.parent.parent.exists() and not os.listdir(p.parent.parent):
                            p.parent.parent.rmdir()
                    except Exception:
                        pass
        return freed_bytes, deleted_files, hashes
