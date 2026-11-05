# Local example

Applies circuit-homeassistant to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

Home Assistant runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs Podman, pulls Home Assistant's image, starts it once to seed its HTTP settings, then starts it for real. The second plan says `No changes.`

Home Assistant listens on `127.0.0.1:8123` inside the container. To finish onboarding in a browser, forward that port over SSH, then open `http://localhost:8123`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8123:127.0.0.1:8123 root@127.0.0.1
```

Or let [check.sh](check.sh) do it, the way CI does. It creates the owner `ci` with the password `Correct-horse-battery-9`, signs in and reads `/api/config`:

```sh
podman exec -i circuit-homeassistant sh < check.sh
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINER_NAME` to name the container something else, and `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
