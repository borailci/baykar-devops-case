# Runbook

## Health checks

```bash
kubectl -n mern get pods,svc,ingress,hpa,cronjob
kubectl -n mern get events --sort-by=.lastTimestamp | tail -30
ALB=$(kubectl -n mern get ingress mern -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -fsS http://$ALB/healthcheck/
```

## Logs

App logs ship to CloudWatch.

```bash
aws logs tail /eks/mern-eks/mern --since 10m --follow
# or per-pod live:
kubectl -n mern logs -l app=server -f --tail=100
kubectl -n mern logs -l app=client -f --tail=100
```

ETL run history:

```bash
kubectl -n mern get jobs --sort-by=.metadata.creationTimestamp
kubectl -n mern logs job/<job-name>
```

## Rollback

```bash
kubectl -n mern rollout undo deployment/server
kubectl -n mern rollout undo deployment/client
kubectl -n mern rollout status deployment/server
```

To pin a previous tag explicitly:

```bash
kubectl -n mern set image deployment/server server=<ecr>/mern-server:<old-sha>
```

## Scaling

Server scales automatically via HPA (CPU 70%, 2–6 replicas). Manual override:

```bash
kubectl -n mern scale deployment/server --replicas=4
```

Node group scales via EKS-managed ASG (Terraform vars `node_min_size`, `node_max_size`).

## Alerts

Configured in `terraform/observability.tf`:

| Alarm | Trigger | Notification |
|---|---|---|
| `mern-eks-alb-5xx` | ALB 5xx sum > 5 in 2× 60s | SNS → email |
| `mern-eks-pod-restarts` | Pod restart count > 3 in 5m | SNS → email |

The email subscription is created by Terraform from `var.alert_email`. After `terraform apply`, confirm the AWS SNS subscription email (subject "AWS Notification - Subscription Confirmation"). To add extra subscribers afterwards:

```bash
aws sns subscribe \
  --topic-arn "$(terraform -chdir=terraform output -raw sns_alarm_topic_arn)" \
  --protocol email --notification-endpoint user@example.com
```

## Mongo data access

```bash
kubectl -n mern exec -it mongo-0 -- mongosh sample_training
# Inside: show collections; db.records.find()
```

## Rotating mongo credentials

```bash
kubectl -n mern delete secret mongo-secret
kubectl -n mern create secret generic mongo-secret \
  --from-literal=ATLAS_URI='mongodb://mongo.mern.svc.cluster.local:27017/sample_training'
kubectl -n mern rollout restart deployment/server
```

## Failed CronJob

```bash
kubectl -n mern get jobs -l app=etl
kubectl -n mern describe cronjob etl
kubectl -n mern logs job/<failed-job>
# Manual re-run:
kubectl -n mern create job --from=cronjob/etl etl-manual-$(date +%s)
```

## Bootstrap IAM (replace AdministratorAccess after demo)

During initial bootstrap the operator IAM user was granted `AdministratorAccess` to unblock `terraform apply`. After tearing the stack down (`terraform destroy`), narrow the user to the bundled starter policy:

```bash
aws iam detach-user-policy \
  --user-name <operator> \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam put-user-policy \
  --user-name <operator> \
  --policy-name mern-eks-bootstrap \
  --policy-document file://docs/minimal-iam-policy.json
```

The policy at [`docs/minimal-iam-policy.json`](minimal-iam-policy.json) covers EKS, VPC + EC2, IAM (scoped to `mern-eks-*` role names and the two OIDC providers), ECR (scoped to `mern-*` and `python-*` repos), KMS, CloudWatch Logs + Alarms, SNS (scoped to `mern-eks-*` topics), and the Terraform S3/DynamoDB backend. It is intentionally a starter — if a fresh `terraform apply` fails on a missing action, add the action to the relevant statement rather than re-attaching `AdministratorAccess`.

## Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `Ingress` has no `ADDRESS` | ALB controller not running or IRSA mis-mapped | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Server `CrashLoopBackOff` reading Mongo | `mongo-secret` missing | recreate secret, see deployment.md §4 |
| Mongo Pending | gp3 StorageClass not created, or EBS CSI controller IRSA misconfigured | `terraform apply` to ensure `kubernetes_storage_class.gp3` exists; verify `aws-ebs-csi-driver` addon shows `service_account_role_arn` |
| EBS CSI controller `CrashLoopBackOff` (`ec2:DescribeAvailabilityZones` denied) | Old install used node role instead of IRSA | `kubectl -n kube-system rollout restart deploy/ebs-csi-controller` after Terraform sets the addon role |
| CronJob shows `Suspend` | `concurrencyPolicy: Forbid` + prior job stuck | delete the stuck job: `kubectl -n mern delete job <name>` |
| Fluent Bit pods log `AccessDeniedException` on `CreateLogStream` | Node role lacks CloudWatch write permissions | `aws iam attach-role-policy --role-name <node-role> --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy`, then `kubectl -n amazon-cloudwatch rollout restart ds/aws-for-fluent-bit` |
