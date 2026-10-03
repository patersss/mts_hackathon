# MTS DevOps Hackathon

Однонодовый кластер Kubernetes, разворачиваемый одной командой на чистой Ubuntu 24.04.

## Требования

- Ubuntu 24.04 LTS, 2+ vCPU, 4+ ГБ RAM.
- Пользователь с правами sudo (не root).
- Доступ в интернет: apt, pkgs.k8s.io, get.helm.sh, metallb.github.io, prometheus-community.github.io,
  grafana-community.github.io, Docker Hub, quay.io.
- Свободные порты 80 и 443 на IP ноды.

## Развёртывание

```bash
git clone https://github.com/patersss/mts_hackathon.git
cd mts_hackathon
make deploy
make verify
```

`make deploy` ставит в `.venv` ansible-core, нужные коллекции и запускает `ansible/site.yml`
локально (`ansible_connection=local`). Повторный запуск не ломает существующий кластер:
`kubeadm init` пропускается, манифесты применяются через `kubectl apply`.

`make verify` — smoke-тесты: нода `Ready`, все поды в рабочем состоянии, адреса подов из
pod CIDR, работает DNS внутри кластера, есть StorageClass по умолчанию, приложение отвечает
`Hello World!` и пишет запрос в access-лог, Gateway получил IP ноды и отдаёт `Hello World!`
по HTTP и HTTPS, работают маршрутизация по path и разделение трафика v1/v2, Prometheus
видит target'ы приложения и Envoy в состоянии `up`, запрос `nginx_http_requests_total`
возвращает данные, Grafana и Prometheus открываются через Gateway, запрос к приложению
через Gateway находится в Loki LogQL-запросом, в Grafana подключён источник Loki.

После деплоя kubeconfig лежит в `~/.kube/config` у пользователя, запускавшего `make deploy`.

## Что ставится

| Компонент | Версия | Роль Ansible |
|---|---|---|
| containerd (`SystemdCgroup=true`) | из apt Ubuntu | `containerd` |
| kubelet / kubeadm / kubectl | 1.36.5 из pkgs.k8s.io | `kubernetes` |
| Calico (tigera-operator, VXLAN) | 3.33.0 | `cni` |
| local-path-provisioner (default SC) | 0.0.37 | `storage` |
| Helm | 3.22.0 | `kubernetes` |
| MetalLB (L2, пул из IP ноды) | 0.16.1 | `gateway` |
| Envoy Gateway + CRD Gateway API v1.6 | 1.9.2 | `gateway` |
| kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics) | 91.9.0 | `monitoring` |
| Loki (чарт grafana-community/loki, Monolithic) | 18.13.7 (Loki 3.7.8) | `logging` |
| Fluentd (`grafana/fluent-plugin-loki`) | 3.7.8 | `logging` |
| nginx (`nginxinc/nginx-unprivileged`) | 1.30.5-alpine | `app` |
| nginx-prometheus-exporter | 1.5.3 | `app` |

Подготовка узла (swap, модули ядра, sysctl, пакеты) — роль `prereqs`.
Все версии закреплены в `ansible/group_vars/all.yml`.

С control-plane снят taint, поэтому нагрузка планируется на единственную ноду.

## Приложение

nginx в namespace `demo` в двух версиях: Deployment `hello-v1` (2 реплики) и `hello-v2`
(1 реплика), у каждой свой Service, общий Service `hello` смотрит на обе.
Версии отличаются только заголовком `X-App-Version` и полем `version` в логе.
Конфиг из ConfigMap, контейнер не от root, файловая система только для чтения.
На любой путь отвечает `Hello World!`, `/healthz` используется пробами.

Access-лог пишется в stdout в JSON, по строке на запрос; error-лог в stderr.
Kubernetes сохраняет их в `/var/log/containers/`, оттуда их забирает Fluentd (см. «Логи»).

Проверка с ноды:

```bash
curl http://$(kubectl -n demo get svc hello -o jsonpath='{.spec.clusterIP}')/
kubectl -n demo logs -l app=hello --tail=5
```

Пример строки лога:

```json
{"time":"2026-10-03T18:00:00+00:00","remote_addr":"10.244.0.1","x_forwarded_for":"","host":"10.96.12.34","method":"GET","uri":"/","status":200,"bytes":13,"request_time":0.000,"user_agent":"curl/8.5.0","version":"v1"}
```

## Gateway API

Реализация — Envoy Gateway, CRD Gateway API ставятся его чартом.

- `GatewayClass eg` → контроллер `gateway.envoyproxy.io/gatewayclass-controller`.
- `Gateway gateway/public`: listener `http` на 80 и `https` на 443 (TLS terminate,
  Secret `gateway-tls`).
- `HTTPRoute demo/hello`: `/v1` → `hello-v1`, `/v2` → `hello-v2`, остальное делится
  80/20 между `hello-v1` и `hello-v2`.

Envoy публикуется Service типа LoadBalancer. MetalLB выдаёт ему IP самой ноды (пул из одного
адреса), поэтому Gateway доступен на `http://<IP ноды>/` и `https://<IP ноды>/` без NodePort.

TLS-сертификат самоподписанный, создаётся при первом деплое в `/etc/kubernetes/gateway-tls`
на `<IP ноды>`, `<ip-с-дефисами>.nip.io` и `*.<ip-с-дефисами>.nip.io`. В репозитории ключей нет.

