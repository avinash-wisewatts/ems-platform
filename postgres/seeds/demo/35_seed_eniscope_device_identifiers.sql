-- ============================================================================
-- 35_seed_eniscope_device_identifiers.sql
--
-- Purpose:
--     Register physical Eniscope MQTT identities.
--
--     MQTT UID is a vendor/device identifier.
--     metadata.devices.id remains our internal EMS identifier.
--
-- Architecture:
--
-- MQTT UID
--     |
--     v
-- metadata.device_identifiers
--     |
--     v
-- metadata.devices
--
-- ============================================================================


INSERT INTO metadata.device_identifiers
(
    device_id,
    identifier_type,
    identifier_value
)

SELECT

    d.id,

    'MQTT_UID',

    LOWER(uid)

FROM metadata.devices d

CROSS JOIN
(
    VALUES

    ('80:34:28:16:09:eb:00:01'),
    ('80:34:28:16:09:eb:00:02'),
    ('80:34:28:16:09:eb:00:03'),
    ('80:34:28:16:09:eb:05:01'),
    ('80:34:28:16:09:eb:05:02')

) AS identifiers(uid)


WHERE d.external_id='ENI-DEMO-001'


ON CONFLICT
(
    identifier_type,
    identifier_value
)

DO NOTHING;


COMMENT ON TABLE metadata.device_identifiers IS
'Maps external device identities such as MQTT UID, serial number, MAC address to internal EMS devices.';
