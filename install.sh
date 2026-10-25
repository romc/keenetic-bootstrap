#!/bin/sh
# Run on the user's computer: copies this bundle to the router and runs setup.sh there.
#
#   ./install.sh [-p PORT] [user@]HOST [setup.sh args...]
#   ./install.sh backup [-p PORT] [user@]HOST
#
# Unlike "git clone" on the router, this also ships local/ (keys, personal VPN
# exceptions). setup.sh asks its questions over the ssh terminal; pass -y to
# take the defaults. Fresh entware listens for SSH on port 222 (root / keenetic):
#   ./install.sh -p 222 root@<router-ip>
#   ./install.sh -p 222 root@<router-ip> -y --extras --keys
# "backup" saves the router's startup-config into local/backups/ (contains
# password hashes and keys - local/ is git-ignored), to restore it after reset.

set -eu

cd "$(dirname "$0")"

MODE=install
[ "${1:-}" = backup ] && { MODE=backup; shift; }

PORT=22
if [ "${1:-}" = -p ]; then PORT=$2; shift 2; fi
[ $# -ge 1 ] || { sed -n '2,14p' "$0"; exit 2; }
HOST=$1; shift

SSH="ssh -p $PORT -o ConnectTimeout=15 $HOST"

if [ "$MODE" = backup ]; then
  mkdir -p local/backups
  out="local/backups/startup-config-$(date +%Y%m%d-%H%M%S).txt"
  $SSH 'ndmc -c "show running-config"' > "$out"
  chmod 600 "$out"
  echo "saved $out ($(wc -l < "$out") lines)"
  exit 0
fi

DIR=/opt/tmp/keenetic-bootstrap
# busybox tar on the router only extracts and may lack gzip - send a plain tar
if [ -d local ]; then
  COPYFILE_DISABLE=1 tar -cf - --exclude 'local/backups' setup.sh files extras local
else
  COPYFILE_DISABLE=1 tar -cf - setup.sh files extras
fi | $SSH "rm -rf $DIR && mkdir -p $DIR && tar -xf - -C $DIR"

# -t: a terminal for setup.sh questions
# shellcheck disable=SC2029 # args are expanded locally on purpose
ssh -t -p "$PORT" -o ConnectTimeout=15 "$HOST" "sh $DIR/setup.sh $*"
