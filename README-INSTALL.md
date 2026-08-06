# Device commissioning scope patch

Implements:
- explicit commissioning status in Device View and Device Edit headers;
- header links to the Device View Operational and lifecycle section;
- compact lifecycle section with an inline expandable readiness panel;
- Asset assignment requirement terminology while preserving operational_policy internally;
- Commission button shown only when the device is uncommissioned, ready, and authorized;
- actionable readiness blockers and contextual commissioning errors;
- commissioning-pending notice in onboarding Device step and final confirmation Device section;
- standalone-device creation redirect to commissioning context;
- secure repair for controlled activation while preserving the direct-ACTIVE guard;
- contract tests.

## Install

From `/opt/ems-platform`, back up first, then extract this archive over the repository.

Apply migration 177 to the test database before production. Rebuild `admin-portal` only after tests and migration validation pass.
