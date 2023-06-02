provider "aws" {
  #https://github.com/hashicorp/terraform-provider-aws/issues/19583
  /* default_tags {
    tags = local.tags
  } */
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_route53_zone" "this" {
  name = var.domain_name
}

data "aws_availability_zones" "available" {}

locals {
  root             = basename(abspath(path.module))
  workspace_suffix = terraform.workspace == "default" ? "" : "_${terraform.workspace}"
  name             = "${var.preffix}${local.workspace_suffix}"
  vpc_name         = "${local.name}-vpc"
  cluster_name     = "${local.name}-eks"
  s3_backup_name   = "${local.name}.backups"
  #s3_artifacts_name = "${local.name}.artifacts"
  route53_zone_id = data.aws_route53_zone.this.id
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = merge(var.tags, {
    "tf:blueprint_root" = local.root
  })

  kubeconfig_file      = "kubeconfig-${module.eks.cluster_name}.yaml"
  kubeconfig_file_path = abspath("${path.root}/${local.kubeconfig_file}")
}

################################################################################
# EKS Integrations
################################################################################

module "aws_s3_backups" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "3.4.0"

  bucket = local.s3_backup_name

  # Allow deletion of non-empty bucket
  # NOTE: This is enabled for example usage only, you should not enable this for production workloads
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  #acl = "private"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerPreferred"

  versioning = {
    status     = true
    mfa_delete = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

################################################################################
# EKS Pre-requisites
################################################################################

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.3.2"

  domain_name = var.domain_name
  subject_alternative_names = [
    "*.ci.${var.domain_name}",
    "*.cd.${var.domain_name}",
    "*.${var.domain_name}"
  ]

  #https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html
  zone_id = local.route53_zone_id

  tags = local.tags
}

#https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html
#https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html
module "vpc" {
  source = "../../modules/aws-vpc-eks"

  name = local.vpc_name
  azs  = local.azs

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.12"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  #https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  #cluster_endpoint_public_access_cidrs = var.ssh_cidr_blocks_k8s_whitelist

  # EKS Addons
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  node_security_group_additional_rules = {
    egress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      self        = true
    }

    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    egress_ssh_all = {
      description      = "Egress all ssh to internet for github"
      protocol         = "tcp"
      from_port        = 22
      to_port          = 22
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    mg_k8sApps = {
      node_group_name = "managed-k8s-apps"
      #https://aws.amazon.com/ec2/instance-types/
      instance_types = ["m5d.4xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 6
      desired_size   = 1
    },
    mg_cbApps = {
      node_group_name = "managed-cb-apps"
      #https://aws.amazon.com/ec2/instance-types/
      instance_types  = ["m5.8xlarge"]
      capacity_type   = "ON_DEMAND"
      create_iam_role = false # Changing `create_iam_role=false` to bring your own IAM Role
      #Alternative using iam_role_additional_policies https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/19.10.2
      iam_role_arn = aws_iam_role.managed_ng.arn
      min_size     = 1
      max_size     = 6
      desired_size = 1
      taints       = [{ key = "dedicated", value = "cb-apps", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "cb-apps"
      }
    }
    mg_cbAgents = {
      node_group_name = "managed-agent"
      instance_types  = ["m5.4xlarge"]
      capacity_type   = "ON_DEMAND"
      min_size        = 1
      max_size        = 3
      desired_size    = 1
      taints          = [{ key = "dedicated", value = "build-linux", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "build-linux"
      }
    },
    mg_cbAgents_spot = {
      node_group_name = "managed-agent-spot"
      instance_types  = ["m5.4xlarge"]
      capacity_type   = "SPOT"
      min_size        = 1
      max_size        = 3
      desired_size    = 1
      taints          = [{ key = "dedicated", value = "build-linux-spot", effect = "NO_SCHEDULE" }]
      labels = {
        ci_type = "build-linux-spot"
      }
    }
  }
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "~> 1.0"

  creation_token = local.name
  name           = local.name

  # Mount targets / security group
  mount_targets = {
    for k, v in zipmap(local.azs, module.vpc.private_subnets) : k => { subnet_id = v }
  }
  security_group_description = "${local.name} EFS security group"
  security_group_vpc_id      = module.vpc.vpc_id
  performance_mode           = "maxIO" #Jenkins Requires High IO
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Custom IAM roles for Node Group Cloudbees Apps
#---------------------------------------------------------------

data "aws_iam_policy_document" "managed_ng_assume_role_policy" {
  statement {
    sid = "EKSWorkerAssumeRole"

    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "managed_ng" {
  name                  = "managed-node-role"
  description           = "EKS Managed Node group IAM Role"
  assume_role_policy    = data.aws_iam_policy_document.managed_ng_assume_role_policy.json
  path                  = "/"
  force_detach_policies = true
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
  inline_policy {
    name = "CloudBees_CI"
    policy = jsonencode(
      {
        "Version" : "2012-10-17",
        "Statement" : [
          {
            "Sid" : "CBCIBackupPolicy1",
            "Effect" : "Allow",
            "Action" : [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject"
            ],
            "Resource" : "arn:aws:s3:::${local.s3_backup_name}/cbci/*"
          },
          {
            "Sid" : "CBCIBackupPolicy2",
            "Effect" : "Allow",
            "Action" : "s3:ListBucket",
            "Resource" : "arn:aws:s3:::${local.s3_backup_name}"
          },
        ]
      }
    )
  }
  tags = local.tags
}

resource "aws_iam_instance_profile" "managed_ng" {
  name = "managed-node-instance-profile-ci"
  role = aws_iam_role.managed_ng.name
  path = "/"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Generating kubeconfig file
#---------------------------------------------------------------

#https://www.bitslovers.com/terraform-null-resource/
resource "null_resource" "update_kubeconfig" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --kubeconfig ${local.kubeconfig_file}"
  }
}