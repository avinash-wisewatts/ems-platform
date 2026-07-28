# Canonical PostgreSQL Bootstrap Validation

Validated on 2026-07-18.

## Results

- Fresh canonical deployment: PASS
- Immediate canonical rerun: PASS
- Canonical files executed: 65
- Metadata integrity indexes verified: 4
- Timescale hypertables verified: 8
- Continuous aggregates verified: 5
- EMS background jobs verified: 3
- Duplicate EMS background jobs: 0
- Demo tenant data in clean database: 0
- Canonical objects missing from production: 0

## Production-only legacy objects

The following remain in production but are not part of canonical deployment:

- telemetry.get_logical_point(text, text)
- telemetry.v_energy_meter

No active database or repository consumers were detected.
