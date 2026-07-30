# Lore EKS workload

Discovers Lore foundation resources from deterministic AWS names, renders the
local Lore Helm chart, waits for the internal NLB, creates its private Route 53
alias, and installs workload dashboards and alarms. It never uses Terraform
remote state and does not configure providers.

The `image` input accepts only a full private ECR digest URI. Tags and `latest`
are rejected.
