# MTS DevOps Hackathon

Однонодовый кластер Kubernetes, разворачиваемый одной командой на чистой Ubuntu 24.04.

## Требования

- Ubuntu 24.04 LTS, 2+ vCPU, 4+ ГБ RAM.
- Пользователь с правами sudo (не root).
- Доступ в интернет: apt, pkgs.k8s.io, get.helm.sh, Docker Hub, quay.io.

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
`Hello World!` и пишет запрос в access-лог.

После деплоя kubeconfig лежит в `~/.kube/config` у пользователя, запускавшего `make deploy`.

## Что ставится

| Компонент | Версия | Роль Ansible |
|---|---|---|
| containerd (`SystemdCgroup=true`) | из apt Ubuntu | `containerd` |
| kubelet / kubeadm / kubectl | 1.36.5 из pkgs.k8s.io | `kubernetes` |
| Calico (tigera-operator, VXLAN) | 3.33.0 | `cni` |
| local-path-provisioner (default SC) | 0.0.37 | `storage` |
| Helm | 3.22.0 | `kubernetes` |

| nginx (`nginxinc/nginx-unprivileged`) | 1.30.5-alpine | `app` |

Подготовка узла (swap, модули ядра, sysctl, пакеты) — роль `prereqs`.
Все версии закреплены в `ansible/group_vars/all.yml`.

С control-plane снят taint, поэтому нагрузка планируется на единственную ноду.

## Приложение

nginx в namespace `demo`: Deployment `hello` (2 реплики) и Service `hello` (порт 80).
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
{"time":"2026-10-03T18:00:00+00:00","remote_addr":"10.244.0.1","x_forwarded_for":"","host":"10.96.12.34","method":"GET","uri":"/","status":200,"bytes":13,"request_time":0.000,"user_agent":"curl/8.5.0"}
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
