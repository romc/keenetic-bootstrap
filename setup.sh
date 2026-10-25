#!/bin/sh
# keenetic-bootstrap: split routing for Keenetic with entware - the default
# route stays on your VPN connection(s), Russian IPv4 networks go directly via
# the ISP (bird2 fills a separate routing table, an ip rule looks it up first).
#
#   sh setup.sh                 interactive: checks, current state, questions
#   sh setup.sh -y [options]    no questions: defaults + options
#   sh setup.sh --uninstall [--purge]
#
#   -y, --yes              do not ask, use defaults (also without a terminal)
#   --isp IFACE            ISP interface, kernel name (default: detected)
#   --extras               install cpuwatch and Cloudflare IPv6 unreachable routes
#   --keys                 install local/authorized_keys for dropbear
#   --no-update            do not download the lists now (cron does it within 4 h)
#   --replace-bird4static  replace an existing Bird4Static setup without asking
#   --uninstall            remove everything this script installed
#   --purge                with --uninstall: also delete lists, cache, exceptions
#
# Safe to run again; changed files are saved as *.bak-<timestamp>.

set -eu

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
HERE=$(cd "$(dirname "$0")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
MARK=keenetic-bootstrap

CONF=/opt/etc/ru-routes.conf
STATE=/opt/var/lib/ru-routes
EXCEPTIONS=/opt/etc/ru-routes/vpn-exceptions.conf
BIRD_CONF=/opt/etc/bird.conf
CRON_LINE="17 */4 * * * root /opt/sbin/ru-routes-cron # $MARK"
PACKAGES="bird2 bird2c curl iprange diffutils ip-full cron ca-bundle"
PROBE_RU=77.88.8.8
TABLE=1100
PRIO=30100

ASK=1
ISP_IFACE=""
WITH_EXTRAS=""
WITH_KEYS=""
DO_UPDATE=""
REPLACE_B4S=""
UNINSTALL=0
PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASK=0 ;;
    --isp) [ $# -ge 2 ] || { echo "--isp needs an interface" >&2; exit 2; }; ISP_IFACE=$2; shift ;;
    --extras) WITH_EXTRAS=1 ;;
    --keys) WITH_KEYS=1 ;;
    --no-update) DO_UPDATE=0 ;;
    --replace-bird4static) REPLACE_B4S=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -t 0 ] || ASK=0

log() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARN: %s\n' "$*"; }
die() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

# yesno <question> <default y|n>: prints 1 or 0
yesno() {
  if [ "$ASK" = 0 ]; then if [ "$2" = y ]; then echo 1; else echo 0; fi; return; fi
  while :; do
    if [ "$2" = y ]; then printf '%s [Y/n] ' "$1" >&2; else printf '%s [y/N] ' "$1" >&2; fi
    read -r a || a=""
    case "${a:-$2}" in
      [Yy]*) echo 1; return ;;
      [Nn]*) echo 0; return ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

# ask <question> <default>: prints the answer
ask() {
  if [ "$ASK" = 0 ]; then echo "$2"; return; fi
  printf '%s [%s]: ' "$1" "$2" >&2
  read -r a || a=""
  echo "${a:-$2}"
}

# install_file <src> <dst> <mode>: copy, keeping a backup of a different file
install_file() {
  mkdir -p "$(dirname "$2")"
  if [ -L "$2" ]; then
    rm -f "$2"
  elif [ -f "$2" ]; then
    if cmp -s "$1" "$2"; then chmod "$3" "$2"; return 0; fi
    cp -p "$2" "$2.bak-$TS"
    log "saved $2.bak-$TS"
  fi
  cp "$1" "$2"
  chmod "$3" "$2"
  log "installed $2"
}

ours() { [ -f "$1" ] && grep -q "$MARK" "$1"; }

