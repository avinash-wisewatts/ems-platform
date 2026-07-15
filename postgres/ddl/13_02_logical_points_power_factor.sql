INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)

VALUES
(
    'POWER_FACTOR_TOTAL',
    'System power factor',
    NULL,
    'numeric'
)

ON CONFLICT DO NOTHING;
