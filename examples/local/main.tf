variable "port" {
  type    = number
  default = 2222
}

# CI sets these to apply an older release first, then upgrade.
variable "homeassistant_version" {
  type    = string
  default = null
}

variable "image_digest" {
  type    = string
  default = null
}

module "homeassistant" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  homeassistant_version = var.homeassistant_version
  image_digest          = var.image_digest
}
