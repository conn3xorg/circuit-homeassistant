output "service" {
  description = "The systemd service that runs Home Assistant on each host."
  value       = "homeassistant.service"
}

output "image" {
  description = "The Home Assistant image the hosts run."
  value       = local.image
}

output "url" {
  description = "Where Home Assistant answers on each host itself, such as \"http://127.0.0.1:8123\". Point a reverse proxy here."
  value       = local.local_url
}

output "config_dir" {
  description = "Home Assistant's config directory on each host. Back it up."
  value       = local.config
}
