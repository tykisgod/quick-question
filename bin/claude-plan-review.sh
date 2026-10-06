#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/../scripts" && pwd)/claude-plan-review.sh" "$@"
