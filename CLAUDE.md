\# WiseWatts EMS Platform — Claude Code Project Instructions



\## 1. Project Identity



This repository is the WiseWatts EMS (Energy Management System) platform.



Repository:



https://github.com/avinash-wisewatts/ems-platform



The local Windows checkout is the primary development environment.



The platform includes:



\- EMS application services

\- Live telemetry ingestion

\- MQTT / HiveMQ integration

\- Telegraf

\- TimescaleDB / PostgreSQL

\- Grafana

\- Grafana semantic/data access layer

\- Energy aggregation pipelines

\- Asset/site onboarding

\- CI/CD

\- Staging

\- Production



\---



\# 2. PRIMARY OPERATING RULE



The local development environment is the default execution environment.



Claude may freely:



\- inspect the repository

\- inspect Git history

\- inspect configuration

\- modify source code

\- modify tests

\- modify SQL migrations

\- modify Grafana provisioning/configuration

\- modify Docker/Compose configuration

\- run local tests

\- run local Docker Compose commands

\- run local database commands against the development database

\- build local containers

\- inspect local logs

\- create local diagnostic scripts

\- create commits



Claude must NOT assume that a change is safe merely because tests pass.



Architecture and operational impact must be considered.



\---



\# 3. PRODUCTION SAFETY



Production is protected infrastructure.



Claude MUST NOT:



\- SSH into production autonomously

\- execute commands on production autonomously

\- modify production files

\- modify production databases

\- restart production services

\- run production migrations

\- alter production Grafana

\- alter production MQTT infrastructure

\- access production secrets

\- copy production credentials into the repository

\- retrieve or expose production `.env` files

\- modify production infrastructure without explicit user instruction



If production access appears necessary, STOP and ask the user.



Never infer permission from the existence of credentials.



\---



\# 4. STAGING SAFETY



Staging is an integration environment and is more permissive than production, but it is still remote infrastructure.



Claude MUST NOT autonomously:



\- SSH into staging

\- restart staging services

\- modify staging configuration

\- modify staging databases

\- run destructive SQL

\- run migrations

\- modify deployed Grafana

\- modify staging MQTT configuration



unless the user explicitly authorizes the specific operation.



When remote staging access is required:



1\. Explain why it is required.

2\. State exactly what will be executed.

3\. Identify potential impact.

4\. Obtain explicit user approval.

5\. Prefer read-only diagnostics first.



\---



\# 5. SECRETS



Never commit secrets.



Never place real credentials in:



\- source code

\- tests

\- documentation

\- CLAUDE.md

\- shell scripts

\- GitHub

\- Docker images

\- Grafana dashboards

\- frontend/browser code



Never print secrets to the terminal unnecessarily.



Never expose:



\- MQTT passwords

\- database passwords

\- Grafana admin passwords

\- session secrets

\- API tokens

\- AWS credentials

\- SSH private keys



If a secret is required for a local operation, use the existing local environment mechanism.



\---



\# 6. ENVIRONMENT SEPARATION



The repository uses separate environment files.



Known environment boundaries include:



\- root `.env`

\- `telegraf/.env`

\- `app/.env`

\- `app/live-telemetry.env`

\- `grafana/.env`

\- `grafana/live-stream.env`



Do not merge environment responsibilities without architectural justification.



Do not copy credentials between environments.



Production configuration is authoritative for understanding deployed behavior only when explicitly inspected by the user.



Never commit real `.env` files.



\---



\# 7. TELEMETRY ARCHITECTURE



The platform has two distinct telemetry paths.



\## Historical telemetry



MQTT / Telegraf → TimescaleDB → analytics / Grafana



This path is optimized for durable historical data, aggregation and analytical querying.



\## Live telemetry



MQTT → server-side live-telemetry service → Grafana live stream



The browser/Grafana frontend must not receive MQTT broker credentials.



The live telemetry service is responsible for server-side MQTT subscription and browser-facing streaming.



