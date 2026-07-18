#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS Metadata Verification
#
# Performs read-only integrity and completeness checks against
# tenant, site, device, asset, and profile metadata.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_DIR}" || {
    echo "[FAIL] Cannot access project directory: ${PROJECT_DIR}"
    exit 1
}

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

print_header
print_section "Metadata Foundation"

if psql_query "SELECT 1;" >/dev/null 2>&1; then
    pass "PostgreSQL connection succeeded"
else
    fail "PostgreSQL connection failed"
    summary
fi

check_table_exists() {
    local schema_name="$1"
    local table_name="$2"
    local exists

    exists="$(
        psql_query "
            SELECT EXISTS (
                SELECT 1
                FROM pg_class c
                JOIN pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE n.nspname = '${schema_name}'
                  AND c.relname = '${table_name}'
                  AND c.relkind IN ('r', 'p')
            );
        " 2>/dev/null || true
    )"

    if [[ "${exists}" == "t" ]]; then
        pass "Table exists: ${schema_name}.${table_name}"
        return 0
    fi

    fail "Table missing: ${schema_name}.${table_name}"
    return 1
}

REQUIRED_TABLES=(
    "metadata.organizations"
    "metadata.sites"
    "metadata.gateways"
    "metadata.devices"
    "metadata.assets"
    "metadata.asset_devices"
    "metadata.logical_points"
    "config.device_profiles"
    "config.profile_field_mapping"
)

for qualified_name in "${REQUIRED_TABLES[@]}"; do
    check_table_exists \
        "${qualified_name%%.*}" \
        "${qualified_name#*.}"
done

print_section "Metadata Population"

ORGANIZATION_COUNT="$(
    psql_query "SELECT COUNT(*) FROM metadata.organizations;" \
        2>/dev/null || echo 0
)"

if [[ "${ORGANIZATION_COUNT}" =~ ^[0-9]+$ ]] &&
   (( ORGANIZATION_COUNT > 0 )); then
    pass "Organizations configured: ${ORGANIZATION_COUNT}"
else
    warn "No organizations are configured"
fi

SITE_COUNT="$(
    psql_query "SELECT COUNT(*) FROM metadata.sites;" \
        2>/dev/null || echo 0
)"

if [[ "${SITE_COUNT}" =~ ^[0-9]+$ ]] &&
   (( SITE_COUNT > 0 )); then
    pass "Sites configured: ${SITE_COUNT}"
else
    warn "No sites are configured"
fi

DEVICE_COUNT="$(
    psql_query "SELECT COUNT(*) FROM metadata.devices;" \
        2>/dev/null || echo 0
)"

if [[ "${DEVICE_COUNT}" =~ ^[0-9]+$ ]] &&
   (( DEVICE_COUNT > 0 )); then
    pass "Devices configured: ${DEVICE_COUNT}"
else
    warn "No devices are configured"
fi

ASSET_COUNT="$(
    psql_query "SELECT COUNT(*) FROM metadata.assets;" \
        2>/dev/null || echo 0
)"

if [[ "${ASSET_COUNT}" =~ ^[0-9]+$ ]] &&
   (( ASSET_COUNT > 0 )); then
    pass "Assets configured: ${ASSET_COUNT}"
else
    warn "No assets are configured"
fi

PROFILE_COUNT="$(
    psql_query "SELECT COUNT(*) FROM config.device_profiles;" \
        2>/dev/null || echo 0
)"

if [[ "${PROFILE_COUNT}" =~ ^[0-9]+$ ]] &&
   (( PROFILE_COUNT > 0 )); then
    pass "Device profiles configured: ${PROFILE_COUNT}"
else
    fail "No device profiles are configured"
fi

MAPPING_COUNT="$(
    psql_query "SELECT COUNT(*) FROM config.profile_field_mapping;" \
        2>/dev/null || echo 0
)"

if [[ "${MAPPING_COUNT}" =~ ^[0-9]+$ ]] &&
   (( MAPPING_COUNT > 0 )); then
    pass "Profile field mappings configured: ${MAPPING_COUNT}"
else
    fail "No profile field mappings are configured"
fi

print_section "Referential Integrity"

ORPHAN_SITES="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.sites s
        LEFT JOIN metadata.organizations o
          ON o.id = s.organization_id
        WHERE o.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${ORPHAN_SITES}" == "0" ]]; then
    pass "No sites reference missing organizations"
else
    fail "Sites referencing missing organizations: ${ORPHAN_SITES}"
fi

ORPHAN_GATEWAYS="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.gateways g
        LEFT JOIN metadata.sites s
          ON s.id = g.site_id
        WHERE s.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${ORPHAN_GATEWAYS}" == "0" ]]; then
    pass "No gateways reference missing sites"
