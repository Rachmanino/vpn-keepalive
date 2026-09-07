# vpn-keepalive

An unattended Fortinet VPN tunnel on macOS: a restart loop around
`openconnect`, run as a LaunchDaemon so a dropped session re-authenticates by
itself.

```bash
git clone git@github.com:Rachmanino/vpn-keepalive.git
cd vpn-keepalive
./install.sh          # asks for VPN username + password, does the rest
```

That is the whole deploy. It detects the Homebrew prefix, the `vpnc-script`
path, your username and home, so the same clone works on Apple Silicon and
Intel. Prerequisite: `brew install openconnect`.

## Why a restart loop, not a reconnect

The server refuses in-place recovery. From its own log:

```
Server reports that reconnect-after-drop is not allowed.
OpenConnect will not be able to reconnect if dead peer is detected.
```

So `openconnect` cannot resume a dropped session — it exits, and only a full
re-authentication brings the tunnel back. **The restart loop is the mechanism,
not a workaround; do not go looking for reconnect flags to tune.**

Observed session lifetimes are wildly irregular — 7 min, 8 min, 26 min, 4.9 h —
which is why this has to be unattended. `--no-dtls` is already proven to be
doing its job (`SSL connected and DTLS disabled` in the log), so the usual
UDP-through-NAT cause is ruled out. `--force-dpd=30` is what makes a half-open
tunnel exit in 30 s instead of hanging until something times out, so the loop
can restart it promptly.

## What gets installed

| Path | What |
| --- | --- |
| `~/bin/vpn-fortinet.sh` | the supervisor (restart loop, backoff, ssh re-warm) |
| `~/bin/rssh` | ssh wrapper that retries across drops (optional) |
| `/etc/openconnect-forti.conf` | credentials, root-only 600 |
| `/Library/LaunchDaemons/com.vpn.fortinet-keepalive.plist` | the daemon |
| `~/.vpn-fortinet.log` | tunnel log |

Runs as **root** so re-authentication never prompts for sudo. Both the username
and the password come from the conf file, so nothing in the plist needs
editing.

## Operating it

```bash
launchctl print system/com.vpn.fortinet-keepalive | grep -E "state|pid|last exit"
tail -f ~/.vpn-fortinet.log
sudo launchctl kickstart -k system/com.vpn.fortinet-keepalive   # force restart
./uninstall.sh
```

`state = running` means it is fine. `pgrep openconnect` returning something
means the tunnel is up.

## Two things that will fool you

**Most "it's down" is not down.** The session expires on a server-side timer
(the log prints `Session authentication will expire at <8h later>`), and the
reconnect window is 10–30 s during which new connections time out while the
daemon is perfectly healthy — `state = running`, `last exit code = (never
exited)`, same PID for days. The tunnel address changes across a reconnect
(e.g. `10.140.0.5` → `10.140.0.4`) and routes are rebuilt. Wait and retry
before touching anything.

**Never run `sudo openconnect` by hand.** A manual instance competes with the
supervisor for the one session the server allows. Worse, closing the terminal
leaves an empty `sudo` shell behind (`pgrep -P <pid>` shows no children) that
makes `pgrep -fl vpn` look like there are two supervisors. That is litter, not
a competitor — `sudo kill` it.

## Configuration

`install.sh` takes these from the environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FORTI_SERVER` | `219.151.21.86:24090` | `host:port` |
| `FORTI_CERT` | a `pin-sha256:` value | server certificate pin |
| `WARM_HOST` | empty | ssh host to re-warm a ControlMaster against after a reconnect |

```bash
FORTI_SERVER=vpn.example.com:443 WARM_HOST=build-box ./install.sh
```

### The certificate pin is required

The server's certificate has no trusted signer. Without a pin `openconnect`
stops to ask yes/no — and a daemon's stdin is the password pipe, so that prompt
dies with `fgets (standard input): Argument list too long` and the tunnel exits
in about a second. Pinning the exact SHA-256 is `openconnect`'s own
recommendation and is stronger than blindly accepting whatever is presented.

The pin is **not a secret** (it is the public certificate's fingerprint), but it
**must be updated when the server renews** — at which point the log prints the
new one. Then edit `servercert=` in `/etc/openconnect-forti.conf` and
`sudo launchctl kickstart -k system/com.vpn.fortinet-keepalive`.

### Backoff

Any tunnel that dies within 10 s is treated as a credential or reachability
problem rather than a drop: three of those in a row and the loop sleeps 300 s.
**Do not remove this** — hammering a Fortinet gateway with bad credentials gets
the account locked, which is far worse than a slow retry.

### OTP

If the login requires a one-time password, the daemon cannot work — nothing can
answer the prompt. Run `~/bin/vpn-fortinet.sh` in a terminal instead; with no
conf file it prompts interactively.

## Credentials are never in this repo

`install.sh` prompts for the username and password and writes them straight to
a root-only file. Nothing is committed, nothing lands in your shell history.
