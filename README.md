# oracle-flex-create

`oracle-flex-create` is a small OCI CLI watcher that keeps trying to acquire an Always Free `VM.Standard.A1.Flex` instance and sends a Telegram message once the launch succeeds.

It is meant to run on a separate watcher VM, such as your existing `VM.Standard.E2.1.Micro`.

## What It Does

- checks all availability domains in the configured region
- optionally asks OCI for a compute capacity report before launching
- retries on capacity and transient OCI errors
- stops on terminal auth, config, subnet, shape, or image errors
- sends Telegram on success
- can also send one Telegram alert when it stops because of a terminal error

## Files

- `acquire_a1.sh`: main watcher script
- `acquire_a1.env.example`: sample runtime configuration
- `oracle-flex-create.service`: sample `systemd` unit
- `deploy.sh`: deployment helper for install and updates.


## Setup

1. Install the runtime dependencies on the watcher VM:

```bash
sudo apt-get update
sudo apt-get install -y jq curl
```

2. Make sure the OCI CLI is installed and authenticated on the watcher VM.

If you installed OCI CLI with Oracle's default root installer path, it may live at `/root/bin/oci`. The included service now adds `/root/bin` to `PATH`, and you can also pin it explicitly in the env file with:

```bash
OCI_BIN="/root/bin/oci"
```

3. Deploy the watcher after clone and after each `git pull`:

```bash
cd oracle_flex_create
chmod +x deploy.sh
./deploy.sh
```

The deploy script:

- installs `acquire_a1.sh` to `/opt/oracle-flex-create/acquire_a1.sh`
- installs `oracle-flex-create.service` to `/etc/systemd/system/oracle-flex-create.service`
- creates `/etc/oracle-flex-create/acquire_a1.env` from the example only if it does not already exist
- runs `systemctl daemon-reload`
- enables and restarts `oracle-flex-create.service` on normal updates
- prints the last 50 journal lines after restart

On the first deployment, if the env file does not exist yet, `deploy.sh` creates it and stops without restarting the service so you can fill in the real values safely.

4. Edit `/etc/oracle-flex-create/acquire_a1.env` and set:

- `OCI_REGION`
- `COMPARTMENT_OCID`
- `SUBNET_OCID`
- `SSH_PUBLIC_KEY_PATH`
- `INSTANCE_DISPLAY_NAME`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

5. Edit `/etc/oracle-flex-create/acquire_a1.env`, then test Telegram:

```bash
/opt/oracle-flex-create/acquire_a1.sh --env-file /etc/oracle-flex-create/acquire_a1.env --test-telegram
```

6. If you prefer the manual deployment steps instead of `deploy.sh`:

```bash
sudo install -d -m 0755 /opt/oracle-flex-create /etc/oracle-flex-create
sudo install -m 0755 acquire_a1.sh /opt/oracle-flex-create/acquire_a1.sh
sudo install -m 0644 oracle-flex-create.service /etc/systemd/system/oracle-flex-create.service
sudo install -m 0600 acquire_a1.env.example /etc/oracle-flex-create/acquire_a1.env
sudo systemctl daemon-reload
sudo systemctl enable --now oracle-flex-create.service
```

## Operations

Check status:

```bash
systemctl status oracle-flex-create.service
```

Follow logs:

```bash
journalctl -u oracle-flex-create.service -f
```

Run manually:

```bash
./acquire_a1.sh --env-file ./acquire_a1.env
```

## Notes

- The watcher only works in the configured region; it does not try other regions.
- `CAPACITY_REPORT_COMPARTMENT_OCID` is optional because some tenants need the tenancy/root compartment OCID for the capacity-report API.
- If capacity-report calls fail, the watcher logs that and still performs a direct launch attempt.
- The created instance is not imported into Terraform state; this watcher is intentionally a plain OCI CLI launcher.
