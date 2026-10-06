#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/../scripts" && pwd)/code-review.sh" "$@"
