data "aws_caller_identity" "current" {}

# IRSA for AWS Load Balancer Controller
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# GitHub OIDC provider (for Actions to assume role without static keys)
resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo == "" ? 0 : 1

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_oidc_assume" {
  count = var.github_repo == "" ? 0 : 1

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count              = var.github_repo == "" ? 0 : 1
  name               = "${var.cluster_name}-gha-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume[0].json
}

data "aws_iam_policy_document" "gha_deploy" {
  count = var.github_repo == "" ? 0 : 1

  # ECR push
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["*"]
  }

  # EKS describe + token
  statement {
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  count  = var.github_repo == "" ? 0 : 1
  name   = "deploy"
  role   = aws_iam_role.github_actions[0].id
  policy = data.aws_iam_policy_document.gha_deploy[0].json
}

# Grant the GHA deployer role cluster-admin via EKS access entries
# (module 20.x default: API_AND_CONFIG_MAP). Does not touch aws-auth.
resource "aws_eks_access_entry" "gha_deployer" {
  count         = var.github_repo == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_deployer_admin" {
  count         = var.github_repo == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gha_deployer]
}
