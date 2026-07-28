-- ============================================================================
-- File: 05_01_engineering_units_extension.sql
-- Purpose: Additional engineering units required for electrical telemetry.
--
-- These units support:
--   - Reactive power
--   - Reactive energy
--   - Apparent power
--   - Apparent energy
-- ============================================================================


INSERT INTO config.engineering_units
(
    symbol
)

VALUES

('kvar'),
('kvarh'),
('kVA'),
('kVAh')

ON CONFLICT DO NOTHING;
