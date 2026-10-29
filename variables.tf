variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. GitLab has no packages for Fedora."
  }
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

variable "external_url" {
  type        = string
  description = "Address people reach GitLab by, such as \"https://gitlab.example.com\". GitLab builds its links and clone URLs from it, and bundled NGINX listens on its scheme and port."

  validation {
    condition     = can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$", var.external_url))
    error_message = "external_url must be an http or https URL such as \"https://gitlab.example.com\", optionally with a port or a path."
  }
}

variable "gitlab_version" {
  type        = string
  default     = "19.5.3"
  description = "GitLab CE release to install, such as \"19.5.3\". Raising it upgrades GitLab in place. Follow GitLab's upgrade path: stop at each required release on the way."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.gitlab_version))
    error_message = "gitlab_version must be a release number such as \"19.5.3\"."
  }
}

variable "root_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password GitLab gives root when it first sets up its database. Pass it at run time with -var or TF_VAR_root_password; it never reaches state or the plan. Changing it later doesn't change root's password."

  validation {
    condition     = length(var.root_password) >= 8 && !strcontains(var.root_password, "\n")
    error_message = "root_password must be at least 8 characters, on one line."
  }

  # GitLab refuses these when it creates root, by which time the database
  # is half set up.
  validation {
    condition     = !strcontains(lower(var.root_password), "root") && !strcontains(lower(var.root_password), "gitlab")
    error_message = "root_password can't contain \"root\" or \"gitlab\". GitLab refuses passwords with the username or its own name in them."
  }
}

variable "letsencrypt" {
  type        = bool
  default     = false
  description = "Have GitLab get and renew a Let's Encrypt certificate for an https external_url. Needs public DNS for its host name and port 80 open to the internet."
}

variable "reverse_proxy" {
  type = object({
    listen_port     = optional(number, 80)
    trusted_proxies = optional(list(string), [])
  })
  default     = null
  description = "Set it when a proxy in front ends TLS: bundled NGINX then serves plain HTTP on listen_port, and trusts X-Forwarded-For from trusted_proxies, such as { trusted_proxies = [\"10.0.0.5/32\"] }."

  validation {
    condition     = var.reverse_proxy == null || try(var.reverse_proxy.listen_port >= 1 && var.reverse_proxy.listen_port <= 65535 && floor(var.reverse_proxy.listen_port) == var.reverse_proxy.listen_port, false)
    error_message = "reverse_proxy.listen_port must be a port number from 1 to 65535."
  }

  # Puma listens on 127.0.0.1:8080, so NGINX can't have it.
  validation {
    condition     = try(var.reverse_proxy.listen_port, 80) != 8080
    error_message = "reverse_proxy.listen_port can't be 8080, which GitLab's Puma already listens on. Try 8081 or 80."
  }

  validation {
    condition     = var.reverse_proxy == null || try(alltrue([for ip in var.reverse_proxy.trusted_proxies : can(cidrhost(strcontains(ip, "/") ? ip : "${ip}/${strcontains(ip, ":") ? 128 : 32}", 0))]), false)
    error_message = "Each of reverse_proxy.trusted_proxies must be an IP address or a CIDR network, such as \"10.0.0.5\" or \"10.0.0.0/8\"."
  }
}

variable "extra_config" {
  type        = string
  default     = ""
  description = "More gitlab.rb settings, as Ruby, added at the end of the file, such as \"puma['worker_processes'] = 2\"."
}

variable "min_memory_mb" {
  type        = number
  default     = 7500
  description = "Memory, in MiB, a host needs before the circuit configures it. GitLab asks for 8 GB at the least; an 8 GB host reports a little less."

  validation {
    condition     = var.min_memory_mb >= 0
    error_message = "min_memory_mb can't be negative."
  }
}