Never move MQTT credentials into frontend code.



Never expose HiveMQ credentials through Grafana.



\---



\# 8. GRAFANA ARCHITECTURE



Grafana is a visualization/query layer.



Do not place complex business logic directly into individual dashboard panels when a reusable semantic/database layer is appropriate.



Prefer:



application/database semantic views/functions

&#x20;       ↓

Grafana datasource/query

&#x20;       ↓

dashboard panels



Reusable analytics semantics should live in the appropriate database/application layer rather than being duplicated across dashboards.



When changing Grafana queries:



\- preserve dashboard variables

\- preserve tenant isolation

\- preserve asset/site filtering

\- preserve time-range behavior

\- avoid unnecessary high-cardinality queries

\- consider TimescaleDB query performance

\- consider aggregation resolution



\---



\# 9. TIMESCALEDB / AGGREGATION ARCHITECTURE



Historical energy telemetry uses multiple resolutions for efficient Grafana querying.



The intended aggregation model includes:



\- 1 minute

\- 5 minute

\- 15 minute

\- 1 hour

\- 1 day



Do not remove or bypass these aggregation layers without understanding their role.



Grafana queries should use the appropriate resolution for the requested time range and visualization.



Do not solve performance problems by simply increasing query limits or timeouts.



Prefer correct aggregation selection and efficient SQL.



\---



\# 10. MULTI-TENANCY



Tenant / organization isolation is a core architectural requirement.



Every query and API path involving tenant-owned data must preserve tenant boundaries.



Never introduce a query that can return another organization's:



\- sites

\- assets

\- telemetry

\- energy data

\- demand data

\- users

\- configuration



When modifying SQL, explicitly verify tenant filtering.



\---



\# 11. DATABASE CHANGES



Database changes must be treated as production-impacting architecture.



For schema changes:



1\. Inspect existing schema.

2\. Inspect existing migrations.

3\. Search for dependent views/functions.

4\. Search application code.

5\. Search Grafana queries.

6\. Determine backwards compatibility.

7\. Add/update tests.

8\. Validate locally.

9\. Explain migration impact before remote execution.



Do not rewrite historical data unless explicitly instructed.



Do not perform destructive migrations without explicit approval.



\---



\# 12. TESTING



Before declaring work complete:



\- run the most relevant tests

\- run targeted tests first

\- run broader tests when appropriate

\- inspect failures rather than hiding them

\- do not weaken tests merely to make them pass



If a test fails because the implementation is wrong, fix the implementation.



If a test is obsolete because architecture intentionally changed, explain why before changing the test.



\---



\# 13. GIT WORKFLOW



The working tree must be checked before making changes.



Before substantial work:



&#x20;   git status



Inspect the current branch.



Do not silently switch branches.



Prefer small, coherent commits.



Before committing:



&#x20;   git diff

&#x20;   git status



Never commit:



\- secrets

\- `.env` files containing credentials

\- generated runtime data

\- database data directories

\- logs

\- private keys

\- machine-specific credentials



Do not force-push.



Do not rewrite shared branch history.



Do not delete remote branches without explicit approval.



\---



\# 14. BRANCHING



The repository uses GitHub for source control and CI/CD.



Treat:



\- feature branches as development

\- staging as integration

\- production as release infrastructure



Do not assume that pushing to a branch automatically makes a change safe for production.



Respect the existing CI/CD promotion model.



Do not bypass CI/CD unless explicitly instructed.



\---



\# 15. CI/CD



CI/CD produces the deployable application artifact.



The staging and production environments should use the intended immutable application artifact rather than silently rebuilding different code on each environment.



Do not change deployment semantics casually.



When changing CI/CD:



\- inspect the existing workflow

\- understand image tagging

\- understand promotion behavior

\- verify staging/production separation

\- preserve deterministic builds

\- avoid embedding secrets in workflow files



\---



\# 16. DOCKER



Local Docker Compose is an allowed development environment.



