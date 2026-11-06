variable "port" {
  type    = number
  default = 2287
}

# Pass it at run time, such as with TF_VAR_root_password.
variable "root_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

# CI sets this to install an older GitLab first, then upgrades to the
# circuit's own pin by applying again without it.
variable "gitlab_version" {
  type    = string
  default = null
}

module "gitlab" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # Reach it through an SSH tunnel; see README.md.
  external_url   = "http://localhost:8929"
  root_password  = var.root_password
  gitlab_version = var.gitlab_version

  # Fewer workers and no bundled monitoring, so GitLab fits next to other
  # containers on a laptop.
  extra_config = <<-EOT
    puma['worker_processes'] = 2
    sidekiq['concurrency'] = 10
    prometheus_monitoring['enable'] = false
  EOT
}

output "external_url" {
  value = module.gitlab.external_url
}
