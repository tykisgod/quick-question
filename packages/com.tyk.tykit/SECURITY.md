# Security

## Known Limitations

- **Localhost-only, no authentication.** tykit binds to `http://localhost:{port}/` with no auth. Any process on the same machine can send commands to Unity Editor. This is by design for development workflows but means:
  - Do not expose the port to the network
  - Do not run on shared machines without network controls
  - Do not use in CI environments where untrusted code may execute

- **Full Editor access.** tykit can execute any Editor command: create/destroy GameObjects, modify scenes, run arbitrary menu items. A malicious local process could use this to corrupt project data.

- **Port info in Temp/.** The file `Temp/tykit.json` contains the port number and PID. Any local process can read it to discover the server.

## Mitigations

- The server only listens on `localhost` (not `0.0.0.0`)
- The server shuts down when Unity Editor quits
- `Temp/tykit.json` is deleted on editor quit
- Port range is limited to 8090-8153

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it privately via the [quick-question security advisory page](https://github.com/tykisgod/quick-question/security/advisories/new) rather than a public issue. We will respond within 48 hours.
