#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- ems-web container smoke test
#
# Runs a built -web image the way compose.yaml runs the `ems-web` service
# (read-only root filesystem, tmpfs for nginx's writable paths,
# no-new-privileges) on a throwaway loopback port and asserts the serving
# contract the admin-portal /app proxy relies on:
#   - the image HEALTHCHECK goes healthy under that hardening
#   - /app, /app/ and client-side routes return the SPA entry, no-store
#   - hashed /app/assets/* are served with immutable caching; missing -> 404
#   - nginx's own redirects are relative (never http://ems-web/...)
#   - optional: the revision label equals the expected Git SHA
#
# Usage:
#   scripts/test/assert_ems_web_container.sh <image> [<expected git sha>]
#
# Local/CI only. Starts and removes one disposable container; touches no
# compose service, database or remote host.
# ============================================================================

IMAGE="${1:?usage: $0 <image> [<expected git sha>]}"
EXPECTED_SHA="${2:-}"
NAME="ems-web-smoke-$$"
failures=0

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

check() {
    local description="$1" ok="$2"
    if [[ "${ok}" == "1" ]]; then
        echo "  PASS  ${description}"
    else
        echo "  FAIL  ${description}"
        failures=$((failures + 1))
    fi
}

docker run -d --name "${NAME}" \
    --read-only \
    --tmpfs /var/cache/nginx --tmpfs /var/run --tmpfs /tmp \
    --security-opt no-new-privileges:true \
    -p 127.0.0.1::80 \
    "${IMAGE}" >/dev/null

port="$(docker port "${NAME}" 80/tcp | head -n1 | sed 's/.*://')"
base="http://127.0.0.1:${port}"

status="starting"
for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${NAME}")"
    [[ "${status}" == "healthy" ]] && break
    sleep 2
done
check "image HEALTHCHECK is healthy under read-only/tmpfs hardening (status=${status})" \
    "$([[ "${status}" == "healthy" ]] && echo 1 || echo 0)"

# Response headers are captured whole first, so no pipe is closed early
# under pipefail. header <path> <name> -> every value, joined with ", ";
# header_count <path> <name> -> how many times the header occurs.
code() { curl -s -o /dev/null -w '%{http_code}' "${base}$1"; }
raw_headers() { curl -s -o /dev/null -D - "${base}$1" | tr -d '\r'; }
header() {
    raw_headers "$1" | awk -v h="$2" '
        tolower($0) ~ "^" tolower(h) ":" { sub(/^[^:]+:[ ]*/, ""); out = out (out == "" ? "" : ", ") $0 }
        END { print out }'
}
header_count() {
    raw_headers "$1" | awk -v h="$2" 'tolower($0) ~ "^" tolower(h) ":" { n++ } END { print n + 0 }'
}

for path in /app /app/ /app/features/energy /app/asset-view; do
    check "${path} -> 200" "$([[ "$(code "${path}")" == "200" ]] && echo 1 || echo 0)"
    check "${path} is the SPA entry (text/html, no-store)" \
        "$([[ "$(header "${path}" content-type)" == text/html* && "$(header "${path}" cache-control)" == *no-store* ]] && echo 1 || echo 0)"
done

entry_html="$(curl -s "${base}/app/")"
entry_js="$(grep -oE '/app/assets/[^"]+\.js' <<<"${entry_html}" | sed -n 1p || true)"
check "entry document references a hashed /app/assets/*.js bundle (${entry_js:-none})" \
    "$([[ -n "${entry_js}" ]] && echo 1 || echo 0)"
if [[ -n "${entry_js}" ]]; then
    check "${entry_js} -> 200" "$([[ "$(code "${entry_js}")" == "200" ]] && echo 1 || echo 0)"
    check "${entry_js} is immutable-cached JavaScript ($(header "${entry_js}" cache-control))" \
        "$([[ "$(header "${entry_js}" cache-control)" == *immutable* && "$(header "${entry_js}" content-type)" == *javascript* ]] && echo 1 || echo 0)"
    check "${entry_js} carries exactly one Cache-Control header" \
        "$([[ "$(header_count "${entry_js}" cache-control)" == "1" ]] && echo 1 || echo 0)"
fi
check "missing hashed asset -> 404 (no SPA fallback for assets)" \
    "$([[ "$(code /app/assets/does-not-exist.js)" == "404" ]] && echo 1 || echo 0)"

root_location="$(header / location)"
check "/ redirects with a relative Location (${root_location:-none})" \
    "$([[ "$(code /)" == "302" && "${root_location}" == "/app/" ]] && echo 1 || echo 0)"
check "nginx version not disclosed (Server: $(header /app/ server))" \
    "$([[ "$(header /app/ server)" == "nginx" ]] && echo 1 || echo 0)"

if [[ -n "${EXPECTED_SHA}" ]]; then
    label="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}")"
    check "revision label == ${EXPECTED_SHA} (got ${label})" "$([[ "${label}" == "${EXPECTED_SHA}" ]] && echo 1 || echo 0)"
fi

if (( failures > 0 )); then
    echo "ems-web container smoke: ${failures} check(s) FAILED" >&2
    docker logs --tail 50 "${NAME}" >&2 || true
    exit 1
fi
echo "ems-web container smoke: all checks passed"
