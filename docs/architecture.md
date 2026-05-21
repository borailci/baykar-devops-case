# Architecture

## Overview

Two workloads delivered side by side on a single AWS EKS cluster:

1. **MERN stack** — React client, Express API, MongoDB.
2. **Python ETL** — `ETL.py` runs hourly to fetch the GitHub API.

All traffic enters through an AWS Application Load Balancer provisioned by the AWS Load Balancer Controller, routed by path:

```
                Internet
                   │
                   ▼
            AWS ALB (Ingress)
            ├─ /record/*       → server:5050
            ├─ /healthcheck/*  → server:5050
            └─ /*              → client:80 (nginx serving React build)

             ┌────────────────────────────────┐
             │  Namespace: mern               │
             │                                │
             │  Deployment: client (×2)       │
             │  Deployment: server (×2, HPA)  │
             │  StatefulSet: mongo (×1, PVC)  │
             │  CronJob: etl (0 * * * *)      │
             │  Secret: mongo-secret          │
             └────────────────────────────────┘

  Observability:
    Fluent Bit DaemonSet (kube-system) → CloudWatch Logs /eks/mern-eks/mern
    CloudWatch Alarms (ALB 5xx, pod restarts) → SNS topic → email
```

## Components

| Component | Image base | Replicas | Exposed |
|---|---|---|---|
| client | `nginx:1.27-alpine` (multi-stage from `node:20-alpine`) | 2 | ALB `/` |
| server | `node:20-alpine` | 2 (HPA 2–6) | ALB `/record`, `/healthcheck` |
| mongo  | `mongo:7` | 1 (StatefulSet + 10Gi gp3 PVC) | ClusterIP only |
| etl    | `python:3.12-slim` | CronJob hourly | none |

## Networking

- VPC: `/16` across 3 AZs, public + private subnets, one NAT gateway.
- EKS managed node group runs in private subnets; ALB lives in public subnets.
- Pod-to-pod: SecurityGroup default; Mongo only reachable in-cluster.

## CI/CD

GitHub Actions, three workflows:

1. `ci.yml` — PR + push to main: lint, build, Cypress e2e against `docker compose`.
2. `build-and-push.yml` — main only: matrix build (client/server/etl) → ECR, OIDC auth.
3. `deploy.yml` — called by build: `kubectl apply -k k8s/` + rollout watch.

No static AWS keys in GitHub. The `aws-iam-openid-connect-provider` in `terraform/iam.tf` lets Actions assume `gha-deployer` via OIDC.

## Security baseline

- Server runs as non-root (UID 1000) with all capabilities dropped; `readOnlyRootFilesystem: false` (server reads `config.env` via dotenv at boot — tightening to `true` with an `emptyDir /tmp` is tracked as a polish item).
- Client image is stock `nginx:1.27-alpine`; requires `CAP_CHOWN` so the `drop: ["ALL"]` set is intentionally not applied. Migrating to `nginxinc/nginx-unprivileged` is a polish item.
- ETL container runs as non-root, drops all capabilities.
- Secrets via `kubectl create secret`; not committed.
- ECR `scan_on_push = true`; lifecycle keeps last 10 images.
- IRSA for the ALB controller **and** the AWS EBS CSI driver (mongo PVC).
- GitHub Actions assumes the `gha-deployer` role via OIDC. The role is granted cluster-admin through an **EKS access entry** + access policy association (`AmazonEKSClusterAdminPolicy`); the legacy `aws-auth` ConfigMap is not touched.
- TLS termination via ACM cert on ALB — **NOT** included; listed under out-of-scope (documented in deployment.md as next step).

## Known limitations

- Single Mongo replica. Production needs a replica set + backup strategy.
- No service mesh / mTLS.
- ETL is fire-and-forget; no result persistence — matches the brief, which only requires hourly run.
