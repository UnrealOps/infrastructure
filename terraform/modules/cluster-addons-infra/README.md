# Cluster add-ons AWS infrastructure

Creates the IAM role, official controller policy, and EKS Pod Identity
association required by AWS Load Balancer Controller chart `3.4.3`. The module
does not configure providers or install Kubernetes resources.

The policy is copied verbatim from the
[`v3.4.3` controller release](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.4.3/docs/install/iam_policy.json)
so chart and IAM capabilities advance together.
