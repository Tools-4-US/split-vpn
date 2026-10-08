# Security policy

Geleit installs a privileged helper and handles VPN credentials, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository.

Include the affected client (e.g. macOS), version or commit, and steps to reproduce. You should receive an answer within a few days.

## Scope

Especially relevant:

- Any way for an unprivileged process to make `geleit-helper` run arbitrary code, write arbitrary files or alter routes/DNS beyond what its subcommands allow.
- Leaks of the SSO cookie, passwords or the generated `openfortivpn` configuration.
- Certificate validation bypasses when connecting to the gateway.

Vulnerabilities in `openfortivpn` itself should be reported upstream at <https://github.com/adrienverge/openfortivpn>.
