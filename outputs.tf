output "config_file" {
  description = "Path of the gitlab.rb the circuit writes on each host."
  value       = local.config_file
}

output "external_url" {
  description = "Address GitLab builds its links from."
  value       = var.external_url
}
