.PHONY: help fmt fmt-check validate lint init plan apply destroy clean

help:
	@echo "Targets:"
	@echo "  make fmt        Format all Terraform files (in-place)"
	@echo "  make fmt-check  Check formatting without modifying files (for CI)"
	@echo "  make validate   Validate all Terraform files"
	@echo "  make lint       Run checkov (Terraform)"
	@echo "  make init       Initialize the working directory"
	@echo "  make plan       Plan (writes tfplan)"
	@echo "  make apply      Apply the saved plan"
	@echo "  make destroy    Destroy all managed infrastructure"
	@echo "  make clean      Remove .terraform/ and tfplan files"

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

validate:
	@for d in $$(find . -type f -name '*.tf' -not -path '*/.*' -exec dirname {} \; | sort -u); do \
		echo "==> $$d"; \
		(cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; \
	done

lint:
	checkov -d . --framework terraform --quiet --compact

init:
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text) && \
	BUCKET="itba-tp-fraud-tfstate-$${ACCOUNT_ID}" && \
	(aws s3api head-bucket --bucket "$${BUCKET}" 2>/dev/null || \
	  aws s3api create-bucket --bucket "$${BUCKET}" --region us-east-1) && \
	aws s3api put-bucket-versioning \
	  --bucket "$${BUCKET}" \
	  --versioning-configuration Status=Enabled && \
	terraform init -migrate-state -force-copy -backend-config="bucket=$${BUCKET}"

plan:
	terraform plan -out=tfplan

apply:
	terraform apply tfplan

destroy:
	terraform destroy

clean:
	find . -type d -name ".terraform" -exec rm -rf {} +
	find . -type f -name "tfplan" -delete
