# Security

This document describes the security properties and limitations of OSymbiote 0.4.0. The project is experimental and has not undergone an independent security audit.

## Security boundary

OSymbiote is designed as a small Linux guest, not as a sandbox around untrusted users. The console shell and HTTP handler execute with root privileges. Native file and command tools therefore have high impact even when invoked through the portal.

The HTTP service uses cleartext HTTP. Session cookies and API traffic are not encrypted by the guest. QEMU's user-mode networking and host port forwarding are not an authorization layer; exposure depends on host and network configuration.

## Authentication and roles

- Initial setup establishes one shared portal password; this does not create separate Unix users.
- The password is stored as a salted hash, while active session state is stored under the guest data directory.
- Sessions expire after 900 seconds.
- Setup and login are rate-limited to 15 requests per minute and lock out after five consecutive failures for a temporary period.
- Role policy gates read, write, execution, and configuration endpoints. Role gates do not drop process privileges or constrain the console shell.
- The default `exec_role=root` means command execution is restricted to the configured root role; `sudo_mode=disabled` blocks web command execution.

## LLM tools and confirmation

The tool surface is an allowlist: read text file, write text file, or execute a shell command. Tool proposals do not by themselves execute writes or commands. The portal asks for per-operation approval and sends `X-OSYM-User-Confirmed: yes`; the handler also requires a valid session and the relevant role.

The confirmation header is a protocol precondition, not a trustworthy user-presence signal. A malicious or compromised authenticated client can send it directly. Do not treat this design as a defense against session theft, browser compromise, hostile same-host users, or an attacker who can reach the API and authenticate.

## Credentials and persistent data

Provider keys are stored in an allowlisted, raw `KEY=value` file at `/data/osymbiote/.env`; the file is parsed rather than sourced and is set to mode `0600` in the guest. System policy is stored separately in `system.conf`. The provider API reports key presence/masking rather than returning the saved key.

With QEMU persistence enabled, the host `data/` directory contains guest credentials and personal data. It is not encrypted by OSymbiote. Restrict host access, use secure backups, and do not commit it. Without a persistent share, state in the initramfs may be lost when the guest stops.

## Deployment guidance

1. Use OSymbiote only in a trusted development environment.
2. Keep the forwarded host port private. Do not bind or proxy it to a public/untrusted network.
3. Use a unique, strong portal password.
4. Set provider keys through the portal or guest shell; never add them to source, images, issue reports, or logs.
5. Disable web root execution with `sudo_mode=disabled` when it is not needed.
6. Back up `data/` securely and stop the guest before directly changing its files.
7. Treat all output and files read by root tools as sensitive.
8. Use an external TLS-terminating, access-controlled deployment only if its network and proxy configuration are understood; the repository does not provide or validate such a deployment.

## Reporting

Do not publish credentials, session cookies, or sensitive guest data in an issue. For a suspected security vulnerability, contact the maintainers through a private channel before filing public details.
