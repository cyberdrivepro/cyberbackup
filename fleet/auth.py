"""
Authentication, Password Hashing, Session Management, and Rate Limiting for CyberFleet.
"""
from datetime import datetime, timezone
import hashlib
import hmac
import os
import secrets
import time
from typing import Dict, Optional, Tuple


def hash_password(password: str) -> str:
    """Hashes password with PBKDF2-HMAC-SHA256 and unique 16-byte salt."""
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100000)
    return f"{salt.hex()}:{dk.hex()}"


def verify_password(password: str, stored_hash: str) -> bool:
    """Verifies password against stored salt:hash in constant time."""
    try:
        parts = stored_hash.split(":")
        if len(parts) != 2:
            return False
        salt = bytes.fromhex(parts[0])
        expected_dk = bytes.fromhex(parts[1])
        actual_dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100000)
        return hmac.compare_digest(expected_dk, actual_dk)
    except Exception:
        return False


class RateLimiter:
    """In-memory IP-based rate limiter for login and sensitive actions."""
    def __init__(self, max_attempts: int = 5, window_seconds: int = 60):
        self.max_attempts = max_attempts
        self.window_seconds = window_seconds
        self.attempts: Dict[str, list] = {}

    def is_allowed(self, client_ip: str) -> bool:
        now = time.time()
        timestamps = self.attempts.get(client_ip, [])
        # Evict old entries
        valid = [t for t in timestamps if now - t < self.window_seconds]
        self.attempts[client_ip] = valid
        return len(valid) < self.max_attempts

    def record_attempt(self, client_ip: str):
        now = time.time()
        if client_ip not in self.attempts:
            self.attempts[client_ip] = []
        self.attempts[client_ip].append(now)

    def reset(self, client_ip: str):
        if client_ip in self.attempts:
            del self.attempts[client_ip]


class SessionManager:
    """Manages secure HTTP session tokens."""
    def __init__(self, session_ttl_seconds: int = 86400):
        self.session_ttl = session_ttl_seconds
        self.sessions: Dict[str, Dict[str, any]] = {}

    def create_session(self, username: str, role: str = "admin") -> str:
        token = secrets.token_urlsafe(32)
        expires_at = time.time() + self.session_ttl
        self.sessions[token] = {
            "username": username,
            "role": role,
            "created_at": time.time(),
            "expires_at": expires_at,
        }
        return token

    def validate_session(self, token: Optional[str]) -> Optional[Dict[str, any]]:
        if not token or token not in self.sessions:
            return None
        session = self.sessions[token]
        if time.time() > session["expires_at"]:
            del self.sessions[token]
            return None
        return session

    def destroy_session(self, token: str):
        if token in self.sessions:
            del self.sessions[token]

    def cleanup_expired(self):
        now = time.time()
        expired = [t for t, s in self.sessions.items() if now > s["expires_at"]]
        for t in expired:
            del self.sessions[t]
