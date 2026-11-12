# Criada no bootstrap. Buscada por nome para o CI não depender de tfvars, que
# não é versionado.
data "aws_iam_role" "ci" {
  name = var.ci_role_name
}

data "aws_iam_user" "admin" {
  user_name = var.admin_user_name
}

data "aws_caller_identity" "atual" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Endpoint público para o CI e a máquina do time alcançarem o cluster sem VPN.
  cluster_endpoint_public_access = true

  # Mesmo motivo das access entries: por padrão o módulo torna administrador da
  # chave KMS quem está executando, e o apply passa a alternar a política entre o
  # CI e a máquina local a cada rodada, num diff que nunca converge.
  kms_key_administrators = [
    data.aws_iam_role.ci.arn,
    data.aws_iam_user.admin.arn,
  ]

  # Desligado de propósito. Esta opção concede acesso a QUEM RODA o terraform,
  # então aplicar do CI substitui a entrada de quem aplicou da própria máquina —
  # e a pessoa perde acesso ao cluster sem nada no plano indicar isso.
  # Com as entradas declaradas abaixo, o acesso não depende de quem executa.
  enable_cluster_creator_admin_permissions = false

  # Permissão de IAM não é permissão de Kubernetes: o cluster tem controle de
  # acesso próprio. Sem entrada aqui, o principal autentica na AWS, pede o token
  # e é recusado pela API do cluster ("Kubernetes cluster unreachable").
  # Ter admin na conta AWS não dá acesso ao cluster: o EKS mantém autorização
  # própria. Quem não constar aqui recebe Unauthorized no kubectl, mesmo sendo
  # administrador da conta.
  access_entries = merge(
    {
      for nome in var.cluster_admin_users : nome => {
        principal_arn = "arn:aws:iam::${data.aws_caller_identity.atual.account_id}:user/${nome}"

        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      ci = {
        principal_arn = data.aws_iam_role.ci.arn

        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }

      admin = {
        principal_arn = data.aws_iam_user.admin.arn

        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size
    }
  }
}

# Permite que os pods dos serviços alcancem os bancos. Os security groups dos
# RDS do OS e do Billing (terraform/ de cada serviço) referenciam este como
# origem autorizada.
output "node_security_group_id" {
  description = "Security group dos nós — origem do tráfego dos pods."
  value       = module.eks.node_security_group_id
}
