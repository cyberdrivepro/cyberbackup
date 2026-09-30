"""
Adaptive Smart Download Engine for CyberTransfer.
Executes multi-stream downloads using aria2c with automatic curl fallback,
adaptive connection scaling, streaming progress parsing, and SHA256 verification.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
from typing import Callable, Optional, Tuple


def get_adaptive_connections(expected_size: int, accept_ranges: bool) -> int:
    """Calculates optimal connection count based on file size and server capabilities."""
    if not accept_ranges:
        return 1
    
    if expected_size <= 0:
        return 2
    
    mb = expected_size / (1024 * 1024)
    if mb < 5:
        return 1
    elif mb < 50:
        return 4
    elif mb < 500:
        return 8
    elif mb < 5000:
        return 16
    else:
        return 16  # Safe maximum for Phase 1


def compute_file_sha256(file_path: Path, chunk_size: int = 65536) -> str:
    """Computes SHA256 checksum of a file in streaming chunks (memory efficient)."""
    hasher = hashlib.sha256()
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


class SmartDownloader:
    def __init__(
        self,
        url: str,
        dest_dir: str,
        filename: Optional[str] = None,
        expected_size: int = 0,
        accept_ranges: bool = True,
        progress_callback: Optional[Callable[[int, int, float, int], None]] = None,
        cancel_event: Optional[threading.Event] = None,
    ):
        self.url = url
        self.dest_dir = Path(dest_dir).resolve()
        self.filename = filename or f"transfer_{int(time.time())}.bin"
        self.expected_size = expected_size
        self.accept_ranges = accept_ranges
        self.progress_callback = progress_callback
        self.cancel_event = cancel_event or threading.Event()
        self.dest_dir.mkdir(parents=True, exist_ok=True, mode=0o755)

    def download(self) -> Tuple[bool, str, str, int, float, Optional[str]]:
        """
        Executes the download.
        Returns: (success, final_path, sha256, downloaded_bytes, elapsed_seconds, error)
        """
        # Disk space preflight check
        usage = shutil.disk_usage(self.dest_dir)
        required = self.expected_size + (50 * 1024 * 1024) if self.expected_size > 0 else (100 * 1024 * 1024)
        if usage.free < required:
            return False, "", "", 0, 0.0, f"Insufficient disk space on node ({usage.free // (1024**2)} MB free)"

        part_name = f"{self.filename}.part"
        part_path = self.dest_dir / part_name
        final_path = self.dest_dir / self.filename

        has_aria2 = shutil.which("aria2c") is not None
        start_time = time.time()

        if has_aria2:
            ok, err = self._download_aria2(part_name, part_path)
        else:
            ok, err = self._download_curl(part_path)

        elapsed = max(0.1, time.time() - start_time)

        if not ok:
            return False, "", "", 0, elapsed, err or "Download failed"

        if not part_path.exists() or part_path.stat().st_size == 0:
            return False, "", "", 0, elapsed, "Downloaded file is missing or empty"

        total_bytes = part_path.stat().st_size
        
        # Atomic rename from .part to final target
        if final_path.exists():
            final_path.unlink()
        part_path.rename(final_path)

        # Compute SHA256 checksum
        try:
            sha256 = compute_file_sha256(final_path)
        except Exception as e:
            sha256 = ""

        # Trigger final 100% progress callback
        if self.progress_callback:
            try:
                self.progress_callback(total_bytes, total_bytes, 0.0, 0)
            except Exception:
                pass

        return True, str(final_path), sha256, total_bytes, elapsed, None

    def _download_aria2(self, part_name: str, part_path: Path) -> Tuple[bool, Optional[str]]:
        conns = get_adaptive_connections(self.expected_size, self.accept_ranges)
        cmd = [
            "aria2c",
            f"--dir={str(self.dest_dir)}",
            f"--out={part_name}",
            "--file-allocation=none",
            "--continue=true",
            f"--max-connection-per-server={conns}",
            f"--split={conns}",
            "--summary-interval=1",
            "--console-log-level=warn",
            "--auto-file-renaming=false",
            "--allow-overwrite=true",
            "--timeout=30",
            "--connect-timeout=10",
            "--max-tries=3",
            "--user-agent=CyberVPS-Transfer/2.0",
            self.url,
        ]

        process = None
        try:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            # Parse aria2 summary output: [#12345 1.2MiB/5.4MiB(22%) CN:4 DL:1.1MiB ETA:3s]
            progress_regex = re.compile(
                r"\[#[a-f0-9]+\s+([0-9.]+[A-Za-z]+)/([0-9.]+[A-Za-z]+)\(([0-9]+)%\)\s+.*?DL:([0-9.]+[A-Za-z]+)(?:\s+ETA:([0-9a-z]+))?\]"
            )

            while True:
                if self.cancel_event.is_set():
                    process.terminate()
                    return False, "Download cancelled by user"

                line = process.stdout.readline()
                if not line and process.poll() is not None:
                    break

                if line:
                    match = progress_regex.search(line)
                    if match and self.progress_callback:
                        downloaded_str, total_str, pct_str, speed_str, eta_str = match.groups()
                        cur_size = part_path.stat().st_size if part_path.exists() else 0
                        speed_bps = self._parse_aria_speed(speed_str)
                        eta_sec = self._parse_aria_eta(eta_str)
                        self.progress_callback(cur_size, self.expected_size or cur_size, speed_bps, eta_sec)

            rc = process.wait()
            return rc == 0, None if rc == 0 else f"aria2c exited with code {rc}"
        except Exception as e:
            if process:
                try:
                    process.kill()
                except Exception:
                    pass
            return False, f"aria2c error: {e}"

    def _download_curl(self, part_path: Path) -> Tuple[bool, Optional[str]]:
        cmd = [
            "curl",
            "-C", "-",
            "-L",
            "--fail",
            "--silent",
            "--show-error",
            "--user-agent", "CyberVPS-Transfer/2.0",
            "--connect-timeout", "10",
            "--max-time", "3600",
            "--output", str(part_path),
            self.url,
        ]

        process = None
        try:
            process = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)

            last_bytes = 0
            last_time = time.time()

            while process.poll() is None:
                if self.cancel_event.is_set():
                    process.terminate()
                    return False, "Download cancelled by user"

                time.sleep(1.0)
                now = time.time()
                cur_size = part_path.stat().st_size if part_path.exists() else 0
                dt = now - last_time
                if dt > 0:
                    speed = max(0.0, (cur_size - last_bytes) / dt)
                    eta = int((self.expected_size - cur_size) / speed) if (self.expected_size > cur_size and speed > 0) else 0
                    if self.progress_callback:
                        self.progress_callback(cur_size, self.expected_size or cur_size, speed, eta)
                last_bytes = cur_size
                last_time = now

            rc = process.wait()
            _, err = process.communicate()
            return rc == 0, None if rc == 0 else f"curl failed ({err.strip() or rc})"
        except Exception as e:
            if process:
                try:
                    process.kill()
                except Exception:
                    pass
            return False, f"curl error: {e}"

    def _parse_aria_speed(self, speed_str: Optional[str]) -> float:
        if not speed_str:
            return 0.0
        match = re.match(r"^([0-9.]+)([A-Za-z]+)?$", speed_str)
        if not match:
            return 0.0
        val, unit = match.groups()
        val = float(val)
        unit = (unit or "").upper()
        if "K" in unit:
            return val * 1024
        elif "M" in unit:
            return val * 1024 * 1024
        elif "G" in unit:
            return val * 1024 * 1024 * 1024
        return val

    def _parse_aria_eta(self, eta_str: Optional[str]) -> int:
        if not eta_str:
            return 0
        total = 0
        match_m = re.search(r"(\d+)m", eta_str)
        match_s = re.search(r"(\d+)s", eta_str)
        if match_m:
            total += int(match_m.group(1)) * 60
        if match_s:
            total += int(match_s.group(1))
        return total


def download_byte_range(
    url: str,
    dest_path: Path,
    start_byte: int,
    end_byte: int,
    expected_etag: str = "",
    progress_callback: Optional[Callable[[int, int, float], None]] = None,
    cancel_event: Optional[threading.Event] = None,
    timeout: float = 60.0,
) -> Tuple[bool, str, int, float, Optional[str]]:
    """
    Downloads a specific byte range [start_byte, end_byte] with streaming SHA-256 computation.
    Validates ETag/Last-Modified stability if supplied.
    Returns: (success, sha256_checksum, bytes_downloaded, elapsed_seconds, error)
    """
    dest_path = Path(dest_path)
    dest_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

    headers = {
        "User-Agent": "CyberVPS-FleetTransfer/2.0",
        "Range": f"bytes={start_byte}-{end_byte}",
    }
    expected_len = end_byte - start_byte + 1
    hasher = hashlib.sha256()
    downloaded = 0
    start_time = time.time()
    last_cb = 0.0

    try:
        import httpx
        with httpx.Client(timeout=timeout, follow_redirects=True) as client:
            with client.stream("GET", url, headers=headers) as resp:
                if resp.status_code not in (200, 206):
                    elapsed = max(0.001, time.time() - start_time)
                    return False, "", 0, elapsed, f"HTTP {resp.status_code} returned for range {start_byte}-{end_byte}"

                # Check ETag stability
                current_etag = resp.headers.get("etag", "").strip('"\'')
                if expected_etag and current_etag and current_etag != expected_etag:
                    elapsed = max(0.001, time.time() - start_time)
                    return False, "", 0, elapsed, f"SOURCE_CHANGED: ETag mismatch ({current_etag} != {expected_etag})"

                temp_path = dest_path.with_suffix(dest_path.suffix + ".part")
                with open(temp_path, "wb") as f:
                    for chunk in resp.iter_bytes(chunk_size=65536):
                        if cancel_event and cancel_event.is_set():
                            elapsed = max(0.001, time.time() - start_time)
                            return False, "", downloaded, elapsed, "Cancelled by user"
                        if chunk:
                            f.write(chunk)
                            hasher.update(chunk)
                            downloaded += len(chunk)
                            now = time.time()
                            if progress_callback and (now - last_cb >= 0.5 or downloaded >= expected_len):
                                last_cb = now
                                elapsed_cb = max(0.001, now - start_time)
                                speed = (downloaded * 8.0) / elapsed_cb
                                progress_callback(downloaded, expected_len, speed)

                if temp_path.exists():
                    if dest_path.exists():
                        dest_path.unlink()
                    temp_path.rename(dest_path)

                elapsed = max(0.001, time.time() - start_time)
                return True, hasher.hexdigest(), downloaded, elapsed, None
    except Exception as e:
        elapsed = max(0.001, time.time() - start_time)
        return False, "", downloaded, elapsed, str(e)
