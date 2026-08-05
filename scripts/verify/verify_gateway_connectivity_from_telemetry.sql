\pset pager off
\echo '=== CONNECTIVITY EVIDENCE ==='
SELECT
    g.name AS gateway_name,
    gc.status_last_seen_at,
    gc.telemetry_last_seen_at,
    gc.last_seen_at,
    gc.last_seen_source,
    CASE
      WHEN gc.last_seen_at IS NULL THEN 'NEVER_SEEN'
      WHEN gc.last_seen_at >= now() - make_interval(secs => p.online_threshold_seconds) THEN 'ONLINE'
      ELSE 'OFFLINE'
    END AS expected_connectivity_status
FROM metadata.gateways g
CROSS JOIN config.gateway_connectivity_policy p
LEFT JOIN analytics.v_gateway_connectivity gc ON gc.gateway_id=g.id
ORDER BY g.name;

\echo ''
\echo '=== ADMIN LIST AGREEMENT ==='
SELECT
    gateway_name,
    connectivity_status,
    last_seen_at,
    online_threshold_seconds
FROM admin.list_accessible_gateways(
    (SELECT portal_user_id FROM admin.portal_users WHERE is_active ORDER BY portal_user_id LIMIT 1)
)
ORDER BY gateway_name;

\echo ''
\echo '=== ENISCOPE HOME EXPECTATION ==='
SELECT
    g.name AS gateway_name,
    gc.last_seen_at IS NOT NULL AS has_last_seen,
    gc.last_seen_source,
    CASE
      WHEN gc.last_seen_at IS NULL THEN 'NEVER_SEEN'
      WHEN gc.last_seen_at >= now() - make_interval(secs => p.online_threshold_seconds) THEN 'ONLINE'
      ELSE 'OFFLINE'
    END AS connectivity_status
FROM metadata.gateways g
CROSS JOIN config.gateway_connectivity_policy p
LEFT JOIN analytics.v_gateway_connectivity gc ON gc.gateway_id=g.id
WHERE g.name='Eniscope Home';
