# tor-relay-setup

Run your own Tor relays on Ubuntu Desktop, Ubuntu Server, or Ubuntu Server on QEMU. Automated setup scripts, WireGuard VPN kill-switch, and step-by-step guide from USB install to running relays.

---

Run Tor non-exit relays over a WireGuard VPN (optional). All relay traffic can be routed through the VPN tunnel with an nftables kill-switch that blocks any traffic outside WireGuard. Configurable number of relays (1–99, default 4) with automatic MyFamily configuration.

Works on:
- **Ubuntu Desktop** — full desktop install
- **Ubuntu Server** (recommended) — minimal, ~1 GB RAM, no GUI overhead
- **Ubuntu Server on QEMU** — run inside a virtual machine on Windows (x86_64 only)

Tested on **AMD**, **Intel**, and **ARM** (Raspberry Pi) machines. The native Ubuntu scripts work on both x86_64 and ARM architectures. QEMU VM scripts are x86_64 only.

## Installing Ubuntu

You can use Ubuntu Desktop or Ubuntu Server. Ubuntu Server is recommended — it uses ~1 GB of RAM and fewer resources than a desktop install.

### Creating a Bootable USB

1. Download and install the latest version of [Rufus](https://rufus.ie)
2. Download the [Ubuntu Server ISO](https://ubuntu.com/download/server)
3. Insert a USB drive (8 GB+)
4. Open Rufus, select the USB drive and the ISO file
5. Click **Start** and wait for it to finish

### Installing

For detailed instructions, see the [official Ubuntu installation tutorial](https://documentation.ubuntu.com/desktop/en/latest/tutorial/install-ubuntu-desktop/).

1. Boot from the USB drive (press F12/F2/Del during startup to select boot device)
2. Select **Install Ubuntu Server**
3. Follow the guided installer:
   - Choose language and keyboard layout
   - Configure network (DHCP is usually fine)
   - Use the default disk partitioning (entire disk)
   - Create your username and password
   - Enable **Install OpenSSH server** (so you can connect remotely)
   - Skip additional snaps
4. Reboot and remove the USB drive

### Running Ubuntu in QEMU (Virtual Machine)

You can also run Ubuntu Server in a virtual machine using QEMU — no dedicated hardware needed. Note: QEMU scripts are x86_64 only.

1. Download QEMU for Windows from [qemu.org/download](https://www.qemu.org/download/#windows) (download the installer, **not** the source code)
2. Install QEMU and add it to your PATH
3. Enable hardware virtualization in your BIOS/UEFI (Intel VT-x or AMD-V)
4. Create a virtual disk and boot the Ubuntu Server ISO:

```bash
# Create a 20 GB virtual disk
qemu-img create -f qcow2 ubuntu-server.qcow2 20G

# Boot from the ISO to install
qemu-system-x86_64 -m 2048 -hda ubuntu-server.qcow2 -cdrom ubuntu-server.iso -boot d

# After installation, run without the ISO
qemu-system-x86_64 -m 2048 -hda ubuntu-server.qcow2
```

---

## Do You Need a VPN?

If your ISP blocks port forwarding — for example, you're behind CGNAT (Carrier-Grade NAT) — Tor relays won't be reachable from the internet. In that case, you need a VPN provider that supports port forwarding (such as Mullvad, AirVPN, etc.) to get publicly reachable ports for your relays.

If your ISP gives you a public IP and you can forward ports on your router, you can run relays without a VPN.

### Setting Up the `share/` Folder (VPN users)

If you're using a VPN, create a `share/` folder next to the scripts and place your config files there before running `first_run`:

```
share/
├── wg0.conf          # WireGuard config from your VPN provider
├── torrc             # Config for relay 0 (Relay00)
├── torrc2            # Config for relay 1 (Relay01)
├── torrc3            # Config for relay 2 (Relay02)
└── torrc4            # Config for relay 3 (Relay03)
```

### Example `torrc` File

Each torrc file configures one relay. Here's an example for the first relay:

```
ORPort 9001

ExitRelay 0
ExitPolicy reject *:*

Nickname Relay00
ContactInfo yourEmail@example.com
MyFamily $FINGERPRINT1,$FINGERPRINT2,$FINGERPRINT3

OutboundBindAddress 10.x.x.x

SocksPort 0
ControlPort 0
DirPort 0
```

Key fields to customize:
- **ORPort** — the port forwarded by your VPN provider (different for each relay)
- **Nickname** — a unique name for each relay
- **MyFamily** — fingerprints of your other relays (auto-configured by `ubuntu_native_configure_myfamily.sh`)
- **OutboundBindAddress** — your WireGuard tunnel IP (from `wg0.conf`)
- **ContactInfo** — your email so the Tor directory can reach you

Each relay needs its own torrc with a different ORPort and Nickname.

---

## Option 1: Native Ubuntu Server (Recommended)

Run relays directly on a bare-metal or dedicated Ubuntu Server machine. Works on x86_64 and ARM (including Raspberry Pi).

### Prerequisites

- Ubuntu Server 24.04 (or compatible Debian-based system)
- A WireGuard VPN config file (`wg0.conf`) from your VPN provider (only if behind CGNAT — see above)
- ORPorts forwarded through your VPN provider or router

### Quick Start

1. Copy this repo to the server (e.g. USB stick), with `share/` containing your `wg0.conf` and torrc files (if using a VPN).

2. Run the one-time setup:
   ```
   sudo CONTACT_EMAIL="you@example.com" ./ubuntu_native_first_run.sh
   ```
   This adds the official Tor Project repository (for the latest Tor version), installs `tor`, `nftables`, `wireguard-tools`, copies configs from `share/` (if present), creates systemd services, sets up the VPN kill-switch firewall, and enables auto-start on boot.

   **Custom relay count and ports:**
   ```
   sudo CONTACT_EMAIL="you@example.com" ./ubuntu_native_first_run.sh --relays 8 --ports 9001,9002,9003,9004,9005,9006,9007,9008
   ```

   **Without VPN** (direct port forwarding, no CGNAT):
   ```
   sudo CONTACT_EMAIL="you@example.com" ./ubuntu_native_first_run.sh --no-vpn
   ```
   Skips WireGuard and firewall setup. Tor relays bind to your machine's IP directly.

   | Flag | Description |
   |------|-------------|
   | `--relays N` | Number of relay instances (default: 4) |
   | `--ports P1,P2,...` | Comma-separated ORPorts (default: 9001, 9002, ... sequential) |
   | `--no-vpn` | Skip WireGuard and firewall setup |

3. Start everything:
   ```
   sudo ./ubuntu_native_run.sh
   ```
   This brings up WireGuard, rebuilds the firewall, starts all Tor relays, and prints status. The relay count is auto-detected from installed services.

   **Without VPN:**
   ```
   sudo ./ubuntu_native_run.sh --no-vpn
   ```

4. After the first start, auto-configure MyFamily so Tor knows your relays are related:
   ```
   sudo ./ubuntu_native_configure_myfamily.sh
   ```
   This waits for all relays to generate fingerprints, then sets `MyFamily` in each torrc with the other relays' fingerprints and restarts the services.

After the first run, all services auto-start on boot. You only need `ubuntu_native_run.sh` again if you've manually stopped things.

### What Gets Installed

| Component | Details |
|-----------|---------|
| Tor (official repo) | Latest version from `deb.torproject.org` (codename: `jammy`), signing key in `/usr/share/keyrings/tor-archive-keyring.gpg` |
| WireGuard | Tunnel config at `/etc/wireguard/wg0.conf` |
| nftables kill-switch | Script at `/usr/local/sbin/vpn-firewall-rebuild`, config in `/etc/vpn-firewall/` |
| Tor relay services | `tor-relay@tor0` through `tor-relay@torN`, configs at `/etc/tor/torN.torrc` |

**Note on the Tor repository:** The signing key fingerprint (`A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89`) and codename (`jammy`) are hardcoded in the script. The Tor Project supports LTS bases first, so `jammy` is used even on Ubuntu 24.04 (noble). If the Tor Project rotates the signing key or adds newer codename support, update `TOR_KEYRING_ID` and the `jammy` codename in `ubuntu_native_first_run.sh`.

**Recommended post-install tools:**
- **`nyx`** — live relay monitoring dashboard (bandwidth, circuits, flags). Each relay has a `ControlSocket` in its data directory for nyx to connect to:
  ```bash
  sudo apt install nyx
  sudo nyx -s /var/lib/tor-instances/tor0/control_socket
  ```
- **`unattended-upgrades`** — automatic security updates: `sudo apt install unattended-upgrades && sudo dpkg-reconfigure unattended-upgrades`

### Relay Defaults

By default (no flags), 4 relays are created with sequential ports starting at 9001:

| Service | Nickname | ORPort | Data Directory |
|---------|----------|--------|----------------|
| `tor-relay@tor0` | Relay00 | 9001 | `/var/lib/tor-instances/tor0` |
| `tor-relay@tor1` | Relay01 | 9002 | `/var/lib/tor-instances/tor1` |
| `tor-relay@tor2` | Relay02 | 9003 | `/var/lib/tor-instances/tor2` |
| `tor-relay@tor3` | Relay03 | 9004 | `/var/lib/tor-instances/tor3` |

Use `--relays N` and `--ports` to customize. All relays are non-exit (`ExitRelay 0`).

### VPN Kill-Switch Firewall

The firewall drops all traffic that doesn't go through `wg0`, except:
- WireGuard handshake packets to the VPN endpoint (so the tunnel can establish)
- SSH (configurable: from anywhere by default, or only over `wg0`)
- Inbound Tor ORPorts over `wg0`

Configuration files in `/etc/vpn-firewall/`:
- `env` — toggles like `ALLOW_SSH_OUTSIDE_WG=1`
- `allow-ports` — list of ports to open (e.g. `tcp:9001`)

### share/ Directory

If `share/` is present next to the scripts, `first_run` auto-copies configs to system locations:

| Source in share/ | Destination |
|------------------|-------------|
| `wg0.conf` | `/etc/wireguard/wg0.conf` |
| `torrc` | `/etc/tor/tor0.torrc` |
| `torrc2` | `/etc/tor/tor1.torrc` |
| `torrc3` | `/etc/tor/tor2.torrc` |
| `torrc4` | `/etc/tor/tor3.torrc` |
| `tor-identities-*/` | `/var/lib/tor-instances/tor{0-3}/keys/` |

If `share/` is absent, the script generates torrc files from built-in relay parameters. You just need to place `wg0.conf` in `/etc/wireguard/` manually before running.

### Restoring Relay Identity

To keep the same relay fingerprints after migrating, place the `tor-identities-*` backup directory inside `share/` before running `first_run`. The script copies the identity keys automatically.

If starting fresh (no keys), Tor generates new ones on first start. Run `ubuntu_native_configure_myfamily.sh` afterwards to set up MyFamily automatically.

### Managing Services

```bash
# Check status of all relays (auto-detects count)
sudo ./ubuntu_native_run.sh

# Restart a single relay
sudo systemctl restart tor-relay@tor1

# View logs for a relay
sudo journalctl -u tor-relay@tor2 -f

# Stop all relays manually
for i in /etc/systemd/system/tor-relay@tor*.service; do
  sudo systemctl stop "$(basename "$i" .service)"
done
sudo wg-quick down wg0
```

### Uninstalling

To cleanly remove everything installed by the setup scripts:

```
sudo ./ubuntu_native_uninstall.sh
```

This stops and disables all relay services, removes systemd unit files, torrc files, WireGuard, and firewall configuration.

| Flag | Description |
|------|-------------|
| `--no-vpn` | Skip WireGuard and firewall removal |
| `--purge` | Also remove relay data directories; prompts to remove packages and wg0.conf |

Examples:
```bash
# Remove everything (services, configs, VPN, firewall)
sudo ./ubuntu_native_uninstall.sh

# Remove relays only, keep VPN and firewall
sudo ./ubuntu_native_uninstall.sh --no-vpn

# Full removal including data, packages, and WireGuard config
sudo ./ubuntu_native_uninstall.sh --purge
```

---

## Ubuntu Native Scripts — Quick Guide

This guide explains how to mount a USB drive, copy your scripts (`ubuntu_native_first_run.sh` and `ubuntu_native_run.sh`), make them executable, and verify Tor relay identities.

### Scripts Included

* `ubuntu_native_first_run.sh` — initial setup script
* `ubuntu_native_run.sh` — normal runtime script
* `ubuntu_native_configure_myfamily.sh` — auto-configure MyFamily after first start
* `ubuntu_native_uninstall.sh` — clean removal of everything

Recommended location:

```
~/scripts
```

Do **not** place personal scripts in system directories such as `/root`, `/bin`, `/usr/bin`, or `/etc`. These are reserved for OS and package-managed files.

### Step 1 — Identify the USB Device

```bash
lsblk
```

Example output might show `sdb1` — this is your USB partition.

### Step 2 — Create a Mount Point

A mount point is simply a directory where Linux attaches the USB.

```bash
sudo mkdir /mnt/usb
```

### Step 3 — Mount the USB

```bash
sudo mount /dev/sdb1 /mnt/usb
```

No output usually means success.

### Step 4 — Access the USB

```bash
cd /mnt/usb
ls
```

You should now see your scripts.

### Step 5 — Create a Scripts Folder (Recommended)

```bash
mkdir -p ~/scripts
```

This creates a clean, predictable location: `/home/youruser/scripts`

### Step 6 — Copy Scripts from USB

If inside `/mnt/usb`:

```bash
cp ubuntu_native_*.sh ~/scripts/
```

Verify:

```bash
ls ~/scripts
```

### Step 7 — Make Scripts Executable (Important)

Linux does NOT assume scripts are runnable.

```bash
cd ~/scripts
chmod +x ubuntu_native_*.sh
```

Check permissions:

```bash
ls -l
```

Look for `-rwxr-xr-x` — the **x** means executable.

### Step 8 — Run the Scripts

First-time setup:

```bash
sudo ./ubuntu_native_first_run.sh
```

Normal operation:

```bash
sudo ./ubuntu_native_run.sh
```

### Safely Remove the USB

Never unplug a mounted drive. Always run:

```bash
sudo umount /mnt/usb
```

Then remove the device.

### Verify Tor Relay Identity

To confirm relay fingerprints:

```bash
for f in /var/lib/tor-instances/tor*/fingerprint; do sudo cat "$f"; done
```

Example output:

```
Relay00 A94F3F6C8B7A...
```

* The first word is the relay nickname
* The long hexadecimal string is the relay identity

The fingerprint is the trusted identifier in the Tor network.

### Quick Troubleshooting

**USB not mounting?** Re-check device name:

```bash
lsblk
```

**Permission denied when running scripts?** Make sure they are executable:

```bash
chmod +x ~/scripts/*
```

### Recommended Workflow Summary

1. Identify USB — `lsblk`
2. Mount — `/mnt/usb`
3. Copy scripts — `~/scripts`
4. Make executable — `chmod +x`
5. Run scripts
6. Unmount USB safely

---

## Option 2: QEMU Virtual Machine on Windows (Legacy)

Run Ubuntu Server inside a QEMU VM on a Windows host. Useful if you don't have a dedicated machine. x86_64 only.

### Prerequisites

- Windows with [QEMU](https://www.qemu.org/download/#windows) installed at `C:\QEMU`
- Ubuntu Server 24.04 ISO at `C:\Users\User\Desktop\QEMU_Ubuntu\ubuntu-24.04.3-live-server-amd64.iso`

### Scripts

- **`ubuntu-qemu-first-run.ps1`** — One-time: creates a 40GB qcow2 virtual disk and boots the ISO for installation. Uses TCG (software emulation).
- **`ubuntu-qemu-start.ps1`** — Day-to-day: boots the VM with accelerator fallback (WHPX → TCG). Automatically disables 9p host share if unsupported by the QEMU build.
- **`ubuntu-qemu-hostshare.ps1`** — Sets up a Windows local user and folder permissions so the guest can access `share/` via SMB.

### VM Configuration

- Q35 chipset, 4 CPUs, 4GB RAM, SDL display
- qcow2 disk with virtio-blk-pci
- User-mode networking with SSH: `ssh -p 2222 <user>@localhost`
- Optional host share via virtio-9p-pci (mount tag: `hostshare`)

### Accelerator Fallback Order

1. WHPX + qemu64 (kernel-irqchip=off)
2. WHPX + Westmere (kernel-irqchip=off)
3. WHPX + host (kernel-irqchip=off)
4. TCG multi-threaded + cpu=max (always works)

### Path Assumptions

Scripts hardcode `C:\Users\User\Desktop\QEMU_Ubuntu` and `C:\QEMU`. Update `$Base` and `$QEMU` variables at the top of each script if your paths differ.

### Logs

Run logs are written to `logs/` with timestamped filenames. They capture the full QEMU command line and stderr output for debugging.
