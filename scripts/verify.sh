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

# с ноды в под не ходим: NetworkPolicy пускает в demo только Gateway и Prometheus
app_url() {
  echo "http://$(gateway_ip)$1"
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

# все правила маршрута с таймаутами, rate limit привязан к правилу v2
route_extras_accepted() {
  [[ "$(kubectl -n "${APP_NS}" get httproute hello -o jsonpath='{.spec.rules[*].timeouts.request}')" == "10s 10s 10s 10s" ]] &&
    kubectl -n "${APP_NS}" wait backendtrafficpolicy/hello-v2-ratelimit --timeout=60s \
      --for=jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'=True
}

gateway_header_route() {
  local ip
  ip=$(gateway_ip)
  for _ in $(seq 10); do
    gw_curl -o /dev/null -D - -H 'X-Version: v2' "http://${ip}/" | grep -qi '^x-app-version: v2' || return 1
  done
}

gateway_response_headers() {
  local h
  h=$(gw_curl -o /dev/null -D - "http://$(gateway_ip)/")
  grep -qi '^x-served-by: envoy-gateway' <<<"${h}" && grep -Eqi '^x-request-id: [0-9a-f-]{36}' <<<"${h}"
}

# коды 30 запросов подряд; без --retry, curl повторяет 429
burst() {
  local ip
  ip=$(gateway_ip)
  for _ in $(seq 30); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${ip}$1"; done
}

ratelimit_v2() {
  burst /v2 | grep -qx 429
}

no_ratelimit_elsewhere() {
  [[ "$(burst /v1 | sort -u)" == 200 && "$(burst / | sort -u)" == 200 ]]
}

ratelimit_metric() {
  prom_expect 'sum({__name__=~"envoy_.*local_rate_limit_rate_limited"}) > bool 0' 1
}

prom_query() {
  local ip
  ip=$(kubectl -n monitoring get svc kps-prometheus -o jsonpath='{.spec.clusterIP}')
  curl -fsS --max-time 5 --get --data-urlencode "query=$1" "http://${ip}:9090/api/v1/query" |
    jq -r '.data.result[0].value[1] // empty'
}

# ждёт, пока запрос вернёт ожидаемое значение: Prometheus находит target не сразу
prom_expect() {
  local query=$1 want=$2 deadline=$((SECONDS + 180))
  until [[ "$(prom_query "${query}")" == "${want}" ]]; do
    [[ ${SECONDS} -lt ${deadline} ]] || return 1
    sleep 5
  done
}

prometheus_ready() {
  kubectl -n monitoring rollout status statefulset/prometheus-kps-prometheus --timeout=180s
}

app_targets_up() {
  local pods
  pods=$(kubectl -n "${APP_NS}" get pods -l app=hello --no-headers | wc -l)
  prom_expect "count(up{job=\"${APP_NS}/hello\"} == 1)" "${pods}"
}

app_requests_metric() {
  curl -fsS --max-time 5 "$(app_url /)" >/dev/null &&
    prom_expect "sum(nginx_http_requests_total{job=\"${APP_NS}/hello\"}) > bool 0" 1
}

envoy_target_up() {
  prom_expect 'min(up{job="envoy-gateway-system/envoy-proxy"})' 1
}

# запрос на <name>.<ip-с-дефисами>.nip.io через Gateway без внешнего DNS
gw_host() {
  local ip host
  ip=$(gateway_ip)
  host="$1.${ip//./-}.nip.io"
  gw_curl --resolve "${host}:443:${ip}" "https://${host}$2" "${@:3}"
}

admin_password() {
  kubectl -n monitoring get secret monitoring-admin -o jsonpath='{.data.admin-password}' | base64 -d
}

grafana_dashboard() {
  gw_host grafana '/api/search?query=Hello' -f -u "admin:$(admin_password)" | grep -q '"uid":"hello"'
}

prometheus_auth() {
  [[ "$(gw_host prometheus /-/ready -o /dev/null -w '%{http_code}')" == 401 ]] &&
    gw_host prometheus /-/ready -f -o /dev/null -u "admin:$(admin_password)"
}

# через datasource proxy Grafana: в Loki пускают только logging и monitoring
loki_query() {
  gw_host grafana /api/datasources/proxy/uid/loki/loki/api/v1/query_range -f --max-time 10 \
    -u "admin:$(admin_password)" --get --data-urlencode "query=$1" --data-urlencode since=15m |
    jq -r '.data.result[].values[][1]'
}

loki_ready() {
  kubectl -n logging rollout status statefulset/loki --timeout=180s &&
    kubectl -n logging rollout status daemonset/fluentd --timeout=120s
}

# запрос с уникальным path через Gateway должен найтись в Loki LogQL-запросом
app_log_in_loki() {
  local uri="/loki-$$-${RANDOM}" deadline=$((SECONDS + 120))
  gw_curl -fo /dev/null "http://$(gateway_ip)${uri}" || return 1
  until loki_query "{namespace=\"${APP_NS}\", container=\"nginx\"} |= \"${uri}\" | json | status=\"200\"" |
    grep -qF "\"uri\":\"${uri}\""; do
    [[ ${SECONDS} -lt ${deadline} ]] || return 1
    sleep 5
  done
}

grafana_loki_datasource() {
  gw_host grafana /api/datasources/uid/loki/health -f -u "admin:$(admin_password)" | grep -q '"status":"OK"'
}

networkpolicies() {
  kubectl -n "${APP_NS}" get networkpolicy default-deny hello &&
    kubectl -n logging get networkpolicy loki
}

# под из default: Gateway отвечает, а $1 недоступен
blocked_from_default() {
  kubectl run "verify-np-$$-${RANDOM}" --rm -i --restart=Never --timeout=120s \
    --image=busybox:1.37.0 --command -- sh -c \
    "wget -qO- -T 5 http://$(gateway_ip)/ | grep -q Hello && ! wget -qO- -T 5 $1"
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
check "HTTPRoute timeouts, rate limit policy Accepted" route_extras_accepted
check "Gateway header X-Version: v2 -> v2" gateway_header_route
check "Gateway response headers X-Served-By, X-Request-ID" gateway_response_headers
check "Gateway rate limit /v2 -> 429" ratelimit_v2
check "Gateway no rate limit on / and /v1" no_ratelimit_elsewhere
check "Prometheus ready" prometheus_ready
check "Prometheus targets app up" app_targets_up
check "Prometheus query nginx_http_requests_total" app_requests_metric
check "Prometheus target envoy up" envoy_target_up
check "Prometheus rate limit metric" ratelimit_metric
check "Grafana dashboard via Gateway" grafana_dashboard
check "Prometheus via Gateway with basic auth" prometheus_auth
check "Loki and Fluentd ready" loki_ready
check "app request found in Loki (LogQL)" app_log_in_loki
check "Grafana Loki datasource" grafana_loki_datasource
check "NetworkPolicy in demo and logging" networkpolicies
check "NetworkPolicy: default -> app blocked" blocked_from_default "http://hello.${APP_NS}.svc.cluster.local/"
check "NetworkPolicy: default -> Loki blocked" blocked_from_default http://loki.logging.svc.cluster.local:3100/ready

"$(dirname "$0")/mem-report.sh"
exit "${failed}"
