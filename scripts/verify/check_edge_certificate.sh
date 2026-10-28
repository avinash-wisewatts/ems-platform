#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS -- edge TLS certificate health (ADR-023)
#
# Read-only: one TLS handshake to the public endpoint, exactly as a browser
# makes it (no SNI for an IP-address host; edge/Caddyfile default_sni). It
# never touches the host, Caddy, its storage or the ACME account, and never
# triggers a renewal.
#
#   check_edge_certificate.sh <host> [port] [min_hours]
#
# PASS when the handshake succeeds, the chain verifies against the system
# trust store for <host> (IP address or hostname), and the certificate is
# valid for at least <min_hours> more hours (default 48).
#
# Why 48 h: the staging customer certificate is a Let's Encrypt 6-day
# "shortlived" IP certificate. Caddy renews it inside the ACME Renewal Info
# window (about 3 days before expiry) and otherwise once a third of its
# lifetime remains (about 53 h). Under 48 h left therefore means renewal has
# already failed, with two days still to act before browsers refuse the
# site (HSTS leaves no click-through).
#
# Exit 0 = PASS, 1 = FAIL, 2 = usage.
# ============================================================

set -uo pipefail

host="${1:-}"
port="${2:-443}"
min_hours="${3:-48}"

if [[ -z "${host}" || ! "${port}" =~ ^[0-9]+$ || ! "${min_hours}" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 <host> [port] [min_hours]" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    target=(-verify_ip "${host}")
else
    target=(-servername "${host}" -verify_hostname "${host}")
fi

summary() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

fail() {
    echo "[FAIL] $1"
    summary "**FAIL** -- $1"
    exit 1
}

echo "Edge certificate check: ${host}:${port}, at least ${min_hours} h of validity required ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

if ! echo | timeout 30 openssl s_client -connect "${host}:${port}" "${target[@]}" -verify_return_error \
        > "${work}/handshake" 2>&1; then
    grep -iE "verify error|errno|alert|refused|timed out|unable" "${work}/handshake" | head -5
    fail "TLS handshake or certificate verification failed for ${host}:${port}."
fi
echo "[PASS] TLS handshake and chain verification for ${host}."

sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{p;/-----END CERTIFICATE-----/q}' \
    "${work}/handshake" > "${work}/leaf.pem"
[[ -s "${work}/leaf.pem" ]] || fail "no certificate in the server response."

not_after="$(openssl x509 -in "${work}/leaf.pem" -noout -enddate | cut -d= -f2)"
issuer="$(openssl x509 -in "${work}/leaf.pem" -noout -issuer | sed 's/^issuer=//')"
hours_left=$(( ( $(date -u -d "${not_after}" +%s) - $(date -u +%s) ) / 3600 ))
echo "       issuer:    ${issuer}"
echo "       not after: ${not_after} (${hours_left} h left)"

if ! openssl x509 -in "${work}/leaf.pem" -noout -checkend $(( min_hours * 3600 )) > /dev/null; then
    fail "certificate for ${host} expires ${not_after} (${hours_left} h left, under ${min_hours} h): automatic renewal has not happened."
fi
echo "[PASS] certificate valid for ${hours_left} h (>= ${min_hours} h)."
summary "**PASS** -- ${host}: ${issuer}, expires ${not_after} (${hours_left} h left)."
exit 0
