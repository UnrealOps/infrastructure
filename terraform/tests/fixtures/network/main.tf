module "network" {
  source = "../../../modules/network"

  name         = var.name
  cluster_name = var.name
}
