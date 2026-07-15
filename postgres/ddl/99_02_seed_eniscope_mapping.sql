-- ============================================================================
-- File:
--   99_02_seed_eniscope_mapping.sql
--
-- Purpose:
--   Map Eniscope raw JSON fields to EMS logical points.
--
-- This implements late-binding metadata.
--
-- MQTT field names remain vendor specific.
-- Dashboards use logical points.
-- ============================================================================


INSERT INTO metadata.device_field_mapping
(
    device_id,
    raw_field_name,
    logical_point_id
)

SELECT
    d.id,
    m.raw_field_name,
    lp.id

FROM metadata.devices d

JOIN
(
VALUES

('P','ENERGY_ACTIVE_POWER_TOTAL'),
('P1','ENERGY_ACTIVE_POWER_L1'),
('P2','ENERGY_ACTIVE_POWER_L2'),
('P3','ENERGY_ACTIVE_POWER_L3'),

('E','ENERGY_IMPORT_TOTAL'),
('Ex','ENERGY_EXPORT_TOTAL'),

('Q','ENERGY_REACTIVE_POWER_TOTAL'),
('RE','ENERGY_REACTIVE_ENERGY_TOTAL'),
('REx','ENERGY_REACTIVE_EXPORT_TOTAL'),

('S','ENERGY_APPARENT_POWER_TOTAL'),
('AE','ENERGY_APPARENT_ENERGY_TOTAL'),

('V1','VOLTAGE_L1'),
('V2','VOLTAGE_L2'),
('V3','VOLTAGE_L3'),

('I1','CURRENT_L1'),
('I2','CURRENT_L2'),
('I3','CURRENT_L3'),

('PF','POWER_FACTOR_TOTAL'),
('F','FREQUENCY'),

('D1','CURRENT_THD_L1'),
('D2','CURRENT_THD_L2'),
('D3','CURRENT_THD_L3')

) AS m
(
raw_field_name,
logical_point_name
)

ON d.external_id='ENI-DEMO-001'

JOIN metadata.logical_points lp
ON lp.name=m.logical_point_name

ON CONFLICT
(
device_id,
raw_field_name
)
DO NOTHING;
