.PHONY: deploy verify lint destroy

deploy:
	./deploy.sh

verify:
	./scripts/verify.sh

lint:
	shellcheck deploy.sh scripts/*.sh
	yamllint .
	ansible-lint ansible/site.yml ansible/vps-user.yml

destroy:
	.venv/bin/ansible-playbook ansible/destroy.yml
