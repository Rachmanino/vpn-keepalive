#!/usr/bin/env bash
# One-shot deploy of the supervised Fortinet tunnel on macOS.
#
#   git clone <this repo> && cd vpn-keepalive && ./install.sh
#
# Asks for the VPN username and password, writes them to a root-only file,
# installs the supervisor and loads it as a LaunchDaemon. Everything else —
# the Homebrew prefix, the vpnc-script path, your username and home — is
# detected, so the same clone works on Apple Silicon and Intel.
#
# If the login needs an OTP, do NOT use the daemon: run vpn-fortinet.sh in a
# terminal instead, which prompts. A daemon cannot answer an OTP.
set -euo pipefail

LABEL=com.vpn.fortinet-keepalive
PLIST=/Library/LaunchDaemons/$LABEL.plist
CONF=/etc/openconnect-forti.conf
SRC=$(cd "$(dirname "$0")" && pwd)

# Defaults for the deployment this was built for. Override with the
# environment, e.g.  FORTI_SERVER=host:port ./install.sh
: "${FORTI_SERVER:=219.151.21.86:24090}"
: "${FORTI_CERT:=pin-sha256:vGfoJXSZRR4DU6YfpCyrwAd7qJCKujUYTAaZ/IvBrxE}"
: "${WARM_HOST:=}"

die() { echo "error: $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as yourself, not root — it will sudo when needed"
[[ $(uname) == Darwin ]] || die "macOS only (this installs a LaunchDaemon)"

# ---- 1. dependencies -------------------------------------------------------
command -v openconnect >/dev/null || die "openconnect not found — brew install openconnect"

BREW_BIN=$(dirname "$(command -v openconnect)")
VPNC_SCRIPT=""
for c in /opt/homebrew/etc/vpnc/vpnc-script /usr/local/etc/vpnc/vpnc-script \
         /etc/vpnc/vpnc-script; do
  [[ -x $c ]] && { VPNC_SCRIPT=$c; break; }
done
[[ -n $VPNC_SCRIPT ]] || die "vpnc-script not found — brew reinstall openconnect"

echo "openconnect : $(command -v openconnect)"
echo "vpnc-script : $VPNC_SCRIPT"
echo "server      : $FORTI_SERVER"
echo "cert pin    : ${FORTI_CERT:-<none>}"
echo

# ---- 2. credentials --------------------------------------------------------
# The server's certificate has no trusted signer, so an unpinned run stops to
# ask yes/no — and a daemon's stdin is the password pipe, so that prompt dies
# and the tunnel exits in about a second. The pin is not a secret (it is the
# public certificate's fingerprint) but it MUST be updated when the server
# renews, at which point openconnect prints the new one.
read -r -p "VPN username: " USER_IN
[[ -n $USER_IN ]] || die "username is required"
read -r -s -p "VPN password: " PW_IN; echo
[[ -n $PW_IN ]] || die "password is required"

umask 077
TMP=$(mktemp)
{
  printf 'user=%s\npassword=%s\n' "$USER_IN" "$PW_IN"
  [[ -n $FORTI_CERT ]] && printf 'servercert=%s\n' "$FORTI_CERT"
} > "$TMP"
sudo install -m 600 -o root -g wheel "$TMP" "$CONF"
rm -f "$TMP"
echo "wrote $CONF (root-only, 600)"

# ---- 3. the supervisor -----------------------------------------------------
mkdir -p "$HOME/bin"
install -m 755 "$SRC/vpn-fortinet.sh" "$HOME/bin/vpn-fortinet.sh"
[[ -f $SRC/rssh ]] && install -m 755 "$SRC/rssh" "$HOME/bin/rssh"
echo "installed $HOME/bin/vpn-fortinet.sh"

# ---- 4. the daemon ---------------------------------------------------------
TMP=$(mktemp)
sed -e "s|@USER@|$USER|g" -e "s|@HOME@|$HOME|g" \
    -e "s|@BREW_BIN@|$BREW_BIN|g" -e "s|@VPNC_SCRIPT@|$VPNC_SCRIPT|g" \
    -e "s|@WARM_HOST@|$WARM_HOST|g" \
    "$SRC/launchd.plist.in" > "$TMP"
sudo install -m 644 -o root -g wheel "$TMP" "$PLIST"
rm -f "$TMP"

# bootout first so re-running install.sh is safe. It fails when nothing is
# loaded, which is not an error here.
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"
echo "loaded $PLIST"

# ---- 5. verify -------------------------------------------------------------
echo
echo -n "waiting for the tunnel"
for _ in $(seq 1 30); do
  if ifconfig 2>/dev/null | grep -q "10\.140\." ; then echo " — up"; break; fi
  sleep 2; echo -n "."
done
echo
sudo launchctl print "system/$LABEL" 2>/dev/null \
  | grep -E "^\s*(state|pid|last exit code) " || true
echo
echo "log      : tail -f $HOME/.vpn-fortinet.log"
echo "status   : launchctl print system/$LABEL | grep -E 'state|pid|last exit'"
echo "restart  : sudo launchctl kickstart -k system/$LABEL"
echo "remove   : ./uninstall.sh"
