# circuit-gitlab

[![Conn3x grade](https://conn3x.org/circuits/gitlab/grade.svg)](https://conn3x.org/circuits/gitlab/grade)

A Conn3x circuit that runs [GitLab Community Edition](https://about.gitlab.com/install/) on one host of your own, from GitLab's official Linux packages. You say where people reach it, which release you want and what root's first password is; the circuit adds GitLab's repository, writes `gitlab.rb`, installs the package and runs `gitlab-ctl reconfigure` for you. After that, reconfigure runs again only when `gitlab.rb` changes, so a plan with nothing to do stays quiet and an apply with nothing to do takes seconds, not the minutes a reconfigure costs.

The release is pinned in your code. GitLab moves when you raise `gitlab_version`, on your schedule, one stop at a time along its [upgrade path](#upgrades), and not because a new package landed in the repository overnight.

This is the single-node install. For GitLab's multi-node reference architectures, with separate Gitaly, PostgreSQL, Redis and Sidekiq nodes behind a load balancer, use the [GitLab Environment Toolkit](https://gitlab.com/gitlab-org/gitlab-environment-toolkit), which GitLab builds and supports for exactly that. This circuit borrows its approach of writing `gitlab.rb` from code, and stops at one box.

## Usage

```hcl
variable "gitlab_root_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "gitlab" {
  source = "github.com/conn3xorg/circuit-gitlab?ref=v0.1.2"

  hosts                = { git1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  external_url   = "https://gitlab.example.com"
  gitlab_version = "19.5.3"
  root_password  = var.gitlab_root_password
  letsencrypt    = true

  extra_config = <<-EOT
    gitlab_rails['time_zone'] = 'Europe/Dublin'
    gitlab_rails['gitlab_email_from'] = 'gitlab@example.com'
  EOT
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_gitlab_root_password`. The first apply downloads a package of about 1.5 GB and runs GitLab's first reconfigure, which together take 5 to 15 minutes depending on the host. The apply waits until GitLab says it's ready. A second `conn3x plan` says `No changes.` Then sign in at your `external_url` as `root`.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its repository by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  git1 = {
    address  = digitalocean_droplet.git.ipv4_address
    host_key = tls_private_key.host.public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### The root password

`root_password` is ephemeral and sensitive, so it never lands in the plan or the state. The circuit writes it to `/etc/gitlab/conn3x-root-password`, mode `0600`, owned by root, with the file's write-only content: state keeps only an HMAC of it. The first reconfigure reads it into `GITLAB_ROOT_PASSWORD`, the variable [GitLab's install docs](https://docs.gitlab.com/install/package/ubuntu/) give for setting root's password, and GitLab creates `root` with it.

That is the only time GitLab looks at it. Change root's password in GitLab afterwards, as you would with any account. Changing `root_password` later rewrites the file and nothing else; it doesn't change root's password, and it doesn't reconfigure.

The file stays on the host, because a file that disappeared after the first apply would show up in every plan after it. Only root can read it, in the same directory as `gitlab-secrets.json`, which holds more than a password. GitLab asks for at least 8 characters, and turns down passwords with `root` or `gitlab` in them, or ones on its list of common passwords, with `Password must not contain commonly used combinations of words and letters`. By then the first reconfigure has half set up the database, so the circuit refuses `root` and `gitlab` at plan time. It can't check GitLab's list; pick something long and unusual.

### Behind a reverse proxy

By default, GitLab's bundled NGINX serves `external_url` itself, on its port, and with `https` it wants a certificate: either `letsencrypt = true`, or your own in `/etc/gitlab/ssl/HOSTNAME.crt` and `.key` before the first apply.

When a proxy or load balancer in front ends TLS instead, set `reverse_proxy`:

```hcl
external_url  = "https://gitlab.example.com"
reverse_proxy = { listen_port = 8081, trusted_proxies = ["10.0.0.5"] }
```

Bundled NGINX then serves plain HTTP on `listen_port` (default 80), and GitLab still builds `https` links from `external_url`. `trusted_proxies` are the addresses GitLab and NGINX take `X-Forwarded-For` from, so logs and rate limits see the real client rather than the proxy. This follows GitLab's [SSL termination](https://docs.gitlab.com/omnibus/settings/ssl/#configure-a-reverse-proxy-or-load-balancer-ssl-termination) setup. Point the proxy at `http://HOST:listen_port`. Any port but 8080, which belongs to GitLab's own Puma on `127.0.0.1`.

### Memory

GitLab is big. Its [requirements](https://docs.gitlab.com/install/requirements/) give 8 vCPU and 16 GB of memory as the single-node baseline, and say it can run in 8 GB in a memory-constrained setup.

So the circuit checks each host's memory, from the `conn3x_host` facts, before it changes anything, and stops with an error on a host with less than `min_memory_mb`, 7500 MiB by default, which an 8 GB host clears. Lower it if you know what you're doing; GitLab's guide to [running in a memory-constrained environment](https://docs.gitlab.com/omnibus/settings/memory_constrained_envs/) has the settings to put in `extra_config`, like the ones in the example:

```ruby
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
prometheus_monitoring['enable'] = false
```

### Upgrades

GitLab can't jump straight from any release to any later one. Database migrations have to run in order, so GitLab names [required upgrade stops](https://docs.gitlab.com/update/upgrade_paths/): at the time of writing 18.2, 18.5, 18.8 and 18.11 in GitLab 18, and 19.2, 19.5, 19.8 and 19.11 in GitLab 19. To go from 18.4 to 19.5, for example, you'd go to 18.5, then 18.8, 18.11, 19.2 and 19.5, each at its latest patch release, and let the background migrations finish (**Admin > Monitoring > Background migrations**) before the next step. GitLab's [upgrade path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/) works out the list for you.

With this circuit, each stop is one apply: set `gitlab_version` to the stop, apply, wait for the migrations, then the next. The package's own upgrade script runs the migrations and restarts GitLab. Patch releases within one minor release need no stops. Change `gitlab_version` in an apply of its own: the upgrade runs with the `gitlab.rb` already on the host, and a settings change in the same apply only reaches GitLab in a second reconfigure afterwards.

Take a backup first: `gitlab-backup create`, and copy `/etc/gitlab/gitlab-secrets.json` and `gitlab.rb` somewhere safe, since the backup leaves them out.

## What it does

On each host, in order:

1. Reads the host's facts, and stops if the distribution has no GitLab packages, or the host has less memory than `min_memory_mb`.
2. Adds GitLab's CE repository at `packages.gitlab.com`, the same one GitLab's install script sets up: `gitlab/gitlab-ce/ubuntu/noble` or `debian/trixie` with that suite on Debian and Ubuntu, and `gitlab/gitlab-ce/el/$releasever/$basearch` on Rocky Linux, AlmaLinux and RHEL. The keys are pinned in `files/`: apt checks the repository against `F6403F6544A38863DAA0B6E03F01618A51312F3F` in `gitlab-repo.asc`, which expires on 6 February 2028, and dnf checks each package against `98BFDB87FCF10076416C1E0BAD997ACC82DD593D` in `gitlab-packages.asc`, which expires on 16 February 2028.
3. Writes `root_password` to `/etc/gitlab/conn3x-root-password`, and installs `tzdata` and `hostname`, which GitLab needs and minimal images leave out.
4. Installs `gitlab-ce` at `gitlab_version`, then writes `/etc/gitlab/gitlab.rb`, mode `0600`: `external_url`, `letsencrypt['enable']`, the NGINX and trusted proxy settings when `reverse_proxy` is set, and `extra_config` at the end. The package goes first on purpose: a fresh install that already finds an `external_url` in `gitlab.rb` reconfigures on the spot, without the root password, and GitLab would make one up. A new version upgrades GitLab in place: the package runs `gitlab-ctl upgrade`, which migrates the database and restarts it.
5. Runs `gitlab-ctl reconfigure` on the first apply and whenever `gitlab.rb` changed, and not otherwise.
6. Waits, up to 10 minutes, for `/-/readiness` to answer on the host itself, after a reconfigure or a new package version.

After a reboot GitLab takes a minute or two to come back. A plan in that window shows the wait step again, and an apply just waits for GitLab; once it's up, the plan is clean.

`gitlab.rb` belongs to the circuit: changes made to it by hand go on the next apply. Put your settings in `extra_config`, as Ruby, the way GitLab's [configuration docs](https://docs.gitlab.com/omnibus/settings/configuration/) write them. It's added at the end of the file, so a setting there wins over one the circuit wrote above it.

### What it doesn't do

- It doesn't do multi-node or high-availability GitLab. That's the [GitLab Environment Toolkit](https://gitlab.com/gitlab-org/gitlab-environment-toolkit)'s job.
- It doesn't install GitLab Enterprise Edition, or Runners. Runners belong on other machines; GitLab's [runner docs](https://docs.gitlab.com/runner/install/) cover them.
- It doesn't take backups, or set up email, LDAP or SSO. Add mail and sign-in settings to `extra_config`.
- It doesn't open firewall ports. Use [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for 80, 443 and 22.
- It doesn't move SSH for Git. GitLab serves Git over the host's own sshd on port 22, so think about where your admin SSH lives.
- It doesn't walk the upgrade path for you. Each stop is its own apply.
- It doesn't hold the package. A plain `apt upgrade` or `dnf upgrade` would still move GitLab to the newest release, past any upgrade stop, and the next plan would show it. Leave `gitlab-ce` out of unattended upgrades.
- Deleting the module leaves GitLab installed and running, with its data in `/var/opt/gitlab`.

## Supported distributions

The circuit installs only where GitLab [publishes packages](https://docs.gitlab.com/install/package/): Ubuntu 22.04, 24.04 and 26.04, Debian 13, and Rocky Linux, AlmaLinux and RHEL. GitLab lists AlmaLinux and RHEL 8, 9 and 10 on that page rather than Rocky Linux, and its `el` packages are the same for all three; the circuit uses them on Rocky Linux 10, which is what was tested.

Fedora isn't supported: GitLab doesn't publish packages for it. Debian 12 stopped at GitLab 19.3, so the default release isn't available there.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan or behind `depends_on` needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `external_url` | string | Required | Address people reach GitLab by, such as `"https://gitlab.example.com"`. GitLab builds its links and clone URLs from it. |
| `root_password` | string | Required | Password GitLab gives `root` when it first creates its database. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters, on one line. See [The root password](#the-root-password). |
| `gitlab_version` | string | `"19.5.3"` | GitLab CE release to install. Raising it upgrades GitLab; see [Upgrades](#upgrades). |
| `letsencrypt` | bool | `false` | Have GitLab get and renew a Let's Encrypt certificate. Needs an `https` `external_url`, public DNS for it, and port 80 open to the internet. |
| `reverse_proxy` | object | `null` | Set it when a proxy in front ends TLS: `{ listen_port = 8081, trusted_proxies = ["10.0.0.5"] }`. `listen_port` defaults to 80 and can't be 8080; `trusted_proxies` defaults to `[]`. See [Behind a reverse proxy](#behind-a-reverse-proxy). |
| `extra_config` | string | `""` | More `gitlab.rb` settings, as Ruby, added at the end of the file. |
| `min_memory_mb` | number | `7500` | Memory, in MiB, a host needs before the circuit configures it. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the file the circuit writes on each host, `/etc/gitlab/gitlab.rb`. |
| `external_url` | Address GitLab builds its links from. |

## Requirements

Requires Conn3x v0.6.9 or later, systemd on each host, and outbound HTTPS to `packages.gitlab.com` and your distribution's mirrors. Each host needs 8 GB of memory or more (see [Memory](#memory)) and GitLab asks for 40 GB of disk. GitLab publishes amd64 and arm64 packages; both were tested, as below.

When the keys in `files/` near their expiry in February 2028, GitLab will publish new ones at `https://packages.gitlab.com/gpgkey/`. A release of this circuit with the new keys then replaces them on the next apply.

## Tested on

Ubuntu 24.04, Debian 13 and Rocky Linux 10, with GitLab CE 19.5.3. CI applies [examples/local](examples/local) to each in a container on amd64 and checks that the second plan has no changes and that the password isn't in the state. Then it checks that `/-/readiness` says `ok`, that `root` can sign in through the web form with the password from the plan and use that session on `/api/v4/user`, and that a wrong password can't. On a fresh container it also installs GitLab 19.5.1, then applies the circuit's own pin over it, and checks the second plan is empty, 19.5.3 is running and the sign-in checks still pass. GitLab 19 no longer offers the OAuth password grant (`/oauth/token` answers `unsupported_grant_type`), so the sign-in form is the check.

Before tagging, the same checks passed by hand in arm64 containers of all three on Apple silicon. On Ubuntu 24.04 a change to `extra_config` ran reconfigure once and reached GitLab, and reverting it did the same, each followed by a clean plan; restarting the container gave a clean plan too.

On 8 GB DigitalOcean droplets (amd64) of all three, with SELinux enforcing on Rocky Linux 10, the first apply took 9 to 12 minutes, the second plan had no changes and the sign-in checks passed. Rocky Linux ran behind `reverse_proxy` with an `https` `external_url`, first on `listen_port = 8080`, where NGINX clashed with Puma and GitLab never got ready, which is why the circuit now refuses 8080, then on 8081, where it came up; Ubuntu and Debian served `http` on port 80. After a reboot of each, GitLab came back by itself within three minutes, the plan had no changes and the checks passed again. The droplets ran the circuit as it was just before `hostname` joined `tzdata` in the packages it installs, which cloud images already have.

Fedora 45 isn't tested, since GitLab has no packages for it.

## License

MPL-2.0. See [LICENSE](LICENSE). GitLab Community Edition itself is MIT.
