# Security

## Known Limitations

- **tykit is localhost-only with no authentication.** Any local process can send HTTP commands to Unity Editor via tykit. This is acceptable for development machines but should not be used in shared or CI environments without additional network controls.

- **Hook scripts execute shell commands.** The hook system runs bash scripts in response to Claude Code tool use events. Only install plugins from trusted sources.

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it privately by opening a [security advisory](https://github.com/tykisgod/quick-question/security/advisories/new) rather than a public issue. We will respond within 48 hours.
