# Local example

Applies circuit-gitlab to a throwaway Ubuntu 24.04 container with systemd. You need Conn3x, Podman, and a Podman machine or Linux host with 8 GB of memory to spare.

GitLab sets kernel parameters for its PostgreSQL, so the host container runs privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
export TF_VAR_root_password='pick-a-long-one-here'
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply downloads about 1.5 GB and runs GitLab's first reconfigure, so give it 10 to 15 minutes. The second plan says `No changes.` To sign in as `root` with your password, open a tunnel and browse to <http://localhost:8929>:

```sh
ssh -p 2287 -i id_ed25519 -o UserKnownHostsFile=known_hosts -N -L 8929:127.0.0.1:8929 root@127.0.0.1
```

`up.sh` listens on `127.0.0.1:2287`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
