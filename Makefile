.PHONY: test-db test-db-status test-db-shell test-db-destroy test-app-build test-app verify-all

# Create a fresh disposable integration-test database.
test-db:
	./scripts/test/run_integration_environment.sh

# Show the disposable test database status.
test-db-status:
	./scripts/test/test_database.sh status

# Open an interactive psql session in the test database.
test-db-shell:
	./scripts/test/test_database.sh psql

# Destroy the disposable test database and its Docker volume.
test-db-destroy:
	./scripts/test/test_database.sh destroy

# Build the isolated admin portal application-test image.
test-app-build:
	docker build 		--file app/Dockerfile.test 		--tag ems-admin-portal-test 		.

# Run the complete admin portal application-test suite.
test-app: test-app-build
	docker run --rm 		--network host 		ems-admin-portal-test

# Rebuild and validate the complete database and admin portal.
verify-all:
	$(MAKE) test-db
	$(MAKE) test-app

