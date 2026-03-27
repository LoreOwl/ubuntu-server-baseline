![Lint & Validate](https://github.com/LoreOwl/ubuntu-server-baseline/actions/workflows/lint.yml/badge.svg)

I built this to eliminate the 70-minute manual setup process every time I provision a new VM.
# ubuntu-server-baseline

Single interactive Bash script that takes a fresh Ubuntu 24.04 LTS install from stock to a hardened, monitored Docker host. One run, one reboot, done.

## What it sets up

**OS hardening** — creates a non-root sudo user, configures UFW (deny-all ingress by default), deploys fail2ban with systemd backend, disables SSH password auth and root login, restricts SSH to a single `AllowUsers` account with key-only access. Includes a built-in lockout safety check that pauses mid-run so you can verify your key works before continuing.

**Docker** — installs Docker CE and Compose plugin from Docker's official apt repo (not Snap). Configures global JSON log rotation and overlay2 storage. Adds the admin user to the `docker` group.

**Portainer CE** — deployed as a standalone container. HTTP port (9000) bound to loopback only; external access is HTTPS on 9443. Admin account is created and authenticated via the Portainer API during setup, so the monitoring stack can be deployed programmatically in the same run.

**Monitoring stack** — Prometheus, Node Exporter, and Grafana deployed as a Portainer-managed Compose stack. Node Exporter listens only on an internal Docker bridge network (port 9100 is never exposed to the host). Grafana ships with Prometheus pre-configured as a datasource. Credentials are injected via the Portainer API environment, not written to disk.

**Static IP** — writes a netplan config for the target IP but does not apply it until reboot, so the script finishes over the existing DHCP session without dropping your SSH connection. Disables cloud-init network management to prevent config overwrite.

## Requirements

- Fresh Ubuntu 24.04 LTS (Server or minimal install)
- Root/sudo access
- An SSH public key (ed25519, RSA, or ECDSA)
- Must be run interactively (not piped)

## Usage

1. Open `server_setup.sh` and fill in the `CHANGE_ME` values in the configuration block at the top: static IP, gateway, network interface, usernames, and SSH public key.

2. Copy it to the target machine and run it:

```bash
scp server_setup.sh user@<current-ip>:~/
ssh user@<current-ip>
chmod +x server_setup.sh && sudo bash server_setup.sh
```

3. The script will prompt for three passwords interactively (OS user, Portainer admin, Grafana admin). Nothing is written to the script file.

4. When it reaches SSH hardening, it will pause and ask you to verify key-based login from a second terminal before continuing.

5. After completion, reboot. Reconnect on the new static IP.

## Ports

| Port | Service | Exposure |
|------|---------|----------|
| 22 | SSH | External (key-only) |
| 3000 | Grafana | External |
| 9090 | Prometheus | External |
| 9443 | Portainer HTTPS | External |
| 9000 | Portainer HTTP | Loopback only |
| 9100 | Node Exporter | Internal Docker network only |

## Design decisions

**Single script, no Ansible.** This is purpose-built for provisioning one machine from bare metal. Ansible adds a control node dependency and abstraction layers that aren't justified for a single-host setup. The script is readable top-to-bottom and runs in the order it reads.

**Interactive credential entry.** Passwords are prompted at runtime with confirmation, not hardcoded in the file. Safe to commit the script to version control as-is.

**Phased execution with debug checks.** Each phase ends with validation checks that report pass/fail status. A failed check warns and doesn't halt the script, since the phase already completed its work. This makes it easy to see exactly where things went wrong on a partial run.

**Portainer API-driven stack deployment.** The monitoring stack is deployed through Portainer's API rather than `docker compose up`, so it appears in Portainer's UI as a managed stack from the start.

## Image versions

All container images are pinned to specific tags in the configuration block. Update them manually when you're ready to upgrade:

| Service | Default image |
|---------|--------------|
| Portainer CE | `portainer/portainer-ce:2.21.4` |
| Prometheus | `prom/prometheus:v2.53.2` |
| Node Exporter | `prom/node-exporter:v1.8.2` |
| Grafana | `grafana/grafana:11.3.2` |

## Post-setup

1. **Reboot** — `sudo reboot`, then reconnect via the static IP.
2. **Verify stack** — Portainer UI (https://\<ip\>:9443) → Stacks → confirm "monitoring" is running.
3. **Import a dashboard** — Grafana → Dashboards → Import → ID `1860` (Node Exporter Full).

## License

MIT
