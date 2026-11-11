# homelab-seed

Turn a Raspberry Pi into the first, self-installing node of your homelab.

You build a USB stick image on your computer. Plug it into the Pi, power on,
and walk away: the stick writes a fresh, pre-configured Raspberry Pi OS to the
SD card, the Pi reboots into it and sets itself up – updates, Docker,
[Semaphore UI](https://semaphoreui.com) for Ansible, optionally an nginx
reverse proxy with HTTPS, and your own Ansible project that takes over from
there. Every part can be switched on or off.

```
 build.sh ──▶ USB stick ──boot──▶ installer writes + verifies SD card ──reboot──▶
 SD card: first-boot setup ──▶ Docker ─▶ Semaphore ─▶ (nginx + TLS) ─▶ your bootstrap playbook
```

## Features

- **Fully unattended**: no keyboard, monitor or wizard needed
- **Safe installer**: refuses to overwrite the disk it runs from, verifies the
  written image, does not reinstall an already installed system
- **Resumable setup**: every step runs once; if one fails (e.g. no network),
  systemd retries and the setup continues where it stopped
- **Secure defaults**: SSH keys only, no root login, secrets are deleted from
  the system after the setup
- **Safe updates**: `homelab-seed-update` pulls first and rolls back if the new
  container does not start
- **Pluggable reverse proxy**: other services just drop their server blocks
  into `/etc/nginx/conf.d`
- **HTTPS your way**: none, self-signed, or Let's Encrypt via HTTP-01 or
  DNS-01 (Cloudflare, mittwald)
- **Network**: Ethernet or Wi-Fi, DHCP or static IP, custom DNS and NTP
- **Maintenance**: automatic security updates, optional ufw firewall
- **Extensible**: extra packages and your own hook scripts without forking

## Requirements

**To build**, one of:

- **Linux / macOS**: Docker, then `./build.sh`
- **Windows**: Docker Desktop, then `.\build.ps1` in PowerShell – no WSL shell,
  Git Bash or Linux tools needed
- **GitHub Actions**: nothing locally – see [Building in GitHub Actions](#building-in-github-actions)

Local builds need about 15 GB of free disk space for Docker.

**To run:** a Raspberry Pi with 64-bit support that can boot from USB
(Pi 3B+, 4, 5), an SD card (≥ 8 GB) as the target, a USB stick (≥ 16 GB), and
internet access via Ethernet or Wi-Fi.

## Quick start

```bash
git clone https://github.com/chris199512/homelab-seed.git
cd homelab-seed
cp config.example.env config.env
mkdir -p secrets && cp ~/.ssh/id_ed25519.pub secrets/authorized_keys
# edit config.env: at least ADMIN_PASSWORD and SEMAPHORE_ADMIN_PASSWORD
./build.sh
```

### Windows

Install [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)
and start it. Then, in PowerShell:

```powershell
git clone -c core.autocrlf=false https://github.com/chris199512/homelab-seed.git
cd homelab-seed
Copy-Item config.example.env config.env
New-Item -ItemType Directory secrets
Copy-Item $HOME\.ssh\id_ed25519.pub secrets\authorized_keys
notepad config.env   # at least ADMIN_PASSWORD and SEMAPHORE_ADMIN_PASSWORD
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

No Git? Download the repository as ZIP from GitHub instead and unpack it –
the line endings are correct either way. Keep the folder on a local drive:
Docker Desktop cannot share mapped network drives with containers.
`build.ps1 -Config <file> -Output <dir> -Xz` takes the same options as `build.sh`.

### Flashing

The image ends up in `out/`. Write it to the USB stick with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/) ("Use custom",
**without** OS customisation) or [balenaEtcher](https://etcher.balena.io/).

Then:

1. Insert the SD card (it will be **erased**) and the USB stick into the Pi.
2. Power on. Use an empty SD card: if it still holds a bootable system, the Pi
   boots that instead of the stick.
3. The installer writes the SD card (progress is shown on HDMI) and reboots.
4. The Pi boots from the SD card and sets itself up. This takes 10–30 minutes
   and ends with a reboot. You can remove the USB stick now.
5. Open Semaphore at `http://<pi>:3000`, or through the proxy at
   `http(s)://<SEMAPHORE_FQDN or pi>`.

Watch progress over SSH with `journalctl -fu homelab-seed-setup`.

### Booting from USB

- **Pi 3B+**: USB boot has to be enabled once: add `program_usb_boot_mode=1`
  to `config.txt` of any Raspberry Pi OS SD card, boot it once, then remove the
  line again. The setting is permanent.
- **Pi 4 / 5**: USB boot is supported out of the box. The default boot order
  tries the SD card first, then USB – which is exactly what homelab-seed relies on.

## Configuration

Everything is configured in `config.env`; [`config.example.env`](config.example.env)
documents every setting and holds the defaults – a setting you leave out keeps
its example value. The build validates the file and reports all problems at
once. Files and directories referenced from the config (SSH keys, secrets,
hooks) are resolved relative to `config.env`.

| Area | Settings |
| --- | --- |
| System | hostname, locale, keyboard, timezone, admin user with SSH keys |
| Network | Ethernet or Wi-Fi, DHCP or static IPv4, DNS servers, NTP servers |
| Installer | target disk, behaviour if a system is already installed, reboot or power off |
| Setup | system upgrade on/off, reboot when done on/off, extra packages, hooks |
| Security | unattended security updates (optional automatic reboot), ufw firewall |
| Components | Docker, Semaphore, nginx proxy – each on/off, ports configurable |
| Semaphore | version, admin account, TOTP, e-mail alerts |
| TLS | none, self-signed, Let's Encrypt via HTTP-01 or DNS-01 |
| Bootstrap | Semaphore project, repository, keys, inventory, secret environment, bootstrap playbook |

A minimal setup – just a hardened, updated Pi without any services:

```bash
DOCKER_ENABLED="false"
SEMAPHORE_ENABLED="false"
```

### Network

The network settings are applied to both the installer stick and the installed
system, so you can SSH into the installer as well. Wi-Fi needs `WIFI_SSID`,
`WIFI_PASSWORD` and `WIFI_COUNTRY`; a static address needs `NETWORK_ADDRESS`
(with prefix length), `NETWORK_GATEWAY` and `NETWORK_DNS`.

### Hooks

Point `HOOKS_DIR` to a directory with `*.sh` scripts. They run as root at the
end of the setup – after Semaphore and the proxy, before the firewall is
enabled – in alphabetical order. Every setting from `config.env` is available
as an environment variable. Each hook runs once; a failing hook fails the
setup, which is retried, so write hooks that can run again safely.

```bash
# hooks/10-motd.sh
echo "Welcome to $TARGET_HOSTNAME" > /etc/motd
```

### Bootstrap: handing over to Ansible

With `BOOTSTRAP_ENABLED="true"` the setup creates a Semaphore project that is
connected to your Ansible repository, including SSH and sudo credentials, an
inventory and an environment with your secrets (`BOOTSTRAP_SECRETS_FILE`, one
`KEY=VALUE` per line). An API token of the admin user is always added as
`SEMAPHORE_TOKEN`, so your playbooks can manage Semaphore itself – for example
to create further templates.

`BOOTSTRAP_PLAYBOOK` is then registered as a template and run.
`BOOTSTRAP_RUN_AFTER` runs more templates afterwards, one after another, in
the order you list them – useful when the bootstrap playbook creates them. All
resource names are configurable, so existing playbooks that look them up by
name keep working.

### TLS certificates

HTTPS requires `PROXY_ENABLED="true"`; choose the certificate with `TLS_MODE`:

| `TLS_MODE` | When to use | Needs |
| --- | --- | --- |
| `none` | plain HTTP in a trusted network | – |
| `selfsigned` | HTTPS in the LAN without a public domain; browsers warn | – |
| `letsencrypt-http` | the Pi is reachable from the internet | `SEMAPHORE_FQDN` pointing to it, port 80 reachable |
| `letsencrypt-dns` | internal hosts with a public domain | API token of your DNS provider |

The proxy always starts with HTTP; once the certificate exists it switches to
HTTPS and redirects HTTP. Let's Encrypt certificates are renewed by certbot's
systemd timer and nginx is reloaded afterwards. Set `ACME_STAGING="true"`
while testing to avoid Let's Encrypt rate limits.

DNS providers for `letsencrypt-dns`:

- **cloudflare** – `CLOUDFLARE_API_TOKEN` with permission *Zone:DNS:Edit*
- **mittwald** – `MITTWALD_API_TOKEN` and `MITTWALD_DOMAIN`; create a DNS zone
  `_acme-challenge.<SEMAPHORE_FQDN>` in mStudio beforehand

Further providers can be added as a file in
`image/target/usr/local/lib/homelab-seed/dns/<name>.sh` implementing
`dns_set_txt <fqdn> <value>` and `dns_clear_txt <fqdn>`. Pull requests are welcome.

### Firewall

With `FIREWALL_ENABLED="true"` ufw denies all incoming traffic except SSH
(optionally only from `FIREWALL_SSH_FROM`), the ports of the enabled services
and `FIREWALL_ALLOW`. Be aware that ports published by Docker containers
bypass ufw: a container you start later with `-p` is reachable regardless of
the firewall rules.

## After the installation

| What | Where |
| --- | --- |
| Setup log | `journalctl -u homelab-seed-setup` |
| Update Semaphore | `sudo homelab-seed-update semaphore [version]` |
| Update nginx | `sudo homelab-seed-update nginx [version]` |
| Add a site to the proxy | put a server block into `/etc/nginx/conf.d/`, then `docker exec nginx-proxy nginx -s reload` |
| Persistent settings | `/etc/homelab-seed/runtime.env` |

Containers: `semaphore` and `nginx-proxy`, attached to the Docker network
`DOCKER_NETWORK`. Semaphore stores its data in the Docker volumes
`semaphore_data`, `semaphore_config` and `semaphore_tmp`.

## Security notes

- **The image contains your secrets** (passwords, API tokens, keys). Treat the
  image file and the USB stick like a password: don't share them and wipe the
  stick when you no longer need it.
- On the installed system the configuration is deleted at the end of the
  setup. What remains is what the services need to run: the Semaphore
  environment and the DNS credentials for renewals (`/etc/homelab-seed`, root
  only).
- Never commit `config.env` or `secrets/` – both are git-ignored.

## Building in GitHub Actions

You don't need Docker locally at all if GitHub builds the image for you. There
are two ways; both need a **private** repository, because the image contains
your secrets and workflow artifacts of public repositories are downloadable by
anyone.

### Option A: a private copy of this repository

1. Create a private copy: on GitHub, *New repository* → *Import a repository*
   with this repository's URL, and set it to private. (Forks of public
   repositories cannot be private.)
2. Store your configuration as repository secrets (*Settings → Secrets and
   variables → Actions*), in one of two ways:

   **Individual secrets – no Docker needed on your computer.** Edit a copy of
   `config.example.env` in any text editor and paste the contents:

   | Secret | Content |
   | --- | --- |
   | `SEED_CONFIG` | your `config.env` (file settings in it are set automatically) |
   | `SEED_AUTHORIZED_KEYS` | your SSH public key(s) |
   | `SEED_SSH_PRIVATE_KEY` | optional: private key for the Semaphore bootstrap |
   | `SEED_SECRETS_ENV` | optional: `KEY=VALUE` lines for the Semaphore environment |

   Hooks contain no secrets: commit them to `hooks/*.sh` in your copy.

   **One bundle – if you have Docker locally.** Validates everything before
   you upload it:

   ```bash
   ./build.sh --bundle          # Windows: .\build.ps1 -Bundle
   gh secret set SEED_CONFIG_BUNDLE < out/config.bundle.b64
   ```

   Delete `out/config.bundle.b64` afterwards – it contains your secrets in
   plain text. If `SEED_CONFIG_BUNDLE` is set, the individual secrets are ignored.
3. Run *Actions → Build image → Run workflow*. Choose where the image goes:
   - **artifact**: download it from the workflow run (kept 3 days). Note that
     artifacts count towards your GitHub storage quota.
   - **webdav**: upload to a WebDAV folder such as Nextcloud; set the secrets
     `SEED_WEBDAV_URL`, `SEED_WEBDAV_USER` and `SEED_WEBDAV_PASSWORD`.

To change the configuration, update the secrets. To get updates of
homelab-seed, pull them from this repository into your copy:

```bash
git remote add upstream https://github.com/chris199512/homelab-seed.git
git pull upstream main && git push
```

### Option B: the action in your own workflow

If you already keep your homelab configuration in a private repository, use
homelab-seed as an action. The action needs a Linux runner; on GitHub-hosted
runners it frees disk space first.

```yaml
jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Provide config.env and the files it references, e.g. decrypt them from
      # your repository or unpack a bundle from a secret:
      - run: |
          mkdir -p "$RUNNER_TEMP/seed"
          base64 -d <<<"$BUNDLE" | tar -xz -C "$RUNNER_TEMP/seed"
        env:
          BUNDLE: ${{ secrets.SEED_CONFIG_BUNDLE }}

      - id: seed
        uses: chris199512/homelab-seed@main   # pin a release tag once available
        with:
          config: ${{ runner.temp }}/seed/config.env
          output: ${{ runner.temp }}/out
          compress: "true"

      - uses: actions/upload-artifact@v4
        with:
          name: image
          path: ${{ steps.seed.outputs.image }}
```

| Input | Default | |
| --- | --- | --- |
| `config` | `config.env` | path to `config.env` (plain or from an unpacked bundle) |
| `output` | `out` | output directory |
| `compress` | `true` | compress with xz |
| `free-disk-space` | `true` | remove unused software on GitHub-hosted runners (the build needs ~25 GB) |

Outputs: `image` and `checksum` (paths of the files).

### Locally with a config from another directory

```bash
./build.sh --config ../my-homelab/seed/config.env --xz
```

## Troubleshooting

**The installer says the target already contains a system.** It does not
reinstall an existing homelab-seed system. Rebuild with
`INSTALLER_IF_INSTALLED="overwrite"` or wipe the SD card.

**The setup stops at "Waiting for internet access".** The Pi needs Ethernet
with DHCP and internet access. The setup waits 10 minutes per attempt and
retries automatically.

**A step failed.** `journalctl -u homelab-seed-setup` shows the error. Fix the
cause and run `sudo systemctl restart homelab-seed-setup`. Completed steps are
skipped (`/var/lib/homelab-seed/steps`).

**Build fails with "Windows line endings".** Clone the repository again with
`git clone -c core.autocrlf=false …`, or download it as ZIP. Your own
`config.env`, keys and hooks may have Windows line endings – they are converted.

**"must point inside the directory of the config file".** The build container
only sees the folder that contains `config.env`. Put keys, secrets and hooks
there (subfolders are fine) and reference them with relative paths.

**Docker Desktop: "drive is not shared" or empty mounts.** Move the repository
and your config to a local drive; network drives are not supported.

**Freeing disk space.** Downloaded base images and the scratch space live in
the Docker volumes `homelab-seed-cache` and `homelab-seed-work`:
`docker volume rm homelab-seed-cache homelab-seed-work`.

## Development

```
build.sh, build.ps1       host entry points (bash / PowerShell), start the builder container
action.yml                GitHub Action
builder/                  image build (runs as root inside Docker)
image/common/             files copied into both images
image/installer/          files for the USB installer
image/target/             files for the installed system
tests/run-tests.sh        unit tests (bash, jq – no Docker, no root)
```

Files under `image/` are copied 1:1 into the images; files starting with a
shebang become executable.

### Checks

Every push and pull request runs:

| Check | Tool |
| --- | --- |
| Secret leaks in the complete git history (also weekly) | gitleaks |
| Shell scripts | ShellCheck |
| Workflows, including their shell blocks | actionlint |
| Builder Dockerfile | hadolint |
| `build.ps1` (incl. Windows PowerShell 5.1 compatibility) | PSScriptAnalyzer, Windows PowerShell parser |
| Configuration validation, staging, bundles, proxy config, hooks, workflow logic | `tests/run-tests.sh` |

The full image build (*Actions → CI → Run workflow*) is started manually.
Dependabot keeps the actions and the builder's base image up to date.

Locally, run `bash tests/run-tests.sh` and `shellcheck --external-sources`
from the repository root. Optionally install the
[pre-commit](https://pre-commit.com) hooks (`pre-commit install`) – they stop
secrets and broken scripts before they are committed.

## License

[MIT](LICENSE)