else
    fail "Gateways referencing missing sites: ${ORPHAN_GATEWAYS}"
fi

ORPHAN_DEVICES="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.devices d
        LEFT JOIN metadata.gateways g
          ON g.id = d.gateway_id
        WHERE d.gateway_id IS NOT NULL
          AND g.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${ORPHAN_DEVICES}" == "0" ]]; then
    pass "No devices reference missing gateways"
else
    fail "Devices referencing missing gateways: ${ORPHAN_DEVICES}"
fi

ORPHAN_ASSETS="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.assets a
        LEFT JOIN metadata.sites s
          ON s.id = a.site_id
        WHERE s.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${ORPHAN_ASSETS}" == "0" ]]; then
    pass "No assets reference missing sites"
else
    fail "Assets referencing missing sites: ${ORPHAN_ASSETS}"
fi

print_section "Device Profile Integrity"

DEVICES_WITHOUT_PROFILE="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.devices
        WHERE profile_id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${DEVICES_WITHOUT_PROFILE}" == "0" ]]; then
    pass "All devices have a profile assignment"
else
    warn "Devices without profile assignment: ${DEVICES_WITHOUT_PROFILE}"
fi

INVALID_DEVICE_PROFILES="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.devices d
        LEFT JOIN config.device_profiles p
          ON p.id = d.profile_id
        WHERE d.profile_id IS NOT NULL
          AND p.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${INVALID_DEVICE_PROFILES}" == "0" ]]; then
    pass "All assigned device profiles are valid"
else
    fail "Devices referencing missing profiles: ${INVALID_DEVICE_PROFILES}"
fi

INVALID_PROFILE_MAPPINGS="$(
    psql_query "
        SELECT COUNT(*)
        FROM config.profile_field_mapping m
        LEFT JOIN config.device_profiles p
          ON p.id = m.profile_id
        LEFT JOIN metadata.logical_points lp
          ON lp.id = m.logical_point_id
        WHERE p.id IS NULL
           OR lp.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${INVALID_PROFILE_MAPPINGS}" == "0" ]]; then
    pass "All profile mappings reference valid profiles and logical points"
else
    fail "Invalid profile field mappings: ${INVALID_PROFILE_MAPPINGS}"
fi

DUPLICATE_PROFILE_FIELDS="$(
    psql_query "
        SELECT COUNT(*)
        FROM (
            SELECT profile_id, raw_field_name
            FROM config.profile_field_mapping
            GROUP BY profile_id, raw_field_name
            HAVING COUNT(*) > 1
        ) duplicates;
    " 2>/dev/null || echo 0
)"

if [[ "${DUPLICATE_PROFILE_FIELDS}" == "0" ]]; then
    pass "No duplicate raw-field mappings exist within profiles"
else
    fail "Duplicate profile raw-field mappings: ${DUPLICATE_PROFILE_FIELDS}"
fi

print_section "Asset and Device Relationships"

INVALID_ASSET_DEVICE_LINKS="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.asset_devices ad
        LEFT JOIN metadata.assets a
          ON a.id = ad.asset_id
        LEFT JOIN metadata.devices d
          ON d.id = ad.device_id
        WHERE a.id IS NULL
           OR d.id IS NULL;
    " 2>/dev/null || echo 0
)"

if [[ "${INVALID_ASSET_DEVICE_LINKS}" == "0" ]]; then
    pass "All asset-device relationships are valid"
else
    fail "Invalid asset-device relationships: ${INVALID_ASSET_DEVICE_LINKS}"
fi

DUPLICATE_PRIMARY_METERS="$(
    psql_query "
        SELECT COUNT(*)
        FROM (
            SELECT asset_id
            FROM metadata.asset_devices
            WHERE is_primary = true
            GROUP BY asset_id
            HAVING COUNT(*) > 1
        ) duplicates;
    " 2>/dev/null || echo 0
)"

if [[ "${DUPLICATE_PRIMARY_METERS}" == "0" ]]; then
    pass "No asset has multiple primary meters"
else
    fail "Assets with multiple primary meters: ${DUPLICATE_PRIMARY_METERS}"
fi

ASSETS_WITHOUT_DEVICE="$(
    psql_query "
        SELECT COUNT(*)
        FROM metadata.assets a
        LEFT JOIN metadata.asset_devices ad
          ON ad.asset_id = a.id
        WHERE ad.asset_id IS NULL
          AND NOT EXISTS (
              SELECT 1
              FROM metadata.assets child
              WHERE child.parent_asset_id = a.id
          );
    " 2>/dev/null || echo 0
)"

if [[ "${ASSETS_WITHOUT_DEVICE}" == "0" ]]; then
    pass "All assets have at least one associated device"
else
    warn "Leaf assets without an associated device: ${ASSETS_WITHOUT_DEVICE}"
fi

summary
