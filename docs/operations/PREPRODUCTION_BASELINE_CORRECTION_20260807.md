# Pre-production baseline correction — 2026-08-07

The first baseline replayed historical migrations on top of canonical DDL and
failed when migration 97 attempted to alter `public.mqtt_staging` as a table,
while canonical deployment correctly defines it as a compatibility view.

The corrected model is:

1. canonical DDL/reference/jobs, including former canonical mirrors;
2. additive baseline 001 for final-state changes without DDL mirrors;
3. future migrations 002 and above.

The production-versus-canonical inventory reported 152 production-only object
names. Most are supplied by DDL files 91-121 once those files are included in
canonical deployment. Legacy production-only objects such as
`telemetry.telegraf_ingest` are not automatically recreated merely to force
object-name equality; they require explicit drift classification.
