# AGENT.md

This repository implements a small OCI watcher that continuously tries to acquire an Always Free `VM.Standard.A1.Flex` instance and notifies you via Telegram when the launch succeeds or when the watcher stops on a terminal error.

## Project Purpose

- Run an OCI CLI-based watcher loop to claim an A1 Flex instance automatically.
- Optionally request a compute capacity report before attempting launch.
- Retry on transient capacity and OCI errors.
- Stop on terminal failures such as authentication, configuration, subnet, shape, or image errors.
- Send Telegram notifications for success and failure states.

## Key Files

- `acquire_a1.sh`: main watcher script and entrypoint.
- `acquire_a1.env.example`: sample runtime configuration file.
- `oracle-flex-create.service`: sample `systemd` unit for running the watcher as a service.
- `deploy.sh`: deployment helper for install and updates.
- `README.md`: usage, installation, and operation guidance.

## Important Operating Rules

- Keep Telegram bot tokens, chat IDs, SSH public keys, and compartment/subnet OCIDs out of git-tracked files.
- Run the watcher on a separate management VM, not on the target A1 instance.
- Use `--test-telegram` or the corresponding env-file flag before enabling the service to verify notifications.
- Do not expose the watcher service publicly; the process only needs outbound OCI and Telegram access.

## Implementation Notes

- The watcher checks all availability domains in the configured region.
- Capacity report lookup is optional and may be required by some tenants using the tenancy/root compartment.
- The script gracefully handles transient OCI API errors and retries accordingly.
- Terminal errors stop the watcher to avoid repeated failed launches and to surface the problem.
- Created instances are not tracked in Terraform state by design; this is an OCI CLI launcher.

## Editing Guardrails

- Prefer minimal, targeted edits over broad refactors.
- Keep shell logic and environment handling easy to audit.
- Do not add real secrets or personal values to tracked files.
- Avoid echoing tokens, password-like values, private keys, or OCIDs in docs or examples.
- When updating docs, keep the tone factual and concise.

## Useful Defaults For Future Codex Sessions

- Assume the user values conservative, recoverable changes.
- Assume security is preferred over convenience for remote management.
- If a proposed change would make the watcher behave more aggressively or expose credentials, ask first.
