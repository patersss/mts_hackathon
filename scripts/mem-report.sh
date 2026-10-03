#!/usr/bin/env bash
# свободная память и память подов по cgroup (anon, без page cache), МБ
set -uo pipefail

echo "INFO MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB"
# у static-подов cgroup назван по config.hash, а не по uid
pods=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.uid} {.metadata.annotations.kubernetes\.io/config\.hash} {.metadata.namespace}/{.metadata.name}{"\n"}{end}')
find /sys/fs/cgroup/kubepods.slice -maxdepth 2 -name 'kubepods-*pod*.slice' | while read -r d; do
  uid=${d##*pod}; uid=${uid%.slice}; uid=${uid//_/-}
  echo "INFO $(awk '/^anon /{print int($2/1048576)}' "${d}/memory.stat") MB $(awk -v u="${uid}" '$1==u||$2==u{print $NF}' <<<"${pods}")"
done | sort -k2 -rn
echo "INFO $(awk '/^anon /{print int($2/1048576)}' /sys/fs/cgroup/system.slice/memory.stat) MB system.slice"
