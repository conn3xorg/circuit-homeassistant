variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "homeassistant_version" {
  type        = string
  nullable    = false
  default     = "2026.11.0"
  description = "Tag of the Home Assistant image, such as \"2026.11.0\". Change image_digest with it."

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.homeassistant_version))
    error_message = "homeassistant_version must be an image tag, such as \"2026.11.0\"."
  }
}

variable "image_digest" {
  type        = string
  nullable    = false
  default     = "sha256:c6c1ca9931036bf3a2c4cc088d8db25dfea3b33935a5ecc83c40349462e2f69e"
  description = "Digest of the image for homeassistant_version, such as \"sha256:c6c1...\". Podman pulls by the digest, so a tag that moves upstream can't change what runs."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "image_repository" {
  type        = string
  default     = "ghcr.io/home-assistant/home-assistant"
  description = "Where to pull Home Assistant's image from. \"docker.io/homeassistant/home-assistant\" serves the same image from Docker Hub."

  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", var.image_repository))
    error_message = "image_repository must be a registry and path without a tag, such as \"ghcr.io/home-assistant/home-assistant\"."
  }
}

variable "listen_addresses" {
  type        = list(string)
  default     = ["127.0.0.1"]
  description = "Addresses Home Assistant's web server listens on, set at its first start. The default keeps it on the host for a reverse proxy in front; add the host's LAN address, or use [\"0.0.0.0\"], for phones and browsers to reach it directly."

  validation {
    condition     = length(var.listen_addresses) > 0 && alltrue([for a in var.listen_addresses : can(cidrhost("${a}/${strcontains(a, ":") ? 128 : 32}", 0))])
    error_message = "listen_addresses must be one or more IPv4 or IPv6 addresses, such as [\"127.0.0.1\"]."
  }
}

variable "port" {
  type        = number
  default     = 8123
  description = "Port Home Assistant's web server listens on, set at its first start."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1 to 65535."
  }
}

variable "trusted_proxies" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Reverse proxies allowed to set X-Forwarded-For, as addresses or networks, such as [\"127.0.0.1\"] for a proxy on the same host. Home Assistant refuses forwarded requests from any proxy not listed. Set at its first start."

  validation {
    condition     = alltrue([for p in var.trusted_proxies : can(cidrhost(strcontains(p, "/") ? p : "${p}/${strcontains(p, ":") ? 128 : 32}", 0)) && (!strcontains(p, "/") || cidrhost(p, 0) == split("/", p)[0])])
    error_message = "trusted_proxies must be addresses or network addresses, such as \"127.0.0.1\" or \"192.168.1.0/24\" (not \"192.168.1.50/24\")."
  }
}

variable "devices" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Host devices to pass into the container, such as [\"/dev/ttyACM0\"] for a Zigbee or Z-Wave stick. Prefer the stable names under /dev/serial/by-id."

  validation {
    condition     = alltrue([for d in var.devices : can(regex("^/dev/[A-Za-z0-9/_.:+-]+$", d))])
    error_message = "Each of devices must be a path under /dev, such as \"/dev/ttyACM0\"."
  }
}
