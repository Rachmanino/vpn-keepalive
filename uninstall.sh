#!/usr/bin/env bash
# Remove the daemon and the credential file. Leaves ~/bin/vpn-fortinet.sh and
# the logs alone — delete those by hand if you want them gone.
set -uo pipefail
LABEL=com.vpn.fortinet-keepalive
PLIST=/Library/LaunchDaemons/$LABEL.plist

sudo launchctl bootout "system/$LABEL" 2>/dev/null && echo "unloaded $LABEL" \
  || echo "$LABEL was not loaded"
sudo rm -f "$PLIST" && echo "removed $PLIST"
sudo rm -f /etc/openconnect-forti.conf && echo "removed /etc/openconnect-forti.conf"
# The supervisor re-execs itself under sudo, so kill the root copy too.
sudo pkill -f "[v]pn-fortinet.sh" 2>/dev/null && echo "killed the supervisor"
sudo pkill -f "[o]penconnect --user" 2>/dev/null && echo "killed openconnect"
echo "done. ~/bin/vpn-fortinet.sh and ~/.vpn-fortinet*.log were left in place."
