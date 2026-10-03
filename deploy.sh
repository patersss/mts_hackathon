#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ANSIBLE_CORE_VERSION=2.21.4

# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
  echo "Нужна Ubuntu 24.04, найдено: ${PRETTY_NAME}" >&2
  exit 1
fi

if [[ ! -x .venv/bin/ansible-playbook ]]; then
  sudo apt-get update -q
  sudo apt-get install -y -q python3-venv
  python3 -m venv .venv
  .venv/bin/pip install -q "ansible-core==${ANSIBLE_CORE_VERSION}"
fi

.venv/bin/ansible-galaxy collection install -r ansible/requirements.yml >/dev/null
.venv/bin/ansible-playbook ansible/site.yml "$@"
