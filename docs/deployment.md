# Deployment Guide

End-to-end from a clean AWS account to a public URL.

## 0. Prerequisites

- AWS account + admin IAM user for bootstrap
- Tools: `aws` ≥2.15, `terraform` ≥1.6, `kubectl` ≥1.30, `helm` ≥3.14, `docker` ≥24
- GitHub repository with this code pushed to `main`

## 1. Local sanity check

```bash
docker compose up --build
open http://localhost:3000    # client (matches result.png)
curl  http://localhost:5050/healthcheck/
```

Stop with `docker compose down`.

## 2. Provision infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit: region, cluster_name, alert_email, github_repo (owner/repo)

terraform init
terraform apply
```

Approve the SNS email confirmation that arrives in your inbox.

Outputs include:

```
cluster_name           = mern-eks
ecr_repository_urls    = { mern-client = ..., mern-server = ..., python-etl = ... }
gha_deployer_role_arn  = arn:aws:iam::...:role/mern-eks-gha-deployer
sns_alarm_topic_arn    = arn:aws:sns:...:mern-eks-alarms
kubeconfig_command     = aws eks update-kubeconfig --region ... --name ...
```

## 3. Configure GitHub

In repo settings → Secrets and variables → Actions:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | `gha_deployer_role_arn` output |
| Variable | `AWS_REGION` | e.g. `eu-central-1` |
| Variable | `EKS_CLUSTER_NAME` | `mern-eks` |

## 4. First deployment

Trigger by pushing to `main` (or run `Build and Push` from the Actions tab manually).

The pipeline:

1. Builds three images, pushes to ECR.
2. Calls `deploy.yml` which:
   - Updates kubeconfig.
   - Renders `PLACEHOLDER_ECR/...:latest` → `<ecr-registry>/<repo>:<sha>` in `k8s/*.yaml`.
   - Creates `mongo-secret` if missing.
   - `kubectl apply -k k8s/`.
   - Waits for rollout.

## 5. Verify

```bash
aws eks update-kubeconfig --region <region> --name <cluster_name>

kubectl -n mern get pods,svc,ingress,cronjob
# Wait until Ingress ADDRESS is populated (60–120s after first apply).

ALB=$(kubectl -n mern get ingress mern -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"

curl "http://$ALB/healthcheck/"
curl "http://$ALB/record/"
```

Open `http://$ALB` in a browser — page must match `result.png`.

## 6. ETL verification

```bash
# Trigger an immediate run instead of waiting for the top of the hour:
kubectl -n mern create job --from=cronjob/etl etl-manual-$(date +%s)
kubectl -n mern logs -l app=etl --tail=20
```

Expected output: `<Response [200]>` and the GitHub root API JSON.

## 7. Tear down

```bash
cd terraform
terraform destroy
```

ECR repos with images will block destroy — `aws ecr delete-repository --force` first if needed.

## Next steps (out of scope here)

- ACM certificate + `alb.ingress.kubernetes.io/listen-ports` `HTTPS:443`.
- Route53 alias from a custom domain to the ALB.
- Mongo replica set + backups (e.g. Percona Operator).
- WAF + Shield on the ALB.
