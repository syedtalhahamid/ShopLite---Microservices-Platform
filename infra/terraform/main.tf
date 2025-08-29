provider "aws" {
  region = var.region
}

resource "aws_ecr_repository" "auth" { name = "shoplite-auth" }
resource "aws_ecr_repository" "product" { name = "shoplite-product" }
resource "aws_ecr_repository" "order" { name = "shoplite-order" }

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 19.0.0"
  cluster_name = "shoplite-eks"
  cluster_version = "1.27"
  subnets = var.subnet_ids
  vpc_id = var.vpc_id
  # configure node groups, IAM, etc.
}
