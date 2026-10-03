# MTS DevOps Hackathon

Однонодовый кластер Kubernetes на kubeadm, который разворачивается одной командой на чистой
Ubuntu 24.04. В кластере работает nginx с ответом `Hello World!`, доступ к нему идёт через
Gateway API (Envoy Gateway) по HTTP и HTTPS на IP ноды. Метрики собирает Prometheus
(kube-prometheus-stack), логи приложения Fluentd отправляет в Loki, всё смотрится в Grafana.

Всё ставится Ansible-плейбуком: `deploy.sh` только создаёт venv с ansible-core и запускает
`ansible/site.yml` на локальной машине. Kubernetes-ресурсы руками не создаются.

## Содержание

- [Архитектура](#архитектура)
- [Технологии и версии](#технологии-и-версии)
- [Требования к среде](#требования-к-среде)
- [Развёртывание](#развёртывание)
- [Проверка](#проверка)
- [Приложение](#приложение)
- [Gateway API](#gateway-api)
- [Мониторинг](#мониторинг)
- [Логи](#логи)
- [CI/CD](#cicd)
- [Дополнительные возможности](#дополнительные-возможности)
- [Безопасность](#безопасность)
- [Известные ограничения](#известные-ограничения)
- [Структура репозитория](#структура-репозитория)

## Архитектура

```text
                      клиент (curl, браузер)
                               │  :80 / :443 на IP ноды
┌──────────────────────────────┼──────────────── Ubuntu 24.04, одна нода kubeadm ─┐
│                              ▼                                                  │
│  MetalLB (L2, пул = IP ноды) → Service LoadBalancer → Envoy Proxy               │
│                                                       (Envoy Gateway)           │
│              Gateway gateway/public: http :80, https :443 (TLS terminate)       │
│                 │                       │                         │             │
│     HTTPRoute demo/hello      HTTPRoute grafana         HTTPRoute prometheus    │
│      /v1  /v2  / 80:20        grafana.<ip>.nip.io       prometheus.<ip>.nip.io  │
│                 │                       │                (basic auth)           │
│                 ▼                       ▼                         ▼             │
│  ns demo: hello-v1 ×2, hello-v2 ×1   Grafana ◄──────────────── Prometheus       │
│   nginx + nginx-prometheus-exporter     ▲                     ▲  scrape:        │
│     │ stdout/stderr (JSON access-лог)   │ LogQL               │  exporter :9113,│
│     ▼                                   │                     │  Envoy, kubelet,│
│  /var/log/containers ──► Fluentd ──► Loki                     │  node-exporter… │
│                         (DaemonSet)  (ns logging)          (ns monitoring)      │
│                                                                                 │
│  containerd · Calico VXLAN · local-path-provisioner (PVC Prometheus и Loki)     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Путь запроса: клиент → IP ноды:80/443 → Envoy (Service типа LoadBalancer, адрес от MetalLB)
→ HTTPRoute → Service `hello-v1`/`hello-v2` → под nginx.

Кластер создаётся `kubeadm init` с конфигом
[`kubeadm.yaml.j2`](ansible/roles/kubernetes/templates/kubeadm.yaml.j2): pod CIDR
`10.244.0.0/16`, service CIDR `10.96.0.0/12`, CRI containerd, cgroup driver systemd. Taint с
control-plane снят, поэтому вся нагрузка работает на единственной ноде.

Порядок ролей в [`ansible/site.yml`](ansible/site.yml):

| Роль | Что делает |
|---|---|
| `prereqs` | swap off, модули `overlay`/`br_netfilter`, sysctl, пакеты |
| `containerd` | containerd из apt, `SystemdCgroup=true` |
| `kubernetes` | kubelet/kubeadm/kubectl из pkgs.k8s.io (hold), `kubeadm init`, kubeconfig, Helm |
| `cni` | Calico через tigera-operator, ждёт `Ready` ноды |
| `storage` | local-path-provisioner, StorageClass по умолчанию |
| `gateway` | MetalLB, Envoy Gateway с CRD Gateway API, TLS-сертификат, GatewayClass и Gateway |
| `monitoring` | kube-prometheus-stack, пароль Grafana/Prometheus, маршруты, дашборд |
| `logging` | Loki, Fluentd DaemonSet |
| `app` | namespace `demo`, nginx v1/v2, HTTPRoute, PodMonitor, PrometheusRule |

## Технологии и версии

| Компонент | Версия | Роль Ansible |
|---|---|---|
| Ubuntu | 24.04 LTS | — |
| ansible-core | 2.21.4 (в `.venv`, ставит `deploy.sh`) | — |
| containerd (`SystemdCgroup=true`) | из apt Ubuntu | `containerd` |
| **Kubernetes**: kubelet / kubeadm / kubectl | **1.36.5** из pkgs.k8s.io | `kubernetes` |
| Calico (tigera-operator, VXLAN) | 3.33.0 | `cni` |
| local-path-provisioner (default SC) | 0.0.37 | `storage` |
| Helm | 3.22.0 | `kubernetes` |
| MetalLB (L2, пул из IP ноды) | 0.16.1 | `gateway` |
| **Envoy Gateway** + CRD Gateway API v1.6 | **1.9.2** | `gateway` |
| kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics) | 91.9.0 | `monitoring` |
| Loki (чарт grafana-community/loki, Monolithic) | 18.13.7 (Loki 3.7.8) | `logging` |
| Fluentd (`grafana/fluent-plugin-loki`) | 3.7.8 | `logging` |
| nginx (`nginxinc/nginx-unprivileged`) | 1.30.5-alpine | `app` |
| nginx-prometheus-exporter | 1.5.3 | `app` |

Все версии закреплены в [`ansible/group_vars/all.yml`](ansible/group_vars/all.yml), версии
коллекций Ansible в [`ansible/requirements.yml`](ansible/requirements.yml). Все образы публичные,
собирать ничего не нужно.

Решение проверено на Ubuntu 24.04 в двух местах: на раннере GitHub Actions `ubuntu-24.04`
(job `e2e`, деплой дважды подряд) и на чистом VPS с Ubuntu 24.04 (4 ГБ RAM) от обычного
пользователя с sudo (job `cd`).

## Требования к среде

- Ubuntu 24.04 LTS, x86_64, 2+ vCPU, 4+ ГБ RAM, 20+ ГБ свободного диска.
- Пользователь с правами sudo (не root).
- Доступ в интернет: apt, pkgs.k8s.io, pypi.org, galaxy.ansible.com, get.helm.sh,
  raw.githubusercontent.com, metallb.github.io, prometheus-community.github.io, grafana-community.github.io, Docker Hub,
  quay.io.
- Свободные порты 80 и 443 на IP ноды.
- На машине не должно быть другого Kubernetes и CNI.

## Развёртывание

```bash
git clone https://github.com/patersss/mts_hackathon.git
cd mts_hackathon
make deploy
make verify
```

На минимальном образе Ubuntu может не быть `make`: `sudo apt-get install -y make` или
напрямую `./deploy.sh` и `./scripts/verify.sh`.

Что происходит при `make deploy`:

1. `deploy.sh` проверяет, что это Ubuntu 24.04, ставит `python3-venv`, создаёт `.venv` с
   ansible-core и ставит коллекции из `ansible/requirements.yml`.
2. Запускается `ansible/site.yml` на `localhost` (`ansible_connection=local`, повышение прав
   через sudo). Роли идут в порядке из таблицы выше.
3. Каждая роль ждёт готовности своих компонентов, поэтому после окончания плейбука кластер
   готов к проверке.

Деплой на 4-ядерной машине занимает около 10 минут. После него kubeconfig лежит в
`~/.kube/config` у пользователя, запускавшего `make deploy`, `kubectl` работает без sudo.

Повторный запуск безопасен: `kubeadm init` пропускается, если кластер уже есть, Helm-релизы
обновляются через `upgrade --install`, манифесты применяются `kubectl apply`, пароли и
сертификат не пересоздаются. Это проверяется в CI вторым деплоем и повторным `make verify`.

Остальные команды:

- `make verify` — smoke-тесты (см. ниже).
- `make lint` — shellcheck, yamllint, ansible-lint, те же проверки, что в CI (нужны
  установленные линтеры).
- `make destroy` — `kubeadm reset` и очистка узла.

## Проверка

### Автоматически

`make verify` выполняет 25 проверок и завершается с ненулевым кодом, если хоть одна упала:
нода `Ready` без DiskPressure и MemoryPressure, все поды `Running`, адреса подов из pod CIDR,
DNS внутри кластера, StorageClass по умолчанию, приложение отвечает `Hello World!` и пишет
запрос в access-лог, Gateway `Programmed` и получил IP ноды, HTTPRoute `Accepted`, HTTP и
HTTPS через Gateway отдают `Hello World!`, работают маршруты `/v1` и `/v2` и сплит v1/v2,
Prometheus видит target'ы приложения и Envoy в состоянии `up`, запрос
`nginx_http_requests_total` возвращает данные, Grafana и Prometheus открываются через Gateway,
запрос к приложению через Gateway находится в Loki LogQL-запросом, в Grafana подключён Loki.

```text
OK   node Ready
...
OK   app request found in Loki (LogQL)
OK   Grafana Loki datasource
```

### Вручную

Все команды выполняются на ноде после `make deploy`. Подробности по каждому компоненту в
разделах ниже.

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
D=${IP//./-}.nip.io

# приложение через Gateway API
curl http://$IP/                    # Hello World!
curl -k https://$IP/                # Hello World!

# мониторинг: target'ы приложения и запрос PromQL
P=$(kubectl -n monitoring get svc kps-prometheus -o jsonpath='{.spec.clusterIP}')
curl -s "http://$P:9090/api/v1/query" --data-urlencode 'query=up{job="demo/hello"}' | jq .data.result
curl -s "http://$P:9090/api/v1/query" --data-urlencode 'query=sum by (version) (nginx_http_requests_total)' | jq .data.result

# логи: запрос через Gateway и поиск его в Loki
curl -s http://$IP/check-$$ >/dev/null; sleep 10
L=$(kubectl -n logging get svc loki -o jsonpath='{.spec.clusterIP}')
curl -sG "http://$L:3100/loki/api/v1/query_range" --data-urlencode since=5m \
  --data-urlencode "query={namespace=\"demo\", container=\"nginx\"} |= \"/check-$$\"" |
  jq -r '.data.result[].values[][1]'

# Grafana в браузере: https://grafana.$D/ (сертификат самоподписанный), логин admin
kubectl -n monitoring get secret monitoring-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Приложение

nginx в namespace `demo` в двух версиях: Deployment `hello-v1` (2 реплики) и `hello-v2`
(1 реплика), у каждой свой Service, общий Service `hello` смотрит на обе.
Версии отличаются только заголовком `X-App-Version` и полем `version` в логе.
Конфиг из ConfigMap, контейнер не от root, файловая система только для чтения.
На любой путь отвечает `Hello World!`, `/healthz` используется пробами.

Access-лог пишется в stdout в JSON, по строке на запрос; error-лог в stderr.
Kubernetes сохраняет их в `/var/log/containers/`, оттуда их забирает Fluentd (см. «Логи»).

Проверка с ноды без Gateway:

```bash
curl http://$(kubectl -n demo get svc hello -o jsonpath='{.spec.clusterIP}')/
kubectl -n demo logs -l app=hello --tail=5
```

Пример строки лога:

```json
{"time":"2026-10-03T18:00:00+00:00","remote_addr":"10.244.0.1","x_forwarded_for":"","host":"10.96.12.34","method":"GET","uri":"/","status":200,"bytes":13,"request_time":0.000,"user_agent":"curl/8.5.0","version":"v1"}
```

## Gateway API

Реализация — **Envoy Gateway 1.9.2**, CRD Gateway API v1.6 (standard) ставятся его чартом.

Ресурсы Gateway API:

| Ресурс | Что делает |
|---|---|
| `GatewayClass eg` | контроллер `gateway.envoyproxy.io/gatewayclass-controller` |
| `Gateway gateway/public` | listener `http` на 80 и `https` на 443 (TLS terminate, Secret `gateway-tls`), маршруты из любых namespace |
| `HTTPRoute demo/hello` | `/v1` → `hello-v1`, `/v2` → `hello-v2`, остальное 80/20 между `hello-v1` и `hello-v2` |
| `HTTPRoute monitoring/grafana` | hostname `grafana.<ip>.nip.io` → Grafana, только HTTPS |
| `HTTPRoute monitoring/prometheus` | hostname `prometheus.<ip>.nip.io` → Prometheus, только HTTPS |
| `HTTPRoute monitoring/https-redirect` | HTTP → HTTPS (фильтр `RequestRedirect`, 301) для Grafana и Prometheus |

Кроме того, используется ресурс Envoy Gateway `SecurityPolicy` для basic auth на Prometheus.

Envoy публикуется Service типа LoadBalancer. MetalLB выдаёт ему IP самой ноды (пул из одного
адреса), поэтому Gateway доступен на `http://<IP ноды>/` и `https://<IP ноды>/` без NodePort.

TLS-сертификат самоподписанный, создаётся при первом деплое в `/etc/kubernetes/gateway-tls`
на `<IP ноды>`, `<ip-с-дефисами>.nip.io` и `*.<ip-с-дефисами>.nip.io`. В репозитории ключей нет.

Проверка:

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
kubectl get gatewayclass,gateway,httproute -A
curl http://$IP/
curl -k https://$IP/
curl -k https://hello.${IP//./-}.nip.io/
curl -sI http://$IP/v1 | grep -i x-app-version
curl -sI http://$IP/v2 | grep -i x-app-version
for i in $(seq 50); do curl -sI http://$IP/ | grep -i x-app-version; done | sort | uniq -c
curl -sI http://grafana.${IP//./-}.nip.io/ | head -3
```

Последний цикл показывает примерно 40 ответов v1 и 10 ответов v2, последняя команда — 301 на HTTPS.

## Мониторинг

kube-prometheus-stack (Helm) в namespace `monitoring`: Prometheus (хранение 3 дня, PVC 5 ГБ на
local-path), Grafana, node-exporter, kube-state-metrics. Alertmanager выключен.

Что собирается:

| Target (`job`) | Откуда | Что даёт |
|---|---|---|
| `demo/hello` | PodMonitor, sidecar nginx-prometheus-exporter в каждом поде (`:9113`, читает `stub_status` nginx) | запросы и соединения nginx |
| `envoy-gateway-system/envoy-proxy` | PodMonitor, Envoy (`:19001/stats/prometheus`) | запросы, коды ответов и задержки на Gateway |
| `envoy-gateway` | ServiceMonitor контроллера Envoy Gateway | состояние контроллера |
| `kubelet`, `node-exporter`, `kube-state-metrics`, `apiserver`, `coredns`, etcd, scheduler, controller-manager, kube-proxy | встроены в чарт | CPU/RAM подов и ноды, состояние объектов Kubernetes |

Чтобы target'ы etcd, scheduler, controller-manager и kube-proxy были доступны, в конфиге
kubeadm их метрики слушают не только localhost.

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
`Hello5xx` — больше 0.1 ответов 5xx в секунду через Gateway 5 минут. Видны в Prometheus на
странице Alerts.

Доступ через Gateway (HTTP перенаправляется на HTTPS):

- Grafana: `https://grafana.<ip-с-дефисами>.nip.io/`, дашборд **Hello app** (RPS по версиям,
  коды ответов, p50/p95, CPU и память подов, логи) плюс стандартные дашборды чарта.
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

Через Gateway:

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
PW=$(kubectl -n monitoring get secret monitoring-admin -o jsonpath='{.data.admin-password}' | base64 -d)
curl -sk -u "admin:$PW" "https://prometheus.${IP//./-}.nip.io/api/v1/query" --data-urlencode 'query=up{job="demo/hello"}' | jq .data.result
```

## Логи

Fluentd (DaemonSet в namespace `logging`) читает `/var/log/containers/*_demo_*.log` на ноде,
разбирает формат CRI и отправляет строки в Loki (`http://loki.logging.svc:3100`).
Позиции чтения и буфер лежат в `/var/lib/fluentd` на ноде, поэтому после перезапуска пода
логи не теряются и не дублируются. Конфиг: [`fluent.conf.j2`](ansible/roles/logging/templates/fluent.conf.j2).

Собираются access-лог (stdout, JSON) и error-лог (stderr, уровень `warn`) nginx, а также лог экспортера.
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

Проверка с ноды: запрос с уникальным путём через Gateway, затем поиск в Loki.

```bash
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
curl -s http://$IP/my-test-request
sleep 10
L=$(kubectl -n logging get svc loki -o jsonpath='{.spec.clusterIP}')
curl -sG "http://$L:3100/loki/api/v1/query_range" --data-urlencode since=5m \
  --data-urlencode 'query={namespace="demo", container="nginx"} |= "/my-test-request" | json' |
  jq -r '.data.result[].values[][1]'
```

## CI/CD

Workflow в [`.github/workflows`](.github/workflows):

- `lint` (push в `main`, PR) — shellcheck, yamllint, ansible-lint и gitleaks (поиск секретов).
- `e2e` (push в `main`, PR) — на чистом раннере `ubuntu-24.04`: `make deploy` → `make verify`
  → повторный `make deploy` → `make verify`. Второй проход проверяет идемпотентность.
  При падении выводит состояние кластера и логи компонентов.
- `cd` (push в `main`, вручную через `workflow_dispatch`) — раскатка на VPS. Под root
  создаётся пользователь `deploy` с sudo ([`ansible/vps-user.yml`](ansible/vps-user.yml)),
  дальше всё от него: копия репозитория, `./deploy.sh`, `./scripts/verify.sh`, проверка
  `Hello World!` снаружи по HTTP и HTTPS. Нужны секреты репозитория `VPS_HOST` и
  `VPS_SSH_KEY` (приватный ключ, публичная часть в `/root/.ssh/authorized_keys` на VPS).
  Для проверки решения эти секреты не нужны.

## Дополнительные возможности

Gateway API:

- несколько маршрутов и backend'ов: приложение, Grafana, Prometheus;
- маршрутизация по path (`/v1`, `/v2`) и по hostname (`grafana.*`, `prometheus.*` через nip.io);
- traffic splitting 80/20 между версиями приложения;
- TLS terminate на Gateway, HTTP → HTTPS redirect фильтром `RequestRedirect`;
- basic auth на Prometheus через `SecurityPolicy` Envoy Gateway;
- Gateway на портах 80/443 IP ноды через MetalLB, без NodePort.

Мониторинг и логирование:

- HTTP-метрики приложения (количество запросов по версиям, соединения) и Gateway (коды ответов,
  latency p50/p95), CPU/RAM подов и ноды;
- дашборд Grafana **Hello app** из ConfigMap: RPS, коды ответов, задержки, CPU/RAM, логи;
- алерты `HelloDown` и `Hello5xx`;
- централизованное хранение логов в Loki с поиском LogQL и просмотром в Grafana;
- метрики control-plane (etcd, scheduler, controller-manager, kube-proxy).

Автоматизация и CI/CD:

- деплой одной командой, только Ansible и Helm, все версии закреплены;
- 25 smoke-тестов в `make verify`;
- CI: линтеры, gitleaks, e2e с двойным деплоем на чистой Ubuntu 24.04;
- CD на VPS от непривилегированного пользователя с sudo.

Надёжность: readiness/liveness-пробы, requests/limits, PodDisruptionBudget, две реплики v1,
PVC для Prometheus и Loki, буфер Fluentd на диске.

## Безопасность

- В репозитории нет паролей, ключей и сертификатов. Пароль Grafana/Prometheus (Secret
  `monitoring/monitoring-admin`) и TLS-сертификат генерируются при первом деплое и при
  повторном не меняются. gitleaks в CI ищет секреты на каждом push и PR.
- Namespace `demo` с Pod Security `restricted`: поды не от root, `readOnlyRootFilesystem`,
  `drop: [ALL]`, `seccompProfile: RuntimeDefault`, без токена ServiceAccount.
- Prometheus наружу только по HTTPS и с basic auth; Grafana только по HTTPS с логином.
- Пакеты Kubernetes зафиксированы через `apt-mark hold`, чтобы `apt upgrade` не обновил их
  случайно.

## Известные ограничения

- Одна нода: нет отказоустойчивости control-plane и данных, PodDisruptionBudget защищает только
  от добровольного вытеснения.
- Только x86_64 (бинарь Helm скачивается для `linux-amd64`).
- Нужен доступ в интернет к репозиториям пакетов, чартов и образов, офлайн-установка не
  поддерживается.
- Сертификат самоподписанный: в браузере будет предупреждение, в curl нужен `-k`.
- Имена `*.nip.io` строятся из IP интерфейса с маршрутом по умолчанию. Если нода за NAT
  (облако с приватным IP), снаружи эти имена не откроются; тогда нужен `curl --resolve` или
  заголовок `Host`, а приложение по-прежнему доступно по публичному IP.
- Gateway занимает порты 80 и 443 IP ноды.
- Смена IP ноды после деплоя не поддерживается: адрес вшит в сертификаты kubeadm и Gateway,
  нужно `make destroy` и `make deploy`.
- Данные Prometheus и Loki лежат на диске ноды (local-path), без репликации и бэкапов.
  Для Loki срок хранения не задан, место ограничено PVC 5 ГБ.
- Alertmanager выключен: алерты видны в Prometheus, но никуда не отправляются.
- Fluentd собирает логи только namespace `demo`.
- NetworkPolicy не настроены.

## Структура репозитория

```text
├── deploy.sh                 # venv с ansible-core и запуск ansible/site.yml
├── Makefile                  # deploy, verify, lint, destroy
├── ansible/
│   ├── site.yml              # роли по порядку
│   ├── destroy.yml           # kubeadm reset и очистка
│   ├── vps-user.yml          # sudo-пользователь для CD
│   ├── group_vars/all.yml    # версии и параметры
│   └── roles/                # prereqs, containerd, kubernetes, cni, storage,
│                             # gateway, monitoring, logging, app
├── scripts/verify.sh         # smoke-тесты
└── .github/workflows/        # lint, e2e, cd
```
