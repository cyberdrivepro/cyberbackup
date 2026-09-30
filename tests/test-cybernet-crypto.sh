#!/usr/bin/env bash
# tests/test-cybernet-crypto.sh — RFC 7748 Curve25519 WireGuard Cryptography Tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logging.sh
source "$REPO_DIR/lib/logging.sh"

log_header "Testing RFC 7748 Curve25519 Cryptography & WireGuard Keys"

PYTHONPATH="$REPO_DIR" python3 - << 'EOF'
import base64
from fleet.cybernet import (
    derive_public_key,
    generate_wireguard_client_config,
    generate_wireguard_keypair,
    validate_public_key,
)

# Test 1: Verify RFC 7748 Official Test Vector 1 (Alice's keypair)
alice_priv_hex = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
alice_priv_bytes = bytes.fromhex(alice_priv_hex)
alice_priv_b64 = base64.b64encode(alice_priv_bytes).decode("ascii")

alice_pub_b64 = derive_public_key(alice_priv_b64)
alice_pub_bytes = base64.b64decode(alice_pub_b64)
expected_pub_hex = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"

assert alice_pub_bytes.hex() == expected_pub_hex, (
    f"RFC 7748 test vector mismatch! Got {alice_pub_bytes.hex()}, expected {expected_pub_hex}"
)
print("PASS: RFC 7748 official Curve25519 test vector verified")

# Test 2: Verify RFC 7748 Official Test Vector 2 (Bob's keypair)
bob_priv_hex = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
bob_priv_bytes = bytes.fromhex(bob_priv_hex)
bob_priv_b64 = base64.b64encode(bob_priv_bytes).decode("ascii")

bob_pub_b64 = derive_public_key(bob_priv_b64)
bob_pub_bytes = base64.b64decode(bob_pub_b64)
expected_bob_pub_hex = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"

assert bob_pub_bytes.hex() == expected_bob_pub_hex, (
    f"Bob's keypair test vector mismatch! Got {bob_pub_bytes.hex()}, expected {expected_bob_pub_hex}"
)
print("PASS: Bob RFC 7748 Curve25519 keypair verified")

# Test 3: Dynamic Keypair Generation
priv_b64, pub_b64 = generate_wireguard_keypair()
assert len(priv_b64) == 44, f"WireGuard base64 private key must be 44 chars, got {len(priv_b64)}"
assert len(pub_b64) == 44, f"WireGuard base64 public key must be 44 chars, got {len(pub_b64)}"
assert priv_b64.endswith("="), "WireGuard base64 key must have padding ="
assert pub_b64.endswith("="), "WireGuard base64 key must have padding ="

derived_pub = derive_public_key(priv_b64)
assert derived_pub == pub_b64, f"Derived public key {derived_pub} must match generated public key {pub_b64}"
print("PASS: Dynamic WireGuard keypair generation and mathematical derivation verified")

# Test 4: Key Validation
assert validate_public_key(pub_b64) is True
assert validate_public_key("pub_dummy_gw_key") is False
assert validate_public_key("invalid_base64") is False
assert validate_public_key("") is False
assert validate_public_key(base64.b64encode(b"short").decode()) is False
print("PASS: WireGuard public key validator accurately distinguishes 32-byte keys from dummies")

# Test 5: WireGuard Config Generation rejects dummy or invalid server key
try:
    generate_wireguard_client_config(
        client_private_key="priv",
        client_ip="10.66.0.2",
        gateway_public_key="pub_dummy_gw_key",
        gateway_endpoint="1.2.3.4:51820",
    )
    assert False, "Must reject dummy gateway public key"
except ValueError:
    pass

# Generates valid config with genuine keys
cfg = generate_wireguard_client_config(
    client_private_key="",
    client_ip="10.66.0.2",
    gateway_public_key=pub_b64,
    gateway_endpoint="198.51.100.1:51820",
    dns_servers=["1.1.1.1"],
)
assert "PrivateKey = ${CLIENT_PRIVATE_KEY}" in cfg
assert f"PublicKey = {pub_b64}" in cfg
assert "Endpoint = 198.51.100.1:51820" in cfg
assert "Address = 10.66.0.2/32" in cfg
print("PASS: WireGuard client configuration generation with genuine keys verified")

EOF

log_ok "All RFC 7748 Curve25519 cryptography tests passed successfully!"
