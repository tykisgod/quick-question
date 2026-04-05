#!/usr/bin/env bash
# Legacy wrapper — delegates to unified review-gate.sh
exec "$(cd "$(dirname "$0")" && pwd)/review-gate.sh" set
