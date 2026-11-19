#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================================
# Regression test: the service precondition of the single-service deploy
# scripts (deploy_customer_api.sh, deploy_web.sh).
#
# Both scripts run under `set -o pipefail`. They used to check the deployed
# compose file with `compose config --services | grep -qx <service>`: grep -q
# exits on its first match, so when the service was not the last line of
# compose's (unordered) output, compose could be killed by SIGPIPE, the
# pipeline returned non-zero and the script wrongly reported that the
# service did not exist (staging customer-api deploy, 2026-11-19).
#
# A stub `docker` on PATH emulates `docker compose ... config --services`:
#   STUB_MODE=first   target service first, then >64 KiB of other services
#                     (guarantees the writer outlives an early-exiting reader)
#   STUB_MODE=absent  >64 KiB of services, target not among them
#   STUB_MODE=fail    compose config itself fails (exit 15)
# Any other docker call exits 97 with STUB_REACHED, i.e. step 1 passed.
# No real Docker, network, host or registry is used.
# ============================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin" "${work}/project/app"
: > "${work}/project/compose.yaml"
: > "${work}/project/app/customer-api.env"
cat > "${work}/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "compose" && " $* " == *" config --services "* ]]; then
    case "${STUB_MODE}" in
        fail) echo "stub: invalid compose file" >&2; exit 15 ;;
        first) echo "${STUB_SERVICE}" ;;
    esac
    for i in $(seq 1 20000); do echo "unrelated-service-${i}"; done
    exit 0
fi
echo "STUB_REACHED docker $*"
exit 97
STUB
chmod +x "${work}/bin/docker"

sha="1473f0c243b95ea88b085efb45871c572a3dcc47"
digest="@sha256:$(printf 'c%.0s' $(seq 1 64))"
failures=0

run_case() {  # script service image_var image mode expected
    local script="$1" service="$2" var="$3" image="$4" mode="$5" expected="$6" out code i
    for i in 1 2 3 4 5; do   # repeat: the old failure was timing-dependent
        set +e
        out="$(env PATH="${work}/bin:${PATH}" PROJECT_PATH="${work}/project" "${var}=${image}" \
               STUB_MODE="${mode}" STUB_SERVICE="${service}" ENVIRONMENT_NAME=test \
               bash "${ROOT}/scripts/release/${script}" 2>&1)"
        code=$?
        set -e
        case "${expected}" in
            pass)    [[ ${code} -eq 97 && "${out}" == *STUB_REACHED* && "${out}" != *"has no '${service}'"* ]] ;;
            absent)  [[ ${code} -eq 1 && "${out}" == *"has no '${service}' service"* ]] ;;
            failed)  [[ ${code} -eq 1 && "${out}" == *"could not read"* && "${out}" != *"has no '${service}'"* ]] ;;
        esac || { echo "FAIL ${script} mode=${mode} run ${i}: exit ${code}"; echo "${out}" | tail -4 | sed 's/^/    /'; failures=$((failures+1)); return; }
    done
    echo "PASS ${script} mode=${mode} (${expected}, 5 runs)"
}

run_case deploy_customer_api.sh customer-api EMS_CUSTOMER_API_IMAGE "ghcr.io/o/r-app:${sha}${digest}" first  pass
run_case deploy_customer_api.sh customer-api EMS_CUSTOMER_API_IMAGE "ghcr.io/o/r-app:${sha}${digest}" absent absent
run_case deploy_customer_api.sh customer-api EMS_CUSTOMER_API_IMAGE "ghcr.io/o/r-app:${sha}${digest}" fail   failed
run_case deploy_web.sh          ems-web      EMS_WEB_IMAGE          "ghcr.io/o/r-web:${sha}${digest}" first  pass
run_case deploy_web.sh          ems-web      EMS_WEB_IMAGE          "ghcr.io/o/r-web:${sha}${digest}" absent absent
run_case deploy_web.sh          ems-web      EMS_WEB_IMAGE          "ghcr.io/o/r-web:${sha}${digest}" fail   failed

if [[ ${failures} -ne 0 ]]; then echo "release service precheck: ${failures} FAILED"; exit 1; fi
echo "release service precheck: all PASSED"
