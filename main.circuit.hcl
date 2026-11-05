locals {
  image  = "${var.image_repository}:${var.homeassistant_version}@${var.image_digest}"
  parent = "/var/lib/homeassistant"
  config = "${local.parent}/config"
  store  = "${local.config}/.storage/http"

  # Since 2026.8, Home Assistant keeps its HTTP server settings in
  # .storage/http and changes them from its UI. The one way in from outside
  # is the http: block it imports from configuration.yaml on its first start,
  # so the seed step gives that block to a throwaway first start and keeps
  # only the settings it wrote.
  # JSON is YAML too, and fits on the one line a printf needs.
  http_yaml = jsonencode({
    http = merge(
      {
        server_host = var.listen_addresses
        server_port = var.port
      },
      [for p in [var.trusted_proxies] : {
        use_x_forwarded_for = true
        trusted_proxies     = p
      } if length(p) > 0]...
    )
  })

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_addresses[0], strcontains(var.listen_addresses[0], ":") ? "[${var.listen_addresses[0]}]" : var.listen_addresses[0])
  local_url  = "http://${local.local_host}:${var.port}"
}

circuit "homeassistant" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # circuit-podman installs it too, but the seed below needs it first.
  step "podman" {
    package {
      name = "podman"
    }
  }

  # The config holds every token and password Home Assistant stores, so it
  # sits in a parent only root can enter.
  step "parent" {
    directory {
      path  = local.parent
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  step "config" {
    directory {
      path  = local.config
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  # Runs once, before Home Assistant's first real start. The image starts in
  # an empty directory with only the http: block, imports it as it would on
  # an upgrade, and stops once .storage/http is written. Only that file moves
  # into the real config, so the first real start finds its HTTP settings
  # already in place and no http: block to warn about. From then on Home
  # Assistant owns the file, and creates keeps this step from touching it.
  step "seed" {
    command {
      command = <<-EOT
        set -eu
        seed=$(mktemp -d ${local.parent}/seed.XXXXXX)
        trap 'podman rm -f -t 5 homeassistant-seed >/dev/null 2>&1 || true; rm -rf "$seed"' EXIT
        printf '%s\n' '${local.http_yaml}' > "$seed/configuration.yaml"
        podman run -d --name homeassistant-seed --network host -v "$seed:/config:Z" ${local.image} >/dev/null
        for _ in $(seq 600); do
          [ -s "$seed/.storage/http" ] && break
          podman container exists homeassistant-seed || break
          sleep 1
        done
        sleep 2
        if [ ! -s "$seed/.storage/http" ] || ! grep -q '"yaml_migration_done": true' "$seed/.storage/http"; then
          podman logs --tail 30 homeassistant-seed >&2 || true
          echo "Home Assistant didn't write its HTTP settings in 10 minutes." >&2
          exit 1
        fi
        # The import stages the settings as a trial, which Home Assistant
        # undoes after 5 minutes unless someone confirms it in the UI. These
        # are the settings asked for, so they become the confirmed ones.
        podman rm -f -t 5 homeassistant-seed >/dev/null
        podman run --rm --network none --entrypoint python3 -v "$seed:/config:Z" ${local.image} -c '
        import json
        p = "/config/.storage/http"
        d = json.load(open(p))
        x = d["data"]
        if x["pending"] is not None:
            assert x["pending"]["error"] is None, x["pending"]
            x["stable"], x["pending"] = x["pending"], None
        json.dump(d, open(p, "w"), indent=2)
        '
        mkdir -p -m 0700 ${local.config}/.storage
        mv "$seed/.storage/http" ${local.store}
      EOT
      creates = local.store
    }
  }
}

# Home Assistant runs from its official image as a Quadlet unit, on the
# host's network. Discovery needs that: mDNS, SSDP and DHCP watching only
# see the LAN from the host's own interfaces, and many integrations find
# devices by broadcast.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.1"

  depends_on = [conn3x_command.homeassistant__seed]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    homeassistant = {
      image   = local.image
      volumes = ["${local.config}:/config:Z"]
      extra   = concat(["Network=host"], [for d in var.devices : "AddDevice=${d}"])
    }
  }
}

circuit "ready" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # A new image or device list restarts Home Assistant, and wait_for alone
  # wouldn't wait again once its port had answered. The host may have no
  # tool to try a port with, so Python in the container does it.
  step "started" {
    depends_on = [module.podman]
    command {
      command  = "for _ in $(seq 900); do podman exec homeassistant python3 -c 'import socket; socket.create_connection((\"${trim(local.local_host, "[]")}\", ${var.port}), 2)' 2>/dev/null && exit 0; sleep 1; done; echo \"Home Assistant didn't open port ${var.port} in 15 minutes. See journalctl -u homeassistant.\" >&2; exit 1"
      triggers = { image = local.image, devices = join(" ", var.devices) }
    }
  }

  # A first start pulls the image and sets up its database before it
  # listens.
  step "port" {
    wait_for {
      port    = var.port
      timeout = "15m"
    }
  }
}
