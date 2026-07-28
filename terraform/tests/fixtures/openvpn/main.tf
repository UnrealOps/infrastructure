module "network" {
  source = "../../../modules/network"

  name         = var.name
  cluster_name = var.name
}

module "openvpn" {
  source = "../../../modules/openvpn"

  name               = var.name
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  subnet_ids         = module.network.vpn_subnet_ids
  runtime_secret_arn = var.runtime_secret_arn
}
