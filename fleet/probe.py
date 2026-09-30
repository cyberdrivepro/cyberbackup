"""
Safe URL probe engine for CyberTransfer.
Inspects HTTP headers, resolves redirect chains with per-hop SSRF validation,
and extracts file metadata without downloading whole files.
"""
import os
import re
import time
from typing import List, Optional, Tuple
import urllib.error
import urllib.parse
import urllib.request

from fleet.models import ProbeResult
from fleet.ssrf import validate_url


def extract_filename_from_headers(content_disposition: Optional[str], url: str) -> str:
    """Extracts sanitized filename from Content-Disposition header or URL path."""
    if content_disposition:
        # Check for RFC 5987 filename* (UTF-8)
        match_star = re.search(r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)", content_disposition)
        if match_star:
            raw = urllib.parse.unquote(match_star.group(1).strip().strip('"\''))
            sanitized = re.sub(r'[\\/*?:"<>|]', "", os.path.basename(raw)).strip()
            if sanitized:
                return sanitized
        
        # Check standard filename=
        match = re.search(r'filename\s*=\s*("([^"]+)"|([^;]+))', content_disposition)
        if match:
            raw = match.group(2) or match.group(3) or ""
            raw = raw.strip().strip('"\'')
            sanitized = re.sub(r'[\\/*?:"<>|]', "", os.path.basename(raw)).strip()
            if sanitized:
                return sanitized
    
    # Fallback to URL path
    parsed = urllib.parse.urlsplit(url)
    path_name = os.path.basename(urllib.parse.unquote(parsed.path))
    sanitized = re.sub(r'[\\/*?:"<>|]', "", path_name).strip()
    if sanitized:
        return sanitized
    
    # Generic default fallback
    return f"download_{int(time.time())}.bin"


class SSRFSafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allow_private: bool = False, max_redirects: int = 8):
        super().__init__()
        self.allow_private = allow_private
        self.max_redirects = max_redirects
        self.redirect_count = 0
        self.redirect_chain: List[str] = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.redirect_count += 1
        if self.redirect_count > self.max_redirects:
            raise urllib.error.HTTPError(
                req.full_url, code, f"Exceeded maximum redirects ({self.max_redirects})", headers, fp
            )
        
        # Resolve relative redirect URLs
        resolved_url = urllib.parse.urljoin(req.full_url, newurl)
        self.redirect_chain.append(resolved_url)
        
        # Strict SSRF re-check on redirect target
        valid, reason, _ = validate_url(resolved_url, allow_private=self.allow_private)
        if not valid:
            raise urllib.error.HTTPError(
                resolved_url, 403, f"SSRF redirect blocked: {reason}", headers, fp
            )
        
        return super().redirect_request(req, fp, code, msg, headers, resolved_url)


def probe_url(
    url: str,
    max_redirects: int = 8,
    timeout: float = 12.0,
    allow_private: bool = False
) -> ProbeResult:
    """
    Performs a safe, low-bandwidth probe of the target URL.
    Returns ProbeResult with file metadata or error.
    """
    valid, reason, canonical = validate_url(url, allow_private=allow_private)
    if not valid:
        return ProbeResult(
            valid=False,
            url=url,
            final_url=url,
            error=f"SSRF validation failed: {reason}"
        )
    
    target_url = canonical or url
    redirect_handler = SSRFSafeRedirectHandler(allow_private=allow_private, max_redirects=max_redirects)
    opener = urllib.request.build_opener(redirect_handler)
    
    headers = {
        "User-Agent": "CyberVPS-Transfer/2.0 (Compatible; +https://github.com/cyberdrivepro/cyberbackup)",
        "Accept": "*/*",
    }
    
    # 1. Attempt HTTP HEAD request first
    head_req = urllib.request.Request(target_url, headers=headers, method="HEAD")
    try:
        with opener.open(head_req, timeout=timeout) as resp:
            final_url = resp.geturl()
            status = resp.status
            resp_headers = resp.headers
            
            content_length = int(resp_headers.get("Content-Length", 0) or 0)
            content_type = resp_headers.get("Content-Type", "application/octet-stream")
            accept_ranges = "bytes" in (resp_headers.get("Accept-Ranges", "") or "").lower()
            etag = (resp_headers.get("ETag", "") or "").strip('"\'')
            last_modified = resp_headers.get("Last-Modified", "") or ""
            disposition = resp_headers.get("Content-Disposition")
            filename = extract_filename_from_headers(disposition, final_url)
            
            return ProbeResult(
                valid=True,
                url=url,
                final_url=final_url,
                http_status=status,
                content_type=content_type,
                expected_size=content_length,
                accept_ranges=accept_ranges,
                etag=etag,
                last_modified=last_modified,
                filename=filename,
            )
    except urllib.error.HTTPError as e:
        # If HEAD method is rejected (405 / 403 / 501), fallback to GET with Range: bytes=0-0
        if e.code in (403, 405, 501):
            pass
        else:
            return ProbeResult(
                valid=False,
                url=url,
                final_url=target_url,
                http_status=e.code,
                error=f"HTTP probe failed with status {e.code}: {e.reason}"
            )
    except Exception as e:
        return ProbeResult(
            valid=False,
            url=url,
            final_url=target_url,
            error=f"Probe connection error: {e}"
        )
    
    # 2. Fallback: GET with Range: bytes=0-0 (reads only 1 byte)
    range_headers = dict(headers)
    range_headers["Range"] = "bytes=0-0"
    get_req = urllib.request.Request(target_url, headers=range_headers, method="GET")
    try:
        with opener.open(get_req, timeout=timeout) as resp:
            final_url = resp.geturl()
            status = resp.status
            resp_headers = resp.headers
            
            # Read at most 1 byte and close connection immediately
            resp.read(1)
            
            accept_ranges = (status == 206) or ("bytes" in (resp_headers.get("Accept-Ranges", "") or "").lower())
            
            # Content-Range: bytes 0-0/123456789
            content_length = 0
            content_range = resp_headers.get("Content-Range", "")
            if content_range and "/" in content_range:
                try:
                    total_str = content_range.split("/")[-1].strip()
                    if total_str.isdigit():
                        content_length = int(total_str)
                except Exception:
                    pass
            if content_length == 0:
                try:
                    content_length = int(resp_headers.get("Content-Length", 0) or 0)
                except Exception:
                    content_length = 0
            
            content_type = resp_headers.get("Content-Type", "application/octet-stream")
            etag = (resp_headers.get("ETag", "") or "").strip('"\'')
            last_modified = resp_headers.get("Last-Modified", "") or ""
            disposition = resp_headers.get("Content-Disposition")
            filename = extract_filename_from_headers(disposition, final_url)
            
            return ProbeResult(
                valid=True,
                url=url,
                final_url=final_url,
                http_status=status,
                content_type=content_type,
                expected_size=content_length,
                accept_ranges=accept_ranges,
                etag=etag,
                last_modified=last_modified,
                filename=filename,
            )
    except urllib.error.HTTPError as e:
        return ProbeResult(
            valid=False,
            url=url,
            final_url=target_url,
            http_status=e.code,
            error=f"HTTP probe fallback failed: status {e.code} ({e.reason})"
        )
    except Exception as e:
        return ProbeResult(
            valid=False,
            url=url,
            final_url=target_url,
            error=f"Probe error on fallback: {e}"
        )