# Keenetic connections that can carry internet: "kernel-name id type address"
wan_list() {
  ndmc -c "show interface" 2>/dev/null | tr -d '\r' | awk '
    function out() { if (id != "" && glob == "yes" && type != "Port") print id, type, addr }
    /^ *id:/ { out(); id = $2; type = ""; glob = "no"; addr = "-" }
    /^ *type:/ { if (type == "") type = $2 }
    /^ *global:/ { glob = $2 }
    /^ *address:/ { if (addr == "-") addr = $2 }
    END { out() }' |
  while read -r id type addr; do
    dev=$(ndmc -c "show interface $id system-name" 2>/dev/null | tr -d '\r' | sed -n 's/.*system-name: *//p' | head -1)
    [ -n "$dev" ] && echo "$dev $id $type $addr"
  done
}

# ISP guess: a PPPoE connection, else the "ISP" port, else the first connected
# Ethernet-type WAN, else eth3
detect_isp() {
  wan=/opt/tmp/$MARK.wan
  wan_list > "$wan" 2>/dev/null || true
  v=$(awk '$3 == "PPPoE" && $4 != "-" { print $1; exit }' "$wan")
  if [ -z "$v" ]; then
    isp_id=$(ndmc -c "show interface ISP" 2>/dev/null | tr -d '\r' | sed -n 's/^ *id: *//p' | head -1)
    [ -n "$isp_id" ] && v=$(awk -v id="$isp_id" '$2 == id { print $1; exit }' "$wan")
  fi
  [ -z "$v" ] && v=$(awk '$3 ~ /^(GigabitEthernet|FastEthernet|Ipoe|UsbLte|UsbModem|WifiStation)$/ && $4 != "-" { print $1; exit }' "$wan")
  rm -f "$wan"
  echo "${v:-eth3}"
}

