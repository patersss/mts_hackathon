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
pod CIDR, работает DNS внутри кластера, есть StorageClass по умолчанию.

После деплоя kubeconfig лежит в `~/.kube/config` у пользователя, запускавшего `make deploy`.

## Что ставится

| Компонент | Версия | Роль Ansible |
|---|---|---|
| containerd (`SystemdCgroup=true`) | из apt Ubuntu | `containerd` |
| kubelet / kubeadm / kubectl | 1.36.5 из pkgs.k8s.io | `kubernetes` |
| Calico (tigera-operator, VXLAN) | 3.33.0 | `cni` |
| local-path-provisioner (default SC) | 0.0.37 | `storage` |
| Helm | 3.22.0 | `kubernetes` |

Подготовка узла (swap, модули ядра, sysctl, пакеты) — роль `prereqs`.
Все версии закреплены в `ansible/group_vars/all.yml`.

С control-plane снят taint, поэтому нагрузка планируется на единственную ноду.

## Команды

- `make deploy` — развернуть или обновить кластер.
- `make verify` — smoke-тесты.
- `make lint` — shellcheck, yamllint, ansible-lint (те же проверки, что в CI).
- `make destroy` — `kubeadm reset` и очистка узла.

## CI

- `lint` — линтеры и gitleaks.
- `e2e` — на раннере `ubuntu-24.04`: `make deploy` → `make verify` → повторный `make deploy`
  → `make verify`. Второй проход проверяет идемпотентность.
