locals {
  cluster_version                 = "1.36"
  system_node_ami_release_version = "1.36.2-20260709"

  cluster_addon_versions = {
    vpc_cni                  = "v1.22.3-eksbuild.1"
    coredns                  = "v1.14.3-eksbuild.3"
    kube_proxy               = "v1.36.0-eksbuild.9"
    ebs_csi_driver           = "v1.62.0-eksbuild.1"
    pod_identity_agent       = "v1.3.10-eksbuild.3"
    cloudwatch_observability = "v6.2.0-eksbuild.1"
  }
}
