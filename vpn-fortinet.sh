#!/usr/bin/env bash
# Supervised Fortinet VPN for macOS: an unattended restart loop around
# openconnect, run as a LaunchDaemon so a drop re-authenticates by itself.
#
# WHY A RESTART LOOP IS THE MECHANISM, not a workaround. The server says so:
#
#   Server reports that reconnect-after-drop is not allowed. OpenConnect will
#   not be able to reconnect if dead peer is detected.
#
# So openconnect cannot resume a dropped session in place; it exits, and only a
# full re-authentication brings the tunnel back. Observed session lifetimes are
# wildly irregular — 7 min, 8 min, 26 min, 4.9 h — so this has to be unattended.
#
# --no-dtls is already proven to be doing its job ("SSL connected and DTLS
# disabled" in the log), which rules out the usual UDP-through-NAT cause.
# --force-dpd=30 is what makes a half-open tunnel exit in 30 s instead of
# whenever something times out, so the loop can restart it.
#
# CREDENTIALS live in ONE root-only file, /etc/openconnect-forti.conf:
#
#   user=NAME
#   password=SECRET
#   servercert=pin-sha256:...
#
# `servercert` is REQUIRED for unattended operation. The server's certificate
# has no trusted signer, so openconnect stops to ask yes/no — and a daemon's
# stdin is the password pipe, so the prompt dies with
# "fgets (standard input): Argument list too long" and the tunnel exits in 1 s.
# Pinning the exact SHA-256 is openconnect's own recommendation and is stronger
# than accepting whatever is presented; it must be UPDATED when the server
# renews its certificate, at which point the log prints the new pin.
#
# so nothing has to be edited into the plist and re-auth needs nobody at the
# keyboard. Run ./install.sh to create it and load the daemon.
# With no such file the script prompts interactively instead, which is the right
# mode if the login needs an OTP — a daemon cannot answer one.
set -uo pipefail

SERVER=${FORTI_SERVER:-219.151.21.86:24090}
# Homebrew puts vpnc-script under /opt/homebrew on Apple Silicon and
# /usr/local on Intel; install.sh bakes the right one into the plist.
SCRIPT=${VPNC_SCRIPT:-/opt/homebrew/etc/vpnc/vpnc-script}
LOG=${LOG:-$HOME/.vpn-fortinet.log}
FORTI_CONF=${FORTI_CONF:-/etc/openconnect-forti.conf}
FORTI_USER=${FORTI_USER:-}
FORTI_PW=""
FORTI_CERT=${FORTI_CERT:-}
# Host to re-warm an ssh ControlMaster against once the tunnel is back, so the
# first command after a drop does not pay a cold connect inside the window
# where new connections still time out. Empty disables it.
WARM_HOST=${WARM_HOST:-}

[[ $EUID -eq 0 ]] || exec sudo -E FORTI_USER="$FORTI_USER" LOG="$LOG" \
  FORTI_CONF="$FORTI_CONF" WARM_HOST="$WARM_HOST" "$0" "$@"

# Parsed after the re-exec so the file only ever has to be root-readable.
if [[ -r $FORTI_CONF ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      user) FORTI_USER=${FORTI_USER:-$v} ;;
      password) FORTI_PW=$v ;;
      servercert) FORTI_CERT=$v ;;
    esac
  done < "$FORTI_CONF"
fi

args=(--protocol=fortinet --no-dtls --force-dpd=30
      --script="$SCRIPT" --timestamp -v)
[[ -n $FORTI_CERT ]] && args+=(--servercert="$FORTI_CERT")
args+=("$SERVER")

say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Re-warm the ssh master in the background, as the invoking user rather than as
# root: the keys and the ControlPath both live in their home.
warm() {
  [[ -n $WARM_HOST && -n ${SUDO_USER:-} ]] || return 0
  ( sleep 3
    for _ in 1 2 3 4 5; do
      sudo -u "$SUDO_USER" ssh -o ConnectTimeout=10 -o BatchMode=yes \
        "$WARM_HOST" true 2>/dev/null && { say "ssh master warm"; return; }
      sleep 5
    done ) &
}

# --non-inter turns any remaining interactive prompt into an immediate exit
# rather than a hang, so the loop and its backoff stay in control. Only safe
# once the cert is pinned and the password is on stdin.
[[ -n $FORTI_CERT && -n $FORTI_PW ]] && args+=(--non-inter)

say "=== supervising $SERVER (restart loop; server forbids in-place reconnect)"
[[ -n $FORTI_CERT ]] || say "WARNING: no servercert pin — an untrusted server \
certificate will prompt, and a daemon cannot answer it"
fails=0
while :; do
  start=$SECONDS
  warm
  if [[ -n $FORTI_USER && -n $FORTI_PW ]]; then
    printf '%s\n' "$FORTI_PW" |
      caffeinate -dimsu openconnect --user="$FORTI_USER" --passwd-on-stdin \
        "${args[@]}" 2>&1 | tee -a "$LOG"
  else
    caffeinate -dimsu openconnect "${args[@]}" 2>&1 | tee -a "$LOG"
  fi
  up=$((SECONDS - start))
  say "tunnel exited after ${up}s"
  # Under 10 s is a credential or reachability problem, not a drop. Back off
  # instead of hammering: three of those in a row and the account gets locked,
  # which is a far worse outcome than a slow retry.
  if ((up < 10)); then
    fails=$((fails + 1))
    if ((fails >= 3)); then
      say "3 immediate failures — backing off 300s (check credentials/route)"
      sleep 300
      fails=0
    else
      sleep 10
    fi
  else
    fails=0
    sleep 1
  fi
done
