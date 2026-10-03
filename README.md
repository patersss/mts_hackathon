# MTS DevOps Hackathon

Однонодовый кластер Kubernetes, разворачиваемый одной командой на чистой Ubuntu 24.04.

## Требования

- Ubuntu 24.04 LTS, 2+ vCPU, 4+ ГБ RAM.
- Пользователь с правами sudo (не root).
- Доступ в интернет: apt, pkgs.k8s.io, get.helm.sh, metallb.github.io, Docker Hub, quay.io.
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
по HTTP и HTTPS, работают маршрутизация по path и разделение трафика v1/v2.

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
| nginx (`nginxinc/nginx-unprivileged`) | 1.30.5-alpine | `app` |

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
Kubernetes сохраняет их в `/var/log/containers/`, откуда их заберёт сборщик логов.

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

## Команды

- `make deploy` — развернуть или обновить кластер.
- `make verify` — smoke-тесты.
- `make lint` — shellcheck, yamllint, ansible-lint (те же проверки, что в CI).
- `make destroy` — `kubeadm reset` и очистка узла.

## CI

- `lint` — линтеры и gitleaks.
- `e2e` — на раннере `ubuntu-24.04`: `make deploy` → `make verify` → повторный `make deploy`
  → `make verify`. Второй проход проверяет идемпотентность.
