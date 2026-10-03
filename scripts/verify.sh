#!/usr/bin/env bash
set -uo pipefail

POD_CIDR_PREFIX=${POD_CIDR_PREFIX:-10.244.}
APP_NS=${APP_NS:-demo}

failed=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK   ${name}"; else echo "FAIL ${name}"; failed=1; fi
}

pods_running() {
  local deadline=$((SECONDS + 180))
  while :; do
    if kubectl get pods -A --no-headers |
      awk '$4!="Running" && $4!="Completed"{bad=1} END{exit bad}'; then
      return 0
    fi
    [[ ${SECONDS} -lt ${deadline} ]] || return 1
    sleep 5
  done
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

app_url() {
  echo "http://$(kubectl -n "${APP_NS}" get svc hello -o jsonpath='{.spec.clusterIP}')$1"
}

app_hello() {
  kubectl -n "${APP_NS}" rollout status deployment -l app=hello --timeout=120s &&
    curl -fsS --retry 5 --retry-all-errors --max-time 5 "$(app_url /)" | grep -qx 'Hello World!'
}

app_access_log() {
  local uri="/verify-$$-${RANDOM}" deadline=$((SECONDS + 30))
  curl -fsS --max-time 5 "$(app_url "${uri}")" >/dev/null || return 1
  until kubectl -n "${APP_NS}" logs -l app=hello --tail=100 |
    grep -F "\"uri\":\"${uri}\"" | grep -q '"status":200'; do
    [[ ${SECONDS} -lt ${deadline} ]] || return 1
    sleep 2
  done
}

gateway_ip() {
  kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}'
}

gateway_programmed() {
  kubectl -n gateway wait gateway/public --for=condition=Programmed --timeout=120s
}

gateway_on_node_ip() {
  local node_ip
  node_ip=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  [[ -n "${node_ip}" && "$(gateway_ip)" == "${node_ip}" ]]
}

route_accepted() {
  kubectl -n "${APP_NS}" wait httproute/hello --timeout=60s \
    --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True
}

gw_curl() {
  curl -ksS --retry 5 --retry-all-errors --max-time 5 "$@"
}

gateway_http() {
  gw_curl "http://$(gateway_ip)/" | grep -qx 'Hello World!'
}

gateway_https() {
  gw_curl "https://$(gateway_ip)/" | grep -qx 'Hello World!'
}

gateway_path() {
  local v
  for v in v1 v2; do
    gw_curl -o /dev/null -D - "http://$(gateway_ip)/${v}" | grep -qi "^x-app-version: ${v}" || return 1
  done
}

# 80/20 между v1 и v2: за 50 запросов должны встретиться обе версии
gateway_split() {
  local ip seen
  ip=$(gateway_ip)
  seen=$(for _ in $(seq 50); do gw_curl -o /dev/null -D - "http://${ip}/"; done |
    grep -i '^x-app-version:' | tr -d '\r' | awk '{print $2}' | sort -u | tr '\n' ' ')
  [[ "${seen}" == "v1 v2 " ]]
}

check "node Ready" kubectl wait node --all --for=condition=Ready --timeout=120s
check "no DiskPressure" kubectl wait node --all --for=condition=DiskPressure=false --timeout=10s
check "no MemoryPressure" kubectl wait node --all --for=condition=MemoryPressure=false --timeout=10s
check "pods Running" pods_running
check "pod IP from pod CIDR" pods_in_pod_cidr
check "cluster DNS" cluster_dns
check "default StorageClass" default_storageclass
check "app answers Hello World" app_hello
check "app access log" app_access_log
check "Gateway Programmed" gateway_programmed
check "Gateway address is node IP" gateway_on_node_ip
check "HTTPRoute Accepted" route_accepted
check "Gateway HTTP :80 Hello World" gateway_http
check "Gateway HTTPS :443 Hello World" gateway_https
check "Gateway path routing /v1 /v2" gateway_path
check "Gateway traffic split v1/v2" gateway_split

exit "${failed}"
