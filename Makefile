# Usage: make bootstrap BUCKET=my-unique-tfstate-bucket
#        make init BUCKET=my-unique-tfstate-bucket
#        make plan | apply | test | destroy
BUCKET ?=
REGION ?= eu-north-1
ENV    := envs/dev

.PHONY: check fmt validate scan test-modules bootstrap init plan apply test demo-alarm destroy

check: fmt validate scan test-modules   ## everything CI runs, no AWS needed

fmt:
	terraform fmt -check -recursive

validate:
	cd bootstrap && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd $(ENV) && terraform init -backend=false -input=false >/dev/null && terraform validate

scan:
	checkov -d . --quiet --compact

test-modules:      ## offline `terraform test` for each module, AWS provider mocked
	for m in network bastion app; do (cd modules/$$m && terraform init -backend=false -input=false >/dev/null && terraform test) || exit 1; done

bootstrap:
	@test -n "$(BUCKET)" || (echo "set BUCKET=<globally unique name>"; exit 1)
	cd bootstrap && terraform init -input=false && terraform apply -var bucket_name=$(BUCKET) -var region=$(REGION)

init:
	@test -n "$(BUCKET)" || (echo "set BUCKET=<same bucket as bootstrap>"; exit 1)
	cd $(ENV) && terraform init -input=false -reconfigure -backend-config="bucket=$(BUCKET)" -backend-config="region=$(REGION)"

plan:
	cd $(ENV) && terraform plan -out=tfplan

apply:
	cd $(ENV) && terraform apply tfplan

test:
	./scripts/verify.sh

demo-alarm:        ## break every web instance and watch the alarms fire and clear (needs the stack up)
	./scripts/demo-alarm.sh

destroy:
	cd $(ENV) && terraform destroy