Before changing Compose:



\- understand service dependencies

\- inspect environment propagation

\- inspect mounted volumes

\- inspect exposed ports

\- inspect health checks



Known services include:



\- timescaledb

\- telegraf

\- grafana

\- live-telemetry

\- application service



Do not expose services publicly merely to make local development easier.



Prefer localhost bindings where appropriate.



\---



\# 17. LIVE TELEMETRY CREDENTIALS



The live telemetry service uses dedicated MQTT credentials.



Relevant configuration includes:



MQTT\_HOST

MQTT\_PORT

MQTT\_USERNAME

MQTT\_PASSWORD

MQTT\_LIVE\_CLIENT\_ID

MQTT\_TLS

EMS\_GRAFANA\_STREAM\_TOKEN



These credentials belong to the server-side live telemetry path.



They must never be exposed to:



\- browsers

\- frontend JavaScript

\- Grafana dashboard variables

\- public APIs



\---



\# 18. GRAFANA STREAM TOKEN



`EMS\_GRAFANA\_STREAM\_TOKEN` is a server-side authentication mechanism.



Treat it as a secret.



Do not expose it to the browser.



Do not commit its real value.



Do not print it in diagnostics.



\---



\# 19. DIAGNOSTICS



Diagnostics should be:



\- read-only where possible

\- reproducible

\- safe to run

\- explicit about environment

\- careful not to expose secrets



When creating diagnostic scripts, prefer commands that report:



\- service status

\- container status

\- health

\- connectivity

\- schema state

\- row counts

\- timestamp ranges

\- aggregation state

\- Grafana query behavior



Never include secret values in diagnostic output.



\---



\# 20. ARCHITECTURAL DECISION RULE



Do not make a local fix that creates a system-level architectural inconsistency.



Before changing an important component, determine:



\- what depends on it

\- what it depends on

\- whether staging and production use it

\- whether Grafana depends on it

\- whether CI/CD depends on it

\- whether database migrations depend on it

\- whether onboarding depends on it

\- whether live telemetry depends on it



Prefer the smallest change that preserves the intended architecture.



\---



\# 21. WHEN UNCERTAIN



Do not guess about:



\- production configuration

\- credentials

\- infrastructure

\- deployment behavior

\- database schema

\- MQTT topics

\- tenant isolation

\- Grafana datasource behavior

\- CI/CD promotion behavior



Instead:



1\. Inspect the repository.

2\. Search for references.

3\. Check tests.

4\. Check configuration.

5\. Explain uncertainty.

6\. Ask the user when remote or destructive action is involved.



\---



\# 22. USER CONTROL



The user remains the final authority for:



\- production changes

\- staging changes

\- migrations on remote environments

\- credential changes

\- infrastructure changes

\- destructive operations

\- deployment decisions



Claude is an engineering assistant, not an autonomous production operator.



\---



\# 23. DEFAULT WORKING STYLE



For implementation tasks:



1\. Inspect first.

2\. Understand existing architecture.

3\. State the proposed approach briefly.

4\. Make the smallest coherent change.

5\. Test.

6\. Inspect the diff.

7\. Report exactly what changed.

8\. Report tests run and results.

9\. Identify remaining risks.



Do not make unrelated cleanup changes while implementing a requested feature.



Do not rewrite working architecture without justification.



\---



\# 24. CURRENT DEVELOPMENT ENVIRONMENT



The primary development environment is:



Windows PowerShell

Local Git repository

Local Docker/Compose

Local development database/services



Repository:



C:\\Users\\avina\\Documents\\WiseWatts\\ems-platform



Remote:



https://github.com/avinash-wisewatts/ems-platform.git



The current development branch may be `staging`, but always check `git status` before acting.



\---



\# 25. FINAL RULE



When in doubt, inspect first and ask before touching remote infrastructure.



Local code changes and local testing are encouraged.



Remote infrastructure changes require explicit authorization.



Production changes always require explicit authorization.

