#!/usr/bin/env bash
set -uo pipefail

POD_CIDR_PREFIX=${POD_CIDR_PREFIX:-10.244.}

failed=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK   ${name}"; else echo "FAIL ${name}"; failed=1; fi
}

pods_running() {
  kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{bad=1} END{exit bad}'
}

pods_in_pod_cidr() {
  local ips
  ips=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}')
  [[ -n "${ips}" ]] || return 1
  for ip in ${ips}; do
    [[ "${ip}" == "${POD_CIDR_PREFIX}"* ]] || return 1
  done
}

cluster_dns() {
  kubectl run "verify-dns-$$" --rm -i --restart=Never --timeout=120s \
    --image=busybox:1.37.0 --command -- nslookup kubernetes.default.svc.cluster.local
}

default_storageclass() {
  kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' |
    grep -q .
}

check "node Ready" kubectl wait node --all --for=condition=Ready --timeout=120s
check "pods Running" pods_running
check "pod IP from pod CIDR" pods_in_pod_cidr
check "cluster DNS" cluster_dns
check "default StorageClass" default_storageclass

exit "${failed}"
