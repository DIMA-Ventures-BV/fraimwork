.PHONY: check check-linux lint test test-unit test-node e2e e2e-spaces test-secrets

# What CI runs: everything that needs no Docker daemon or server. About 1 minute.
check: lint test

# The same checks on Ubuntu in Docker, as CI runs them. About 3 minutes.
check-linux:
	tests/check-linux.sh

lint:
	tests/lint.sh

test: test-unit test-node

# One job per core when GNU parallel is installed, otherwise one test at a time.
JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

test-unit:
	@if parallel --version 2>/dev/null | grep -q GNU; then bats --jobs $(JOBS) tests/unit; else bats tests/unit; fi

test-node:
	node --test tests/node/*.test.mjs

# Full stack on this machine with Docker. 10 to 20 minutes.
e2e:
	tests/e2e-local.sh

# Two spaces on a local stack: separation, policy, previews, MCP, hosts, GitHub. About 5 minutes.
e2e-spaces:
	tests/e2e-spaces.sh

# The secrets proxy in Docker, with a fake API. About 1 minute.
test-secrets:
	tests/secrets.sh
