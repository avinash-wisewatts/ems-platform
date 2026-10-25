#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Pending-migration precheck for a release (no database access; files only).
#
# Computes the migrations the TARGET commit's own runner would apply to an
# environment, then refuses unless that set is exactly what the operator
# declared, and never contains a migration scoped away from the environment.
#
#   check_pending_migrations.sh \
#     --environment production \
#     --manifest   <target restructure_manifest.csv> \
#     --scope      <target migration_environment_scope.csv | none> \
#     --scope-aware yes|no   (does the target runner honour the scope file?) \
#     --deny-scope <scope file from staging HEAD> \
#     --ledger     <file: one recorded migration_id per line> \
#     --expected   <comma list of ids or numeric prefixes, e.g. 311 | none>
#
# Why both scopes: a rollback can target a commit whose runner predates the
# scope file. Its runner would apply every pending row, so a staging-only
# migration it would apply must be refused using the current (staging HEAD)
# scope as the deny list.
#
# Exit 0 = safe to deploy; 1 = refused; 2 = usage error.
# =============================================================================

environment=""
manifest=""
scope="none"
scope_aware=""
deny_scope=""
ledger=""
expected=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment) environment="$2"; shift 2 ;;
        --manifest) manifest="$2"; shift 2 ;;
        --scope) scope="$2"; shift 2 ;;
        --scope-aware) scope_aware="$2"; shift 2 ;;
        --deny-scope) deny_scope="$2"; shift 2 ;;
        --ledger) ledger="$2"; shift 2 ;;
        --expected) expected="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "${environment}" in staging|production) ;; *) echo "ERROR: --environment must be staging or production" >&2; exit 2 ;; esac
case "${scope_aware}" in yes|no) ;; *) echo "ERROR: --scope-aware must be yes or no" >&2; exit 2 ;; esac
for required in manifest deny_scope ledger; do
    if [[ ! -f "${!required}" ]]; then
        echo "ERROR: --${required//_/-} file not found: ${!required}" >&2
        exit 2
    fi
done
if [[ "${scope}" != "none" && ! -f "${scope}" ]]; then
    echo "ERROR: --scope file not found: ${scope}" >&2
    exit 2
fi
if [[ -z "${expected}" ]]; then
    echo "ERROR: --expected is required (use 'none' for a release with no migrations)" >&2
    exit 2
fi

# Migrations whose scope excludes the environment, from one scope file.
scoped_out() {
    [[ "$1" == "none" ]] && return 0
    while IFS=',' read -r scope_id scope_environments _reason; do
        scope_id="${scope_id%$'\r'}"
        [[ -z "${scope_id}" || "${scope_id}" == "migration_id" ]] && continue
        [[ "|${scope_environments}|" == *"|${environment}|"* ]] || echo "${scope_id}"
    done < "$1"
}

declare -A recorded=() target_out=() denied=()
while IFS= read -r id; do
    id="${id%$'\r'}"
    [[ -n "${id}" ]] && recorded["${id}"]=1
done < "${ledger}"
while IFS= read -r id; do target_out["${id}"]=1; done < <(scoped_out "${scope}")
while IFS= read -r id; do denied["${id}"]=1; done < <(scoped_out "${deny_scope}"; scoped_out "${scope}")

pending=()
while IFS=',' read -r source_file target_category _path _notes; do
    [[ "${source_file}" == "source_file" || "${target_category}" != "migration" ]] && continue
    id="${source_file%.sql}"
    [[ -n "${recorded[${id}]:-}" ]] && continue
    if [[ "${scope_aware}" == "yes" && -n "${target_out[${id}]:-}" ]]; then
        continue
    fi
    pending+=("${id}")
done < "${manifest}"

echo "Environment:          ${environment}"
echo "Target runner scoped: ${scope_aware}"
echo "Would apply (${#pending[@]}): ${pending[*]:-none}"
echo "Declared:             ${expected}"

refused=0
for id in "${pending[@]}"; do
    if [[ -n "${denied[${id}]:-}" ]]; then
        echo "REFUSED: ${id} is scoped away from ${environment} but the target runner would apply it." >&2
        refused=1
    fi
done

declare -A matched=()
if [[ "${expected}" != "none" ]]; then
    IFS=',' read -r -a tokens <<< "${expected}"
    for token in "${tokens[@]}"; do
        token="$(echo "${token}" | xargs)"
        hits=0
        for id in "${pending[@]}"; do
            if [[ "${id}" == "${token}" || "${id}" == "${token}_"* ]]; then
                hits=$((hits + 1))
                matched["${id}"]=1
            fi
        done
        if [[ "${hits}" -ne 1 ]]; then
            echo "REFUSED: declared '${token}' matches ${hits} pending migrations (must be exactly 1)." >&2
            refused=1
        fi
    done
fi
for id in "${pending[@]}"; do
    if [[ -z "${matched[${id}]:-}" ]]; then
        echo "REFUSED: ${id} would be applied but was not declared." >&2
        refused=1
    fi
done

if [[ "${refused}" -ne 0 ]]; then
    echo "Pending-migration precheck: REFUSED" >&2
    exit 1
fi
echo "Pending-migration precheck: OK"
