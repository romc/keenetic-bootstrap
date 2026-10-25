#!/bin/sh
# keenetic-bootstrap extra: lightweight CPU spike logger for Keenetic (entware, busybox sh).
# Samples /proc/stat every $INTERVAL s; when total busy >= $TOTAL_THR % or any
# core >= $CORE_THR %, writes one syslog line (tag cpuwatch) with per-core
# busy/softirq, NET_RX deltas per core, rx+tx rates of $IFACES and top-3
# processes, plus top-3 LAN clients from conntrack (flows / DNS flows to the
# router / MB in their live flows). Every $HEARTBEAT samples logs the period maximum.
# Each sample also pings $PROBE_DEF via the default route (VPN) and $PROBE_ISP via
# $ISP_IFACE (ISP direct); loss or rtt >= $RTT_THR ms also triggers a SPIKE line, so
# traffic drops are visible even without CPU load.
# Lines go to the router log (and to a remote syslog server, if one is configured).

INTERVAL=${INTERVAL:-5}
TOTAL_THR=${TOTAL_THR:-50}
CORE_THR=${CORE_THR:-85}
HEARTBEAT=${HEARTBEAT:-120}   # 120 * 5 s = 10 min
# shellcheck disable=SC1091
[ -f /opt/etc/ru-routes.conf ] && . /opt/etc/ru-routes.conf
ISP_IFACE=${ISP_IFACE:-eth3}
# default: ISP + WireGuard/OpenVPN/PPP interfaces present at start
IFACES=${IFACES:-"$ISP_IFACE $(ls /sys/class/net 2>/dev/null | grep -E '^(nwg|ovpn|ppp)' | tr '\n' ' ')"}
RTT_THR=${RTT_THR:-250}
PROBE_DEF=${PROBE_DEF:-1.1.1.1}
PROBE_ISP=${PROBE_ISP:-77.88.8.8}

# prints rtt in ms (integer) or LOSS
probe() {
  r=$(ping -c1 -W1 "$@" 2>/dev/null | sed -n 's/.*time=\([0-9]*\).*/\1/p')
  [ -n "$r" ] && echo "$r" || echo LOSS
}

# top-3 LAN sources in conntrack: ip=flows/dns/MB (MB = orig+reply bytes of live flows)
top_hosts() {
  awk '{ src=""; dport=""; b=0; nb=0
    for (i=1;i<=NF;i++) {
      if (src=="" && $i ~ /^src=/) src=substr($i,5)
      else if (dport=="" && $i ~ /^dport=/) dport=substr($i,7)
      else if ($i ~ /^bytes=/ && nb<2) { b+=substr($i,7); nb++ } }
    if (src !~ /^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/) next
    F[src]++; B[src]+=b; if (dport=="53") D[src]++ }
    END { for (h in F) printf "%d %s=%d/%d/%.0fMB\n", F[h], h, F[h], D[h]+0, B[h]/1048576 }' \
    /proc/net/nf_conntrack 2>/dev/null | sort -rn | head -3 | cut -d' ' -f2 | tr '\n' ' '
}

snap_cpu() { grep '^cpu' /proc/stat; }
snap_netrx() { awk '/NET_RX/{for(i=2;i<=NF;i++) printf "%s ", $i}' /proc/softirqs; }
snap_if() {
  for i in $IFACES; do
    r=$(cat /sys/class/net/$i/statistics/rx_bytes 2>/dev/null || echo 0)
    t=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0)
    printf '%s:%s:%s ' "$i" "$r" "$t"
  done
}

prev_cpu=$(snap_cpu); prev_rx=$(snap_netrx); prev_if=$(snap_if)
n=0; max_total=0; max_line=""; loss_def=0; loss_isp=0; slow=0

while :; do
  sleep $INTERVAL
  probe $PROBE_DEF > /tmp/cpuwatch.def & probe -I "$ISP_IFACE" $PROBE_ISP > /tmp/cpuwatch.isp & wait
  rtt_def=$(cat /tmp/cpuwatch.def); rtt_isp=$(cat /tmp/cpuwatch.isp)
  cur_cpu=$(snap_cpu); cur_rx=$(snap_netrx); cur_if=$(snap_if)

  # per-cpu busy% and softirq%: fields user nice system idle iowait irq softirq steal
  stats=$(printf '%s\n%s\n' "$prev_cpu" "$cur_cpu" | awk '
    { k=$1; t=0; for(i=2;i<=NF;i++) t+=$i; idle=$5+$6; si=$8
      if (k in T) { dt=t-T[k]; if (dt<=0) dt=1
        b=int(100*(dt-(idle-I[k]))/dt); s=int(100*(si-S[k])/dt)
        if (k=="cpu") tot=b; else { line=line sprintf(" %s=%d/si%d", k, b, s); if (b>mx) mx=b } }
      else { T[k]=t; I[k]=idle; S[k]=si } }
    END { printf "%d %d%s", tot, mx, line }')
  total=${stats%% *}; rest=${stats#* }; maxcore=${rest%% *}; percore=${rest#* }

  netrx=$(printf '%s\n%s\n' "$prev_rx" "$cur_rx" | awk 'NR==1{for(i=1;i<=NF;i++)a[i]=$i} NR==2{for(i=1;i<=NF;i++) printf "%s%d", (i>1?",":""), ($i-a[i])/'$INTERVAL'}')
  ifrates=$(printf '%s\n%s\n' "$prev_if" "$cur_if" | awk -v iv=$INTERVAL '
    NR==1{for(i=1;i<=NF;i++){split($i,p,":"); R[p[1]]=p[2]; X[p[1]]=p[3]}}
    NR==2{for(i=1;i<=NF;i++){split($i,p,":"); printf "%s %s=%.1f/%.1fMbit", (i>1?"":""), p[1], (p[2]-R[p[1]])*8/iv/1e6, (p[3]-X[p[1]])*8/iv/1e6}}')

  net_bad=0
  for v in $rtt_def $rtt_isp; do
    if [ "$v" = LOSS ] || [ "$v" -ge "$RTT_THR" ]; then net_bad=1; fi
  done
  [ "$rtt_def" = LOSS ] && loss_def=$((loss_def+1))
  [ "$rtt_isp" = LOSS ] && loss_isp=$((loss_isp+1))
  [ "$net_bad" = 1 ] && slow=$((slow+1))

  msg="ping def=${rtt_def} isp=${rtt_isp} total=${total}% cores:${percore} netrx/s=${netrx}${ifrates} load=$(cut -d' ' -f1-3 /proc/loadavg)"

  if [ "$total" -ge "$TOTAL_THR" ] || [ "$maxcore" -ge "$CORE_THR" ] || [ "$net_bad" = 1 ]; then
    top3=$(top -b -n1 2>/dev/null | awk '$1~/^[0-9]+$/ && $9!="top" {printf "%s %s%%; ", $9, $8; if (++c==3) exit}')
    logger -t cpuwatch "SPIKE $msg top: $top3 hosts(flows/dns/MB): $(top_hosts)"
  fi

  if [ "$total" -gt "$max_total" ]; then max_total=$total; max_line=$msg; fi
  n=$((n+1))
  if [ "$n" -ge "$HEARTBEAT" ]; then
    logger -t cpuwatch "max10m bad_samples=$slow loss_def=$loss_def loss_isp=$loss_isp maxcpu: $max_line"
    n=0; max_total=0; max_line=""; loss_def=0; loss_isp=0; slow=0; loss_def=0; loss_isp=0; slow=0
  fi

  prev_cpu=$cur_cpu; prev_rx=$cur_rx; prev_if=$cur_if
done
