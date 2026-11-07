.PHONY: check check-linux lint test test-unit test-node e2e

# What CI runs: everything that needs no Docker daemon or server. About 1 minute.
check: lint test

# The same checks on Ubuntu in Docker, as CI runs them. About 3 minutes.
check-linux:
	tests/check-linux.sh

lint:
	tests/lint.sh

test: test-unit test-node

test-unit:
	bats tests/unit

test-node:
	node --test tests/node/*.test.mjs

# Full stack on this machine with Docker. 10 to 20 minutes.
e2e:
	tests/e2e-local.sh
