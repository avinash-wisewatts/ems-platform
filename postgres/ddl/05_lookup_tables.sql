-- ============================================================================
-- File: 05_lookup_tables.sql
-- Purpose: EMS reference data and controlled vocabulary.
--
-- These tables contain reusable definitions shared across the EMS platform.
--
-- Design principles:
--   - Avoid free-text inconsistencies.
--   - Support multiple IoT vendors.
--   - Support future BMS integrations.
--
-- Execution order:
--   00_extensions.sql
--   01_schemas.sql
--   02_roles.sql
--   03_admin.sql
--   04_metadata.sql
-- ============================================================================


-- ============================================================================
-- ENGINEERING UNITS
-- ============================================================================

INSERT INTO config.engineering_units
(symbol, description)
VALUES
('kW', 'Kilowatt - instantaneous power'),
('kWh', 'Kilowatt hour - accumulated energy'),
('V', 'Voltage'),
('A', 'Current'),
('Hz', 'Frequency'),
('degC', 'Temperature in Celsius'),
('%', 'Percentage'),
('bar', 'Pressure'),
('m3', 'Volume'),
('L/min', 'Flow rate'),
('hours', 'Operating hours')
ON CONFLICT (symbol) DO NOTHING;



-- ============================================================================
-- ASSET TYPES
-- ============================================================================

INSERT INTO metadata.asset_types
(name, description)
VALUES
('Chiller', 'Central cooling equipment'),
('AHU', 'Air Handling Unit'),
('Pump', 'Water circulation or process pump'),
('Cooling Tower', 'Cooling tower equipment'),
('Compressor', 'Compressed air or refrigeration compressor'),
('Fan', 'Ventilation or air movement equipment'),
('Boiler', 'Heating equipment'),
('Energy Meter', 'Electrical energy measurement device'),
('Temperature Sensor', 'Temperature measurement device'),
('Flow Meter', 'Fluid flow measurement device'),
('Pressure Sensor', 'Pressure measurement device')
ON CONFLICT DO NOTHING;



-- ============================================================================
-- DEVICE CATEGORIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.device_categories (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


INSERT INTO config.device_categories
(name, description)
VALUES
('Energy Meter', 'Electrical measurement device'),
('Gateway', 'IoT communication gateway'),
('Environmental Sensor', 'Temperature, humidity and environmental monitoring'),
('Digital Input Module', 'Binary status monitoring device'),
('PLC', 'Programmable logic controller'),
('BMS Controller', 'Building management system controller')
ON CONFLICT (name) DO NOTHING;



-- ============================================================================
-- COMMUNICATION PROTOCOLS
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.protocols (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


INSERT INTO config.protocols
(name, description)
VALUES
('MQTT', 'Message Queue Telemetry Transport'),
('Modbus TCP', 'Ethernet based Modbus communication'),
('Modbus RTU', 'Serial Modbus communication'),
('BACnet', 'Building automation communication protocol'),
('OPC-UA', 'Industrial interoperability protocol'),
('HTTP API', 'HTTP based integration')
ON CONFLICT (name) DO NOTHING;



-- ============================================================================
-- LOGICAL POINT CATEGORIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.point_categories (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


INSERT INTO config.point_categories
(name, description)
VALUES
('Power', 'Instantaneous electrical power'),
('Energy', 'Accumulated energy consumption'),
('Voltage', 'Electrical voltage measurement'),
('Current', 'Electrical current measurement'),
('Temperature', 'Temperature measurement'),
('Humidity', 'Humidity measurement'),
('Pressure', 'Pressure measurement'),
('Flow', 'Flow measurement'),
('Runtime', 'Operating hours'),
('Status', 'Equipment operating state')
ON CONFLICT (name) DO NOTHING;


