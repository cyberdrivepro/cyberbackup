"""
Phase 2: Distributed File Assembler & Concurrent Range Writer.
Writes chunks at byte offsets with direct seek, streaming SHA-256 verification, and atomic finalization.
"""
import hashlib
import os
from pathlib import Path
import threading
from typing import Dict, List, Optional, Tuple, Union

from fleet.models import DownloadChunk


class BurstAssembler:
    """
    Manages local assembly of distributed chunk downloads on the Assembler node.
    Supports both direct target_path construction and job/dest_dir construction.
    """
    def __init__(
        self,
        target_path: Optional[Union[Path, str]] = None,
        expected_size: int = 0,
        job_id: Optional[str] = None,
        total_size: Optional[int] = None,
        dest_dir: Optional[Union[Path, str]] = None,
        filename: Optional[str] = None,
    ):
        if target_path is not None:
            self.target_path = Path(target_path)
            self.expected_size = expected_size or total_size or 0
        else:
            d_dir = Path(dest_dir) if dest_dir else Path("/tmp")
            f_name = filename or f"{job_id or 'download'}.bin"
            self.target_path = d_dir / f_name
            self.expected_size = total_size or expected_size or 0

        self.part_path = self.target_path.with_suffix(self.target_path.suffix + ".part")
        self.job_id = job_id
        self._lock = threading.Lock()
        self._init_part_file()

    def _init_part_file(self):
        """Preallocate / truncate destination file to expected size."""
        self.part_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._lock:
            if not self.part_path.exists():
                with open(self.part_path, "wb") as f:
                    if self.expected_size > 0:
                        # Seek to expected_size - 1 and write a single zero byte to sparse-allocate
                        f.seek(self.expected_size - 1)
                        f.write(b"\0")
                    f.flush()

    def write_chunk(
        self,
        chunk_or_id: Union[DownloadChunk, str, int],
        offset_or_data: Union[int, bytes, None] = None,
        chunk_data: Optional[bytes] = None,
    ) -> Tuple[bool, str, str]:
        """
        Write chunk bytes at the exact start_byte offset.
        Accepts:
          write_chunk(chunk, data)
          or write_chunk(chunk_id, start_byte, data)
        """
        if isinstance(chunk_or_id, DownloadChunk):
            start_byte = chunk_or_id.start_byte
            data = offset_or_data if isinstance(offset_or_data, (bytes, bytearray)) else chunk_data
            expected_length = chunk_or_id.expected_length
        else:
            start_byte = int(offset_or_data) if offset_or_data is not None else 0
            data = chunk_data
            expected_length = len(data) if data is not None else None

        if data is None:
            return False, "", "No chunk data provided"

        if expected_length is not None and len(data) != expected_length:
            return False, "", f"Chunk size mismatch: expected {expected_length}, got {len(data)}"

        chunk_hash = hashlib.sha256(data).hexdigest()

        with self._lock:
            try:
                with open(self.part_path, "r+b") as f:
                    f.seek(start_byte)
                    f.write(data)
                    f.flush()
                return True, chunk_hash, ""
            except Exception as e:
                return False, "", f"Write failed at offset {start_byte}: {e}"

    def write_chunk_from_file(
        self,
        chunk_or_id: Union[DownloadChunk, str, int],
        start_byte_or_file: Union[int, Path, str],
        src_file: Optional[Union[Path, str]] = None,
    ) -> Tuple[bool, str, str]:
        """
        Stream chunk bytes from a downloaded source file directly into the part file at start_byte.
        Accepts:
          write_chunk_from_file(chunk, file_path)
          or write_chunk_from_file(chunk_id, start_byte, file_path)
        """
        if isinstance(chunk_or_id, DownloadChunk):
            start_byte = chunk_or_id.start_byte
            file_path = Path(start_byte_or_file)
            expected_length = chunk_or_id.expected_length
        else:
            start_byte = int(start_byte_or_file)
            file_path = Path(src_file) if src_file else None
            expected_length = None

        if file_path is None or not file_path.exists():
            return False, "", f"Source chunk file does not exist: {file_path}"

        actual_size = file_path.stat().st_size
        if expected_length is not None and actual_size != expected_length:
            return False, "", f"Chunk file size mismatch: expected {expected_length}, got {actual_size}"

        hasher = hashlib.sha256()
        buffer_size = 64 * 1024  # 64KB bounded stream buffer

        with self._lock:
            try:
                with open(file_path, "rb") as sf, open(self.part_path, "r+b") as df:
                    df.seek(start_byte)
                    while True:
                        buf = sf.read(buffer_size)
                        if not buf:
                            break
                        hasher.update(buf)
                        df.write(buf)
                    df.flush()
                return True, hasher.hexdigest(), ""
            except Exception as e:
                return False, "", f"Stream write failed: {e}"

    def finalize(self, expected_sha256: Optional[str] = None) -> Tuple[Path, str]:
        """
        Verify complete assembled file size and compute streaming SHA-256.
        Atomically renames .part -> target_path.
        Returns (target_path, final_sha256).
        Raises RuntimeError or ValueError on error.
        """
        with self._lock:
            if not self.part_path.exists():
                raise RuntimeError(f"Part file not found for finalization: {self.part_path}")

            actual_size = self.part_path.stat().st_size
            if self.expected_size > 0 and actual_size != self.expected_size:
                raise RuntimeError(f"Size mismatch: expected {self.expected_size}, got {actual_size}")

            # Compute streaming SHA-256
            hasher = hashlib.sha256()
            with open(self.part_path, "rb") as f:
                while True:
                    buf = f.read(128 * 1024)
                    if not buf:
                        break
                    hasher.update(buf)
            final_hash = hasher.hexdigest()

            if expected_sha256 and final_hash.lower() != expected_sha256.lower():
                raise ValueError(f"SHA-256 mismatch: expected {expected_sha256}, got {final_hash}")

            # Atomic rename
            if self.target_path.exists():
                self.target_path.unlink()
            self.part_path.rename(self.target_path)
            return self.target_path, final_hash
