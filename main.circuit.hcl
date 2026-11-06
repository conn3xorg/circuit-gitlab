# Facts give each host's distribution, which picks GitLab's apt or yum
# repository, and its memory, which GitLab needs plenty of.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = self.os_family == "redhat" ? contains(["rocky", "almalinux", "rhel"], self.os_id) : contains(keys(local.codenames), "${self.os_id} ${self.os_version}")
      error_message = "Host ${each.key} runs ${self.os_id} ${self.os_version}. GitLab publishes Linux packages for Ubuntu 22.04, 24.04 and 26.04, Debian 13, and Rocky Linux, AlmaLinux and RHEL."
    }

    postcondition {
      condition     = self.memory_mb >= var.min_memory_mb
      error_message = "Host ${each.key} has ${self.memory_mb} MiB of memory. GitLab needs 8 GB at the least on a single node, and 16 GB is its baseline. Set min_memory_mb lower to go ahead anyway."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  # GitLab keeps one apt repository per release, named after it. Debian 12
  # stopped at GitLab 19.3.
  codenames = {
    "ubuntu 22.04" = "jammy"
    "ubuntu 24.04" = "noble"
    "ubuntu 26.04" = "resolute"
    "debian 13"    = "trixie"
  }
  codename = { for name, f in data.conn3x_host.facts : name => lookup(local.codenames, "${f.os_id} ${f.os_version}", "") }

  # apt wants the full version, dnf takes the leading part of it.
  package_version = { debian = "${var.gitlab_version}-ce.0", redhat = var.gitlab_version }

  config_file   = "/etc/gitlab/gitlab.rb"
  password_file = "/etc/gitlab/conn3x-root-password"

  url_parts = regex("^(https?)://([^/:]+)(?::([0-9]+))?", var.external_url)

  # Where the circuit itself asks GitLab whether it's ready. Bundled NGINX
  # answers on every address, whatever the Host header.
  local_scheme = var.reverse_proxy == null ? local.url_parts[0] : "http"
  local_port = var.reverse_proxy != null ? tostring(var.reverse_proxy.listen_port) : coalesce(
    local.url_parts[2], local.url_parts[0] == "https" ? "443" : "80"
  )
  readiness_url = "${local.local_scheme}://127.0.0.1:${local.local_port}/-/readiness"

  gitlab_rb = join("\n", compact([
    "# Written by Conn3x. Changes here are overwritten on the next apply.",
    "external_url '${var.external_url}'",
    "letsencrypt['enable'] = ${var.letsencrypt}",
    # TLS ends at the proxy, which talks plain HTTP to bundled NGINX. GitLab
    # still builds https links from external_url.
    var.reverse_proxy == null ? "" : <<-EOT
    nginx['listen_port'] = ${var.reverse_proxy.listen_port}
    nginx['listen_https'] = false
    nginx['real_ip_header'] = 'X-Forwarded-For'
    nginx['real_ip_recursive'] = 'on'
    nginx['real_ip_trusted_addresses'] = ${jsonencode(var.reverse_proxy.trusted_proxies)}
    gitlab_rails['trusted_proxies'] = ${jsonencode(var.reverse_proxy.trusted_proxies)}
    EOT
    ,
    var.extra_config == "" ? "" : "\n# extra_config\n${trimspace(var.extra_config)}",
  ]))
}

circuit "gitlab" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # apt checks the repository's Release file against the repository key,
  # which expires on 6 February 2028. dnf checks each package against the
  # package signing key, which expires on 16 February 2028.
  step "repo" {
    repository {
      name   = "gitlab-ce"
      url    = local.family[each.key] == "debian" ? "https://packages.gitlab.com/gitlab/gitlab-ce/${local.os[each.key]}/${local.codename[each.key]}" : "https://packages.gitlab.com/gitlab/gitlab-ce/el/$releasever/$basearch"
      key    = file("${path.module}/files/${local.family[each.key] == "debian" ? "gitlab-repo.asc" : "gitlab-packages.asc"}")
      suites = local.family[each.key] == "debian" ? [local.codename[each.key]] : null
    }
  }

  # Write-only: the plan and state record only an HMAC of the content.
  # GitLab reads it once, when the first reconfigure creates root.
  step "root_password" {
    file {
      path       = local.password_file
      content_wo = var.root_password
      mode       = "0600"
    }
  }

  # Minimal images leave these out. GitLab reads the time zone database,
  # and reconfigure names its Chef node from hostname.
  step "tools" {
    for_each = toset(["hostname", "tzdata"])
    package {
      name = item.value
    }
  }

  # Installed before gitlab.rb is written. A fresh install that finds an
  # external_url in gitlab.rb reconfigures straight away, without
  # GITLAB_ROOT_PASSWORD, and root would get a random password. With only
  # the package's own template there, it leaves the first reconfigure to the
  # step below. A new version runs gitlab-ctl upgrade, which migrates the
  # database and restarts GitLab with the gitlab.rb already in place.
  step "package" {
    package {
      name    = "gitlab-ce"
      version = local.package_version[local.family[each.key]]
    }
  }

  step "config" {
    file {
      path    = local.config_file
      content = "${local.gitlab_rb}\n"
      mode    = "0600"
    }
  }

  # Handler-like: runs on the first apply and whenever gitlab.rb changes, and
  # not otherwise, since a reconfigure takes minutes. GITLAB_ROOT_PASSWORD
  # only counts on the run that creates the database.
  step "reconfigure" {
    command {
      command = "GITLAB_ROOT_PASSWORD=\"$(cat ${local.password_file})\" gitlab-ctl reconfigure"
      triggers = {
        config = conn3x_file.gitlab__config[each.key].revision
      }
    }
  }

  # Puma takes a minute or two to come up after a reconfigure, and after
  # the restart a new package version's upgrade does. unless is checked at
  # plan time, before either, so their revisions make the apply check again.
  step "ready" {
    command {
      command = "for _ in $(seq 300); do /opt/gitlab/embedded/bin/curl -sfk -o /dev/null ${local.readiness_url} && exit 0; sleep 2; done; echo 'GitLab did not answer on ${local.readiness_url} in 10 minutes. See gitlab-ctl status and gitlab-ctl tail.' >&2; exit 1"
      unless  = "/opt/gitlab/embedded/bin/curl -sfk -o /dev/null ${local.readiness_url}"
      triggers = {
        package     = conn3x_package.gitlab__package[each.key].revision
        reconfigure = conn3x_command.gitlab__reconfigure[each.key].revision
      }
    }
  }
}