# an active Bird4Static: its init script, its cron job or its route script
b4s_found() {
  [ -e /opt/etc/init.d/S02bird-table ] || [ -L /opt/etc/init.d/S02bird-table ] || \
    [ -e /opt/etc/cron.hourly/add-bird4_routes.sh ] || [ -L /opt/etc/cron.hourly/add-bird4_routes.sh ] || \
    [ -e /opt/root/Bird4Static/scripts/add-bird4_routes.sh ]
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  echo "=== keenetic-bootstrap: uninstall ==="
  [ "$(yesno 'Remove ru-routes (rule, bird config, cron job, scripts)?' y)" = 1 ] || exit 0
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
  [ -x /opt/etc/init.d/S02ru-routes ] && /opt/etc/init.d/S02ru-routes stop
  rm -f /opt/etc/init.d/S02ru-routes /opt/sbin/ru-routes-update /opt/sbin/ru-routes-cron \
    /opt/etc/init.d/S02ru-routes.bak-* /opt/sbin/ru-routes-update.bak-* /opt/sbin/ru-routes-cron.bak-* "$CONF".bak-*
  if [ -f /opt/etc/crontab ] && grep -q "# $MARK\$" /opt/etc/crontab; then
    sed -i "/# $MARK\$/d" /opt/etc/crontab
    /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
  fi
  if ours "$BIRD_CONF"; then
    if [ -f "$BIRD_CONF.before-ru-routes" ]; then
      mv "$BIRD_CONF.before-ru-routes" "$BIRD_CONF"
      log "restored the previous $BIRD_CONF"
      /opt/etc/init.d/S70bird restart >/dev/null 2>&1 || true
    else
      /opt/etc/init.d/S70bird stop >/dev/null 2>&1 || true
      rm -f "$BIRD_CONF"
      log "bird stopped, $BIRD_CONF removed"
    fi
  fi
  ip route flush table "$TABLE" 2>/dev/null || true
  for f in /opt/etc/init.d/S98cpuwatch /opt/etc/init.d/S03cloudflare-ipv6-unreachable; do
    if ours "$f"; then "$f" stop >/dev/null 2>&1 || true; rm -f "$f"; log "removed $f"; fi
  done
  if ours /opt/bin/cpuwatch.sh; then rm -f /opt/bin/cpuwatch.sh; fi
  rm -f "$CONF"
  if [ "$PURGE" = 1 ]; then
    rm -rf "$STATE" /opt/etc/ru-routes /opt/var/log/ru-routes.log
    log "lists, cache and exceptions deleted"
  else
    log "kept: $STATE (lists, cache), $EXCEPTIONS - delete with --uninstall --purge"
  fi
  log "packages ($PACKAGES) and dropbear keys are left as they are"
  log "done"
  exit 0
fi

# ---------------------------------------------------------------- checks
echo
echo "=== keenetic-bootstrap: default via VPN, Russian networks via ISP ==="

[ -d /opt/etc ] && [ -x /opt/bin/opkg ] || die "entware not found in /opt"
[ "$(id -u)" = 0 ] || die "run as root"
command -v ndmc >/dev/null 2>&1 || warn "ndmc not found - is this a Keenetic? interface detection will be limited"

free_kb=$(df -k /opt | awk 'NR == 2 { print $4 }')
log "free on /opt: $((free_kb / 1024)) MB"
[ "$free_kb" -ge 102400 ] || die "need at least 100 MB free on /opt (download cache is ~45 MB)"
mkdir -p /opt/tmp

# ---------------------------------------------------------------- current state
echo
ISP_DEFAULT=""
if [ -f "$CONF" ]; then
  ISP_DEFAULT=$(sed -n 's/^ISP_IFACE=//p' "$CONF" | head -1)
  echo "Current installation:"
  echo "  ISP interface:  ${ISP_DEFAULT:-?}"
  echo "  ip rule $PRIO: $(ip rule show | grep -q "^$PRIO:" && echo on || echo OFF)"
  echo "  table $TABLE:     $(ip route show table "$TABLE" 2>/dev/null | wc -l) routes"
  echo "  bird:           $(pidof bird >/dev/null 2>&1 && echo running || echo STOPPED)"
  [ -f "$STATE/meta" ] && echo "  lists updated:  $(sed -n 's/^updated=//p' "$STATE/meta")"
  echo "  $PROBE_RU:      $(ip route get "$PROBE_RU" 2>/dev/null | head -1)"
  if ours /opt/etc/init.d/S98cpuwatch; then echo "  extras:         installed"; fi
else
  echo "No previous installation - fresh install."
fi

if b4s_found; then
  echo
  warn "Bird4Static found:"
  for f in /opt/etc/init.d/S02bird-table /opt/etc/cron.hourly/add-bird4_routes.sh /opt/root/Bird4Static/scripts/add-bird4_routes.sh; do
    if [ -e "$f" ] || [ -L "$f" ]; then echo "    $f"; fi
  done
  echo "  It uses the same tools (bird, ip rule) and would conflict. If you go on, its"
  echo "  init script and cron job are stopped and moved to $STATE/replaced-bird4static/,"
  echo "  $BIRD_CONF is saved; the /opt/root/Bird4Static directory is left as it is."
  [ -n "$REPLACE_B4S" ] || REPLACE_B4S=$(yesno "Replace it?" n)
  [ "$REPLACE_B4S" = 1 ] || die "stopped: Bird4Static is in place (use --replace-bird4static to replace it)"
elif [ -d /opt/root/Bird4Static ]; then
  log "note: /opt/root/Bird4Static is not used any more and can be deleted"
fi

# ---------------------------------------------------------------- questions
echo
[ "$(yesno 'Begin install?' y)" = 1 ] || exit 0

if [ -z "$ISP_IFACE" ]; then
  echo
  echo "Internet connections (kernel name, Keenetic interface, type, address):"
  echo "----------------------"
  wan_list | awk '{ printf "  %-10s %-24s %-16s %s\n", $1, $2, $3, $4 }'
  echo "----------------------"
  echo "Pick the ISP connection (PPPoE: the pppN line, not the Ethernet port under it)."
  ISP_IFACE=$(ask "ISP interface for Russian networks" "${ISP_DEFAULT:-$(detect_isp)}")
fi
ip link show "$ISP_IFACE" >/dev/null 2>&1 || die "interface $ISP_IFACE not found"
log "ISP interface: $ISP_IFACE"

if [ -z "$WITH_EXTRAS" ]; then
  def=n
  if ours /opt/etc/init.d/S98cpuwatch; then def=y; fi
  echo
  echo "Extras: cpuwatch (logs CPU spikes and ping loss via VPN/ISP to the router log)"
  echo "and unreachable routes for Cloudflare IPv6 (so it cannot bypass the IPv4 VPN)."
  WITH_EXTRAS=$(yesno "Install extras?" "$def")
fi

if [ -z "$WITH_KEYS" ]; then
  WITH_KEYS=0
  if [ -f "$HERE/local/authorized_keys" ]; then
    echo
    echo "Public keys in local/authorized_keys:"
    awk 'NF { print "  " $1, $NF }' "$HERE/local/authorized_keys"
    WITH_KEYS=$(yesno "Install them for dropbear (root login by key)?" y)
  fi
fi
if [ "$WITH_KEYS" = 1 ] && [ ! -f "$HERE/local/authorized_keys" ]; then
  die "--keys: put public keys into local/authorized_keys"
fi

if [ -z "$DO_UPDATE" ]; then
  echo
  DO_UPDATE=$(yesno "Download the Russian networks lists now (1-3 min)?" y)
fi

# ---------------------------------------------------------------- packages
echo
log "opkg update + packages: $PACKAGES"
# one dead third-party feed makes "opkg update" fail as a whole: retry, then go
# on - "opkg install" fails clearly if the entware feed itself is unreachable
err=/opt/tmp/$MARK-opkg.$$
i=1
until opkg update >/dev/null 2>"$err"; do
  if [ "$i" -ge 3 ]; then
    warn "opkg update had errors, continuing:"
    sed 's/^/    /' "$err"
    break
  fi
  warn "opkg update failed, retry $i/2 in 10 s"
  i=$((i + 1))
  sleep 10
done
rm -f "$err"
# shellcheck disable=SC2086
opkg install $PACKAGES >/dev/null || die "opkg install failed"

# ---------------------------------------------------------------- Bird4Static
if [ "$REPLACE_B4S" = 1 ] && b4s_found; then
  bak="$STATE/replaced-bird4static"
  mkdir -p "$bak"
  if [ -e /opt/etc/init.d/S02bird-table ] || [ -L /opt/etc/init.d/S02bird-table ]; then
    sh /opt/etc/init.d/S02bird-table stop >/dev/null 2>&1 || true
    mv /opt/etc/init.d/S02bird-table "$bak/S02bird-table-$TS"
  fi
  if [ -e /opt/etc/cron.hourly/add-bird4_routes.sh ] || [ -L /opt/etc/cron.hourly/add-bird4_routes.sh ]; then
    mv /opt/etc/cron.hourly/add-bird4_routes.sh "$bak/add-bird4_routes.sh-$TS"
  fi
  log "Bird4Static init script / cron job moved to $bak"
fi

# ---------------------------------------------------------------- files
mkdir -p /opt/etc/ru-routes "$STATE"
cat > "$CONF.new" <<EOF
# $MARK settings (read by ru-routes-update and S02ru-routes)
ISP_IFACE=$ISP_IFACE
ISP_GW=auto
GEOIP=1
TABLE=$TABLE
PRIO=$PRIO
EOF
install_file "$CONF.new" "$CONF" 644
rm -f "$CONF.new"

install_file "$HERE/files/ru-routes-update" /opt/sbin/ru-routes-update 755
install_file "$HERE/files/ru-routes-cron" /opt/sbin/ru-routes-cron 755
install_file "$HERE/files/S02ru-routes" /opt/etc/init.d/S02ru-routes 755
if [ -f "$HERE/local/vpn-exceptions.conf" ]; then
  install_file "$HERE/local/vpn-exceptions.conf" "$EXCEPTIONS" 644
elif [ ! -f "$EXCEPTIONS" ]; then
  install_file "$HERE/files/vpn-exceptions.conf" "$EXCEPTIONS" 644
fi
[ -f "$STATE/isp.routes" ] || : > "$STATE/isp.routes"

if [ -f "$BIRD_CONF" ] && ! ours "$BIRD_CONF"; then
  if [ -f "$BIRD_CONF.before-ru-routes" ]; then
    : # install_file below keeps a .bak of it
  else
    mv "$BIRD_CONF" "$BIRD_CONF.before-ru-routes"
    log "saved $BIRD_CONF.before-ru-routes (restored by --uninstall)"
  fi
fi
cat > "$BIRD_CONF.new" <<EOF
# $MARK: Russian networks via the ISP. Generated by setup.sh.
log syslog { warning, error, fatal };

protocol device {
	scan time 30;
}

ipv4 table ru;

# everything in "ru" goes to kernel table $TABLE (ip rule $PRIO, S02ru-routes)
protocol kernel ru_kernel {
	kernel table $TABLE;
	scan time 60;
	ipv4 {
		table ru;
		import none;
		export all;
	};
}

# generated by ru-routes-update (cron, every 4 hours)
protocol static ru_isp {
	ipv4 { table ru; };
	include "$STATE/isp.routes";
}

# kept by hand
protocol static ru_vpn_exceptions {
	ipv4 { table ru; };
	include "$EXCEPTIONS";
}
EOF
bird -p -c "$BIRD_CONF.new" || die "generated bird config does not parse"
install_file "$BIRD_CONF.new" "$BIRD_CONF" 644
rm -f "$BIRD_CONF.new"

touch /opt/etc/crontab
if ! grep -qF "$CRON_LINE" /opt/etc/crontab; then
  sed -i "/# $MARK\$/d" /opt/etc/crontab
  printf '%s\n' "$CRON_LINE" >> /opt/etc/crontab
  log "cron: every 4 hours"
fi

if [ "$WITH_EXTRAS" = 1 ]; then
  install_file "$HERE/extras/cpuwatch.sh" /opt/bin/cpuwatch.sh 755
  install_file "$HERE/extras/S98cpuwatch" /opt/etc/init.d/S98cpuwatch 755
  install_file "$HERE/extras/S03cloudflare-ipv6-unreachable" /opt/etc/init.d/S03cloudflare-ipv6-unreachable 755
fi

if [ "$WITH_KEYS" = 1 ]; then
  install_file "$HERE/local/authorized_keys" /opt/etc/dropbear/authorized_keys 600
  chmod 700 /opt/etc/dropbear
fi

# ---------------------------------------------------------------- start
log "start"
/opt/etc/init.d/S10cron restart >/dev/null 2>&1 || /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
/opt/etc/init.d/S02ru-routes start
if pidof bird >/dev/null 2>&1; then
  birdc configure >/dev/null || die "birdc configure failed"
else
  /opt/etc/init.d/S70bird start >/dev/null
fi
if [ "$WITH_EXTRAS" = 1 ]; then
  /opt/etc/init.d/S03cloudflare-ipv6-unreachable start
  /opt/etc/init.d/S98cpuwatch restart >/dev/null
fi

if [ "$DO_UPDATE" = 1 ]; then
  log "downloading the lists"
  /opt/sbin/ru-routes-update --force || die "ru-routes-update failed"
fi

# ---------------------------------------------------------------- checks
echo
log "checks"
sleep 3
fail=0
if ip rule show | grep -q "^$PRIO:"; then log "ok: ip rule $PRIO -> table $TABLE"; else log "FAIL: no ip rule $PRIO"; fail=1; fi
if pidof bird >/dev/null 2>&1; then log "ok: bird running"; else log "FAIL: bird is not running"; fail=1; fi
if pidof cron >/dev/null 2>&1; then log "ok: cron running"; else log "FAIL: cron is not running"; fail=1; fi
n=$(ip route show table "$TABLE" | wc -l)
log "table $TABLE: $n routes"
if [ "$DO_UPDATE" = 1 ] && [ "$n" -lt 1000 ]; then log "FAIL: too few routes"; fail=1; fi
r=$(ip route get "$PROBE_RU" 2>/dev/null | head -1)
case "$r" in
  *"dev $ISP_IFACE "*|*"dev $ISP_IFACE") log "ok: $PROBE_RU -> $ISP_IFACE (direct)" ;;
  *) if [ "$DO_UPDATE" = 1 ]; then log "FAIL: $PROBE_RU -> $r"; fail=1; else log "later: $PROBE_RU -> $r"; fi ;;
esac
log "default route: $(ip route get 1.1.1.1 2>/dev/null | head -1)"
if [ "$fail" = 0 ]; then log "done"; else die "some checks failed"; fi
