"""
Strict Server-Side Request Forgery (SSRF) Protection Engine.
Validates URLs, resolves DNS, blocks private/cloud-metadata/loopback IPs,
and guards against dangerous schemes and malicious redirects.
"""
import ipaddress
import re
import socket
from typing import List, Optional, Tuple
import urllib.parse

# Cloud metadata addresses and special disallowed hostnames
METADATA_IPS = {
    "169.254.169.254",  # AWS / GCP / Azure / OpenStack metadata
    "100.100.100.200",  # Alibaba Cloud metadata
    "fd00:ec2::254",    # AWS IPv6 metadata
}

DISALLOWED_HOSTS = {
    "localhost",
    "localhost.localdomain",
    "metadata.google.internal",
    "instance-data",
}

# Special reserved IP networks (IPv4 and IPv6)
DISALLOWED_NETWORKS = [
    ipaddress.ip_network("0.0.0.0/8"),          # Current network (only valid as source address)
    ipaddress.ip_network("10.0.0.0/8"),          # RFC 1918 Private
    ipaddress.ip_network("100.64.0.0/10"),       # Shared Address Space (CGNAT)
    ipaddress.ip_network("127.0.0.0/8"),         # Loopback
    ipaddress.ip_network("169.254.0.0/16"),      # Link Local
    ipaddress.ip_network("172.16.0.0/12"),       # RFC 1918 Private
    ipaddress.ip_network("192.0.0.0/24"),        # IETF Protocol Assignments
    ipaddress.ip_network("192.0.2.0/24"),        # TEST-NET-1 (Documentation)
    ipaddress.ip_network("192.168.0.0/16"),      # RFC 1918 Private
    ipaddress.ip_network("198.18.0.0/15"),       # Network Interconnect Device Benchmark Testing
    ipaddress.ip_network("198.51.100.0/24"),     # TEST-NET-2 (Documentation)
    ipaddress.ip_network("203.0.113.0/24"),      # TEST-NET-3 (Documentation)
    ipaddress.ip_network("224.0.0.0/4"),         # Multicast
    ipaddress.ip_network("240.0.0.0/4"),         # Reserved for Future Use
    ipaddress.ip_network("255.255.255.255/32"),  # Broadcast
    # IPv6
    ipaddress.ip_network("::/128"),              # Unspecified
    ipaddress.ip_network("::1/128"),             # Loopback
    ipaddress.ip_network("fc00::/7"),            # Unique Local Unicast (ULA)
    ipaddress.ip_network("fe80::/10"),           # Link-Local Unicast
    ipaddress.ip_network("ff00::/8"),            # Multicast
]


def is_ip_disallowed(ip: ipaddress.IPv4Address | ipaddress.IPv6Address, allow_private: bool = False) -> Tuple[bool, str]:
    """Checks whether an IP address belongs to any forbidden subnet or metadata endpoint."""
    ip_str = str(ip)
    if ip_str in METADATA_IPS:
        return True, f"Cloud metadata endpoint blocked ({ip_str})"
    
    if not allow_private:
        if ip.is_loopback:
            return True, f"Loopback address blocked ({ip_str})"
        
        if ip.is_private:
            return True, f"Private RFC 1918 address blocked ({ip_str})"
        
        for net in DISALLOWED_NETWORKS:
            if ip in net:
                return True, f"Reserved / disallowed network blocked ({ip_str} in {net})"
    
    return False, ""


def resolve_hostname_ips(hostname: str) -> List[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    """Resolves all IPv4 and IPv6 addresses for a hostname."""
    resolved_ips = []
    try:
        # socket.getaddrinfo returns a list of 5-tuples: (family, type, proto, canonname, sockaddr)
        addrinfo = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        for item in addrinfo:
            sockaddr = item[4]
            ip_str = sockaddr[0]
            try:
                ip_obj = ipaddress.ip_address(ip_str)
                if ip_obj not in resolved_ips:
                    resolved_ips.append(ip_obj)
            except ValueError:
                pass
    except (socket.gaierror, socket.herror, OSError):
        pass
    return resolved_ips


def validate_url(url: str, allow_private: bool = False) -> Tuple[bool, str, Optional[str]]:
    """
    Validates a URL against strict SSRF constraints.
    Returns: (is_valid, reason, canonical_url)
    """
    if not url or not isinstance(url, str):
        return False, "URL is empty or not a string", None
    
    # Check for CRLF injection in URL
    if "\r" in url or "\n" in url or "\t" in url:
        return False, "URL contains disallowed control characters (CRLF)", None
    
    # Strip whitespace
    url = url.strip()
    
    try:
        parsed = urllib.parse.urlsplit(url)
    except Exception as e:
        return False, f"Failed to parse URL: {e}", None
    
    # 1. Scheme validation: strictly http or https
    scheme = parsed.scheme.lower()
    if scheme not in ("http", "https"):
        return False, f"Disallowed URL scheme '{parsed.scheme}'. Only HTTP and HTTPS are permitted.", None
    
    # 2. Hostname validation
    hostname = parsed.hostname
    if not hostname:
        return False, "URL has missing or empty hostname", None
    
    hostname_lower = hostname.lower()
    if not allow_private and hostname_lower in DISALLOWED_HOSTS:
        return False, f"Disallowed target host: '{hostname}'", None
    
    # Authority credentials check: do not allow user:pass@host in public URL
    if parsed.username or parsed.password:
        return False, "URLs with embedded credentials in authority are not allowed", None
    
    # Port validation
    if parsed.port:
        if not (1 <= parsed.port <= 65535):
            return False, f"Invalid port number: {parsed.port}", None
        # Disallow well-known internal ports if needed (e.g. redis 6379, ssh 22)
        if not allow_private and parsed.port in (22, 25, 6379, 11211, 2375, 2376, 9200):
            return False, f"Connection to port {parsed.port} blocked by safety policy", None
    
    # 3. Direct IP address check or DNS resolution
    try:
        # If hostname is a literal IP address
        direct_ip = ipaddress.ip_address(hostname)
        disallowed, reason = is_ip_disallowed(direct_ip, allow_private=allow_private)
        if disallowed:
            return False, reason, None
        return True, "OK", url
    except ValueError:
        # Hostname is a domain name, resolve via DNS
        pass
    
    resolved_ips = resolve_hostname_ips(hostname)
    if not resolved_ips:
        return False, f"Failed to resolve DNS for hostname '{hostname}'", None
    
    for ip in resolved_ips:
        disallowed, reason = is_ip_disallowed(ip, allow_private=allow_private)
        if disallowed:
            return False, f"DNS resolution blocked: {hostname} resolves to {reason}", None
    
    canonical_url = urllib.parse.urlunsplit(parsed)
    return True, "OK", canonical_url
