# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Scripts for running configurable Tor non-exit relays over a WireGuard VPN. Two deployment modes:

1. **QEMU VM on Windows** (legacy) — PowerShell scripts that run an Ubuntu 24.04 Server VM via QEMU.
2. **Native Ubuntu Server** (current) — Bash scripts for bare-metal or dedicated Ubuntu installs (x86_64 and ARM).

## Native Ubuntu Scripts

Four-script workflow:

- **`ubuntu_native_first_run.sh`** — One-time setup (run as root). Accepts `--relays N` (default 4), `--ports P1,P2,...` (default sequential from 9001), and `--no-vpn`. Adds the official Tor Project repository (deb.torproject.org) for the latest Tor version, auto-copies configs from `share/` if present (wg0.conf, torrc files, identity keys), installs packages (`tor`, `deb.torproject.org-keyring`, `nftables`, `wireguard-tools`), creates N systemd services (`tor-relay@tor0` through `tor-relay@tor{N-1}`), sets up the VPN kill-switch firewall, enables auto-start on boot.
- **`ubuntu_native_run.sh`** — Brings up WireGuard, rebuilds nftables firewall, starts all `tor-relay@` services, prints status. Accepts `--no-vpn` and `--relays N`. Auto-detects relay count from installed systemd service files if `--relays` not given. Hints to run `ubuntu_native_configure_myfamily.sh` if MyFamily is unconfigured.
- **`ubuntu_native_configure_myfamily.sh`** — Auto-configures MyFamily in all torrc files. Detects instances from systemd services, waits for fingerprint files (with `--timeout N`, default 120s), sets MyFamily in each torrc to the other relays' fingerprints, restarts services.
- **`ubuntu_native_uninstall.sh`** — Clean removal. Accepts `--no-vpn` (skip VPN removal) and `--purge` (also remove data directories, optionally packages and wg0.conf). Auto-detects instances from systemd services.

### Tor Relay Instances

Default configuration (no flags) creates 4 relays with sequential ports:

| Instance | Nickname | ORPort | Config file | Data directory |
|----------|----------|--------|-------------|----------------|
| tor0 | Relay00 | 9001 | `/etc/tor/tor0.torrc` | `/var/lib/tor-instances/tor0` |
| tor1 | Relay01 | 9002 | `/etc/tor/tor1.torrc` | `/var/lib/tor-instances/tor1` |
| tor2 | Relay02 | 9003 | `/etc/tor/tor2.torrc` | `/var/lib/tor-instances/tor2` |
| tor3 | Relay03 | 9004 | `/etc/tor/tor3.torrc` | `/var/lib/tor-instances/tor3` |

Customizable via `--relays N` and `--ports P1,P2,...`. All relays are non-exit (`ExitRelay 0`), bound outbound to the WireGuard tunnel IP, and declare each other via `MyFamily` (configured by `ubuntu_native_configure_myfamily.sh`).

### VPN Kill-Switch Firewall

`/usr/local/sbin/vpn-firewall-rebuild` generates nftables rules that:
- Drop all traffic not going through `wg0` (kill-switch)
- Allow WireGuard handshake to the VPN endpoint
- Allow inbound Tor ORPorts via `vpn_inbound_tcp` set
- Allow SSH (configurable: from anywhere or only over `wg0`)

Config files in `/etc/vpn-firewall/`: `env` (toggles), `allow-ports` (ORPorts, dynamically generated from relay config).

### Config Source Mapping (share/ → system)

| share/ file | Destination |
|-------------|-------------|
| `wg0.conf` | `/etc/wireguard/wg0.conf` |
| `torrc` | `/etc/tor/tor0.torrc` |
| `torrc2` | `/etc/tor/tor1.torrc` |
| `torrc3` | `/etc/tor/tor2.torrc` |
| `torrc{N}` | `/etc/tor/tor{N-1}.torrc` |
| `tor-identities-*/` | `/var/lib/tor-instances/tor{0..N-1}/keys/` |

If `share/` is absent, `first_run` generates torrc files from relay parameters (nicknames and ports).

### Tor Project Repository

`first_run` adds the official Tor Project apt repository (`deb.torproject.org`) so relays run the latest stable Tor instead of the older Ubuntu-packaged version.

- **Signing key**: `A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89` — hardcoded in the script as `TOR_KEYRING_ID`. If the Tor Project rotates this key, update it from [deb.torproject.org](https://deb.torproject.org/torproject.org/).
- **Codename**: `jammy` — hardcoded because the Tor Project supports LTS bases first. Even on Ubuntu 24.04 (noble), `jammy` packages are used. Update when Tor adds newer codename support.
- **Keyring**: stored at `/usr/share/keyrings/tor-archive-keyring.gpg`, referenced via `signed-by` in `/etc/apt/sources.list.d/tor.list`.

## QEMU VM Scripts (Legacy)

- **`ubuntu-qemu-first-run.ps1`** — One-time: creates a 40GB qcow2 disk and boots the Ubuntu Server ISO for installation. Uses TCG (software emulation).
- **`ubuntu-qemu-start.ps1`** — Day-to-day launcher with accelerator fallback (WHPX qemu64 → WHPX Westmere → WHPX host → TCG). Handles 9p/virtfs share failures by retrying without share args.
- **`ubuntu-qemu-hostshare.ps1`** — Sets up Windows local user and NTFS/share permissions for guest SMB access.

### VM Configuration

- **Machine**: Q35, 4 CPUs, 4GB RAM, SDL display
- **Disk**: qcow2 with virtio-blk-pci, writeback cache, discard/unmap
- **Network**: User-mode, SSH port forwarding (host 2222 → guest 22)
- **Host share**: virtio-9p-pci (`hostshare` mount tag)
- **Path assumptions**: `C:\Users\User\Desktop\QEMU_Ubuntu` and `C:\QEMU`

## share/ Directory

Host↔guest file exchange folder containing WireGuard configs, Tor relay configs (torrc–torrc4), Tor identity key backups, and VPN setup notes. Gitignored (contains private keys).

## Logs

QEMU run logs in `logs/` with timestamped filenames. Capture command lines and stderr for diagnosing accelerator or device errors.

## Commit Convention

```
[Scope] Action: Short description (keywords)
```

- **Scope**: area of the project, e.g. `Native`, `QEMU`, `Firewall`, `Docs`, `Project`
- **Action**: what was done, e.g. `Add`, `Fix`, `Update`, `Remove`, `Refactor`
- **Keywords**: relevant technologies or concepts in parentheses

Examples:
```
[Project] Init: Setup scripts for Tor relays over WireGuard (tor, nftables, systemd)
[Native] Add: Auto-copy configs from share/ on first run (wireguard, torrc)
[Firewall] Fix: Allow DHCP on uplink interface (nftables)
[Docs] Update: README with native deployment instructions (readme)
```
