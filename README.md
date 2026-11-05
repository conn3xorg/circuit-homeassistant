# circuit-homeassistant

[![Conn3x grade](https://conn3x.org/circuits/homeassistant/grade.svg)](https://conn3x.org/circuits/homeassistant/grade)

A Conn3x circuit that runs [Home Assistant](https://www.home-assistant.io) on your own hosts, the Container way: the official image under Podman, as a systemd service. Your automations, your device history and the tokens for every integration stay on a machine you run.

The image is pinned by tag and digest, and the container uses the host's network so Home Assistant can discover devices on your LAN. The web server listens on `127.0.0.1:8123` to start with, for a reverse proxy in front, until you say otherwise. The config lives in `/var/lib/homeassistant/config`, in a parent only root can enter. It runs on Debian, Ubuntu, Fedora and Rocky Linux.

This is Home Assistant Container, not Home Assistant OS or Supervised: there are no add-ons and no Supervisor. Anything you'd run as an add-on, such as Mosquitto or Zigbee2MQTT, runs as its own service beside it.

## Usage

```hcl
module "homeassistant" {
  source = "github.com/conn3xorg/circuit-homeassistant?ref=v0.1.0"

  hosts                = { home = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  listen_addresses = ["192.168.1.50"]
  devices          = ["/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus-if00-port0"]
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

Open `http://192.168.1.50:8123` straight away and finish onboarding. Until you do, the first person to open that page creates the owner account. The default `listen_addresses` keeps the page on the host itself, which gives you time: reach it over SSH with `ssh -L 8123:127.0.0.1:8123 root@192.168.1.50`, then open `http://localhost:8123`.

To try it on a throwaway container first, see [examples/local](examples/local).

### Behind a reverse proxy

Home Assistant speaks plain HTTP. With a proxy such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) on the same host, keep the default listen address and tell Home Assistant to trust the proxy:

```hcl
module "homeassistant" {
  source = "github.com/conn3xorg/circuit-homeassistant?ref=v0.1.0"

  hosts                = { home = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  trusted_proxies = ["127.0.0.1"]
}

module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.3.0"

  hosts                = { home = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  sites = {
    "home.example.com" = { reverse_proxy = ["127.0.0.1:8123"] }
  }
}
```

Without `trusted_proxies`, Home Assistant answers every forwarded request with `400 Bad Request`. That's on purpose: it won't take a client's address from a header it can't vouch for.

## Why the host's network

Home Assistant finds a lot of what's on your LAN by listening for it. Chromecasts and HomeKit devices announce themselves over mDNS, Hue bridges and Sonos speakers over SSDP, and some integrations watch for DHCP requests to spot new devices. All of that is multicast or broadcast on the LAN, and a container on Podman's bridge network sees none of it. So the container shares the host's network, as Home Assistant's own Container instructions say to.

What that costs:

- **The ports are the host's.** Home Assistant's web server, and anything an integration opens, such as the HomeKit Bridge, listen on the host's interfaces directly, with no `-p` mapping to narrow them. A firewall on the host still applies.
- **The container isn't walled off from the network.** It can reach anything on the host's loopback, such as a database that listens only on `127.0.0.1`. The circuit doesn't run it privileged, and it only gets the devices you list.
- **The web server listens where it's told.** Home Assistant listens on every address unless told otherwise, and the circuit tells it `listen_addresses` before it first starts, so the default is `127.0.0.1` only. Discovery doesn't need the web server on the LAN; it listens for multicast on its own sockets either way.

If you'd rather give up discovery, and add each device by its address instead, this circuit isn't the right fit. Ask in the [Discussions](https://github.com/conn3xorg/conn3x/discussions) and say what you'd need.

## How the HTTP settings get there

Since 2026.8, Home Assistant keeps its web server's settings (listen addresses, port, trusted proxies) in `.storage/http` and you change them under **Settings > System > Network**. A `http:` block in `configuration.yaml` is read once, imported, and then ignored with a repair notice asking you to remove it. That's also the only way to set them from outside before the first start.

So on a host's first apply, before Home Assistant has ever run there, the circuit:

1. Starts the image once in an empty directory, under `/var/lib/homeassistant`, holding only an `http:` block built from `listen_addresses`, `port` and `trusted_proxies`.
2. Waits for Home Assistant to import the block and write `.storage/http`, then stops it.
3. Marks the imported settings as confirmed. An import is staged as a trial, which Home Assistant undoes after five minutes unless someone confirms it in the UI, and that would put the web server back on every address.
4. Moves `.storage/http` alone into the real config, and removes the rest.

The real first start then finds its HTTP settings in place and no `http:` block to warn about. The imported values go through Home Assistant's own checks, so an address it can't use stops the apply rather than a running instance.

From then on, Home Assistant owns that file. **Changing `listen_addresses`, `port` or `trusted_proxies` after the first apply does nothing**: change them in the UI. If you move an existing config into `/var/lib/homeassistant/config` before the first apply, its own `.storage/http` is kept and the seed doesn't run.

## What it does

On each host, in order:

1. Installs Podman.
2. Creates `/var/lib/homeassistant`, mode `0700`, and `/var/lib/homeassistant/config` inside it, both owned by root.
3. If `/var/lib/homeassistant/config/.storage/http` doesn't exist, seeds it as described above.
4. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.1, runs `ghcr.io/home-assistant/home-assistant:VERSION@DIGEST` as `homeassistant.service`: a Quadlet unit on the host network, with the config mounted at `/config` and each of `devices` passed in.
5. Waits up to 15 minutes for the web server's port, after a first start and after any change that restarts Home Assistant. On a first start it pulls the image and sets up its database first.

Home Assistant writes its own `configuration.yaml` on the first start, and the circuit never touches it, so edit it as you would on any Home Assistant install. A change to the image or the devices restarts Home Assistant.

### Devices

A Zigbee or Z-Wave stick, or any serial device, goes in `devices`. Use the stable name under `/dev/serial/by-id/` rather than `/dev/ttyACM0`, since the numbered names can swap when two sticks are plugged in. The device is passed in at the same path, so that's also the path to give the integration.

Bluetooth needs D-Bus from the host as well, and the circuit doesn't set that up.

### Upgrades

Change `homeassistant_version` and `image_digest` together. `conn3x plan` shows the new image in the unit, and the apply restarts Home Assistant on it, which migrates its database as it starts. Read the release notes' "Backward-incompatible changes" first; Home Assistant releases monthly and each one has some. CI upgrades from 2026.10.4 to the default on every distro.

### What it doesn't do

- It doesn't finish onboarding or create the owner. Do that yourself, before the web server is on the LAN.
- It doesn't set up TLS or a reverse proxy, and it doesn't open a port in a firewall.
- It doesn't back anything up. Back up `/var/lib/homeassistant/config`, or use Home Assistant's own backups under **Settings > System > Backups** and copy them off the host (see [circuit-restic](https://github.com/conn3xorg/circuit-restic)).
- It doesn't run add-ons, the Supervisor or Home Assistant OS.
- Deleting the module leaves Podman, the container and `/var/lib/homeassistant` in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.50"`, or a host object such as `{ address = "192.168.1.50", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `listen_addresses` | list(string) | `["127.0.0.1"]` | Addresses the web server listens on, such as `["192.168.1.50"]`, or `["0.0.0.0"]` for every address. First start only. |
| `port` | number | `8123` | Port the web server listens on. First start only. |
| `trusted_proxies` | list(string) | `[]` | Reverse proxies allowed to set `X-Forwarded-For`, such as `["127.0.0.1"]` or `["192.168.1.0/24"]`. Turns on Home Assistant's "Trust X-Forwarded-For". A network must be given by its network address. First start only. |
| `devices` | list(string) | `[]` | Host devices to pass in, such as `["/dev/serial/by-id/usb-..."]`. |
| `homeassistant_version` | string | `"2026.11.0"` | Tag of Home Assistant's image. Change `image_digest` with it. |
| `image_digest` | string | `"sha256:c6c1ca99..."` | Digest of the image for `homeassistant_version`. Podman pulls by the digest. Find it on the [package page](https://github.com/home-assistant/core/pkgs/container/home-assistant) or with `skopeo inspect docker://ghcr.io/home-assistant/home-assistant:TAG`. |
| `image_repository` | string | `"ghcr.io/home-assistant/home-assistant"` | Where to pull the image from. `"docker.io/homeassistant/home-assistant"` serves the same digests from Docker Hub. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | The systemd service that runs Home Assistant, `homeassistant.service`. |
| `image` | The image the hosts run, with its tag and digest. |
| `url` | Where Home Assistant answers on the host itself, such as `http://127.0.0.1:8123`, from the first of `listen_addresses`. Point a reverse proxy here. |
| `config_dir` | `/var/lib/homeassistant/config`, the directory to back up. |

## Requirements

Requires Conn3x v0.7.0 or later and systemd on each host. The image is built for amd64 and arm64. Each host needs to reach its package mirror and GitHub's registry. `conn3x init` fetches circuit-podman from GitHub.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, first with Home Assistant 2026.10.4 and then upgrading to the default, and checks the next plan has no changes. [check.sh](examples/local/check.sh) then finishes onboarding through `/api/onboarding/users`, checks a second owner is refused, signs in as the owner through the login flow, checks a wrong password is refused, reads `/api/config` with the token and checks the version, and checks port 8123 doesn't answer on the host's own address. CI restarts the host, runs the same checks again, and plans clean once more.

The same runs passed by hand on arm64 in rootful Podman on a Mac. By hand on DigitalOcean droplets with 4 GB of memory, Ubuntu 24.04 and Rocky Linux 10 with SELinux enforcing: the apply, the clean plan and check.sh passed, port 8123 didn't answer on the public address, and after a reboot Home Assistant came back on its own, the owner signed in again and the plan was clean. The Rocky audit log had no denials. Bluetooth and USB devices haven't been tried.

## License

MPL-2.0. See [LICENSE](LICENSE).

Home Assistant itself is under the Apache License 2.0.