Проверка:

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
curl http://$IP/
curl -k https://$IP/
curl -k https://hello.${IP//./-}.nip.io/
curl -sI http://$IP/v2 | grep -i x-app-version
for i in $(seq 20); do curl -sI http://$IP/ | grep -i x-app-version; done | sort | uniq -c
```

## Мониторинг

kube-prometheus-stack в namespace `monitoring`: Prometheus (хранение 3 дня, PVC 5 ГБ на
local-path), Grafana, node-exporter, kube-state-metrics. Alertmanager выключен.

Что собирается:

| Target (`job`) | Откуда | Что даёт |
|---|---|---|
| `demo/hello` | PodMonitor, sidecar nginx-prometheus-exporter в каждом поде (`:9113`, читает `stub_status` nginx) | запросы и соединения nginx |
| `envoy-gateway-system/envoy-proxy` | PodMonitor, Envoy (`:19001/stats/prometheus`) | запросы, коды ответов и задержки на Gateway |
| `envoy-gateway` | ServiceMonitor контроллера Envoy Gateway | состояние контроллера |
| `kubelet`, `node-exporter`, `kube-state-metrics`, `apiserver`, `coredns`, etcd, scheduler, controller-manager, kube-proxy | встроены в чарт | CPU/RAM подов и ноды, состояние объектов Kubernetes |

Основные метрики приложения:

| Метрика | Тип | Смысл |
|---|---|---|
| `up{job="demo/hello"}` | gauge | 1, если Prometheus смог опросить экспортер пода |
| `nginx_up` | gauge | 1, если экспортер достучался до `stub_status` nginx |
| `nginx_http_requests_total` | counter | всего обработано HTTP-запросов, метка `version` = v1/v2 |
| `nginx_connections_active` | gauge | открытые клиентские соединения |
| `nginx_connections_accepted`, `nginx_connections_handled` | counter | принятые и обработанные соединения; разница — отброшенные |
| `envoy_cluster_upstream_rq_xx{envoy_response_code_class}` | counter | ответы приложения через Gateway по классам кодов (2xx, 5xx) |
| `envoy_cluster_upstream_rq_time_bucket` | histogram | время ответа приложения через Gateway, мс |
| `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes` | counter / gauge | CPU и память контейнеров |

Примеры запросов:

```promql
up{job="demo/hello"}
sum by (version) (rate(nginx_http_requests_total[1m]))
sum by (envoy_response_code_class) (rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/demo/hello/.*"}[5m]))
histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/demo/hello/.*"}[5m])))
```

Алерты (PrometheusRule `demo/hello`): `HelloDown` — нет ни одного живого экспортера 2 минуты,
`Hello5xx` — больше 0.1 ответов 5xx в секунду через Gateway 5 минут.

Доступ через Gateway (HTTP перенаправляется на HTTPS):

- Grafana: `https://grafana.<ip-с-дефисами>.nip.io/`, дашборд **Hello app** (RPS по версиям,
  коды ответов, p50/p95, CPU и память подов) плюс стандартные дашборды чарта.
- Prometheus: `https://prometheus.<ip-с-дефисами>.nip.io/`, basic auth.

Логин `admin`, пароль генерируется при первом деплое и хранится только в кластере:

```bash
kubectl -n monitoring get secret monitoring-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Проверка с ноды без Gateway:

```bash
P=$(kubectl -n monitoring get svc kps-prometheus -o jsonpath='{.spec.clusterIP}')
curl -s "http://$P:9090/api/v1/targets?state=active" | jq '.data.activeTargets[] | select(.labels.namespace=="demo") | {pod: .labels.pod, health}'
curl -s "http://$P:9090/api/v1/query" --data-urlencode 'query=sum by (version) (nginx_http_requests_total)' | jq .data.result
```

## Логи

Fluentd (DaemonSet в namespace `logging`) читает `/var/log/containers/*_demo_*.log` на ноде,
разбирает формат CRI и отправляет строки в Loki (`http://loki.logging.svc:3100`).
Позиции чтения и буфер лежат в `/var/lib/fluentd` на ноде, поэтому после перезапуска пода
логи не теряются и не дублируются.

Метки потока в Loki: `namespace`, `workload` (`hello-v1`/`hello-v2`), `pod`, `container`
(`nginx` или `exporter`), `stream` (`stdout` — access-лог, `stderr` — error-лог), `job="fluentd"`.
Сама строка остаётся JSON access-лога nginx, поля достаются в запросе через `| json`.

Loki в режиме Monolithic (один под), хранение на файловой системе, PVC 5 ГБ на local-path.
В Grafana источник `Loki` добавлен автоматически, на дашборде **Hello app** есть панель логов;
произвольные запросы — в Explore.

Примеры LogQL:

```logql
{namespace="demo", container="nginx", stream="stdout"}
{namespace="demo", container="nginx"} | json | status >= 400
{namespace="demo", container="nginx", stream="stderr"}
sum by (workload) (count_over_time({namespace="demo", container="nginx", stream="stdout"}[5m]))
```

Проверка с ноды:

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
curl -s http://$IP/my-test-request
L=$(kubectl -n logging get svc loki -o jsonpath='{.spec.clusterIP}')
curl -sG "http://$L:3100/loki/api/v1/query_range" --data-urlencode since=5m \
  --data-urlencode 'query={namespace="demo", container="nginx"} |= "/my-test-request" | json' |
  jq -r '.data.result[].values[][1]'
```

## Команды

- `make deploy` — развернуть или обновить кластер.
- `make verify` — smoke-тесты.
- `make lint` — shellcheck, yamllint, ansible-lint (те же проверки, что в CI).
- `make destroy` — `kubeadm reset` и очистка узла.

## CI

- `lint` — линтеры и gitleaks.
- `e2e` — на раннере `ubuntu-24.04`: `make deploy` → `make verify` → повторный `make deploy`
  → `make verify`. Второй проход проверяет идемпотентность.
