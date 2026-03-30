#!/usr/bin/env bash
set -euo pipefail

if [ -f ./test.sh ]; then
  chmod +x ./test.sh ./install.sh
fi

if [ -d ./scripts ]; then
  find ./scripts -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
fi

cat <<'EOF'
quick-question devcontainer is ready.

Suggested checks:
  ./test.sh
  python3 ./scripts/qq-capability.py validate --pretty
  ./scripts/qq-doctor.sh --pretty

This container is for repository development and CI-friendly tooling.
It does not replace the local Unity + tykit fast path.
EOF
