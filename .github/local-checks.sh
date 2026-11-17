#!/usr/bin/env bash
# The pull-request checks. /ship and /merge run this before merging and post the
# result as the `local-checks` commit status; ci.yml runs `make check` only when
# dispatched by hand, and bin/fraim-release runs tests/check-linux.sh itself.
set -euo pipefail
cd "$(dirname "$0")/.."

make check
