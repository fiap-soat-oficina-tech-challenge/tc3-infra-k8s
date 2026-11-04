# tc3-infra-k8s

Infraestrutura Kubernetes do Tech Challenge Fase 3 (FIAP SOAT) — sistema de gestão de oficina mecânica.

Provisiona, via Terraform, a rede e o cluster onde a aplicação NestJS roda. É a **base** dos demais repositórios: `tc3-infra-db` e `tc3-auth-lambda` leem os outputs daqui pelo state remoto.

## O que este repositório cria

| Recurso | Detalhe |
|---|---|
| VPC | 2 AZs, subnets públicas e privadas, NAT único |
| Cluster EKS | Kubernetes 1.35, endpoint público, addons de base |
| Managed node group | 3× `t3.small` (3–4 nós) |
| metrics-server | Requisito do HPA da aplicação |
| AWS Load Balancer Controller | Traduz Ingress em ALB; alvo do VPC Link do API Gateway |
| `nri-bundle` (New Relic) | Métricas, eventos e logs do cluster, sem CloudWatch no caminho |
| Dashboard e alertas | Quatro páginas de painéis e quatorze condições (quinze com o monitor de Synthetics), como código |
| Monitor de Synthetics | Healthcheck externo, quando a URL pública é informada |

## Tecnologias

Terraform ≥ 1.10 · AWS provider 5.x · módulos `terraform-aws-modules/vpc` e `/eks` · Helm provider · GitHub Actions

## Ordem de execução

```
bootstrap/  →  tc3-infra-k8s  →  tc3-infra-db  →  tc3-auth-lambda
```

### 1. Bootstrap (uma vez por conta)

Cria o bucket de state, o budget de proteção de custo e o OIDC do GitHub Actions. Usa state local — por isso mora num diretório separado.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # editar
terraform init
terraform apply
```

Anote os outputs: `state_bucket` e `github_actions_role_arn`.

### 2. Cluster

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config="bucket=SEU_BUCKET"
terraform apply

aws eks update-kubeconfig --region us-east-1 --name tc3-oficina-homolog
kubectl get nodes
```

## CI/CD

`.github/workflows/terraform.yml`

- **Pull request** → `fmt`, `validate` e `plan`, com o plano comentado no PR
- **Push em `develop`** → apply automático (rótulo `homolog` no GitHub)
- **Push em `main`** → apply automático (rótulo `production` no GitHub)

> **Ambiente único:** `develop` e `main` aplicam no **mesmo** ambiente na AWS (mesmo state e recursos) — a distinção homologação/produção é apenas o rótulo do deploy no GitHub e foi desconsiderada.

Secrets necessários no repositório:

| Secret | Origem |
|---|---|
| `AWS_ROLE_ARN` | output `github_actions_role_arn` do bootstrap |
| `TF_STATE_BUCKET` | output `state_bucket` do bootstrap |
| `NEW_RELIC_ACCOUNT_ID` | conta New Relic → *Administration* |
| `NEW_RELIC_API_KEY` | conta New Relic → *API keys*, tipo **User** (`NRAK-…`) |
| `NEW_RELIC_LICENSE_KEY` | conta New Relic → *API keys*, tipo **Ingest - License** |

O workflow mapeia cada um para a variável correspondente do Terraform no bloco
`env:` — cadastrar o secret não basta, e nomeá-lo `TF_VAR_NEWRELIC_API_KEY` não
funciona: o Terraform casa `TF_VAR_<nome>` com o nome exato declarado em
`variables.tf`, em minúsculas.

Aplicando da própria máquina, os mesmos valores ficam no `.env` da raiz —
ignorado pelo git (`.env` e `.env.*` no `.gitignore`), já com o mapeamento
`TF_VAR_*`:

```bash
set -a; source .env; set +a
terraform plan
```

O plan valida o formato das credenciais antes de tocar em qualquer recurso:
account ID numérico e license key de 40 caracteres. Placeholder falha ali, com a
explicação, em vez de os agentes subirem e receberem 403 em silêncio.

Duas *variables* do repositório (aba ao lado dos secrets) completam a
configuração, ambas opcionais:

| Variable | Efeito se ficar vazia |
|---|---|
| `ALERT_EMAILS` | política sobe sem canal de notificação — formato JSON: `["fulano@exemplo.com"]` |
| `SYNTHETICS_UPTIME_URL` | monitor externo não é criado; os alertas internos de uptime continuam valendo |

`main` é protegida: merge apenas via Pull Request com CI verde.

## Custo

O control plane do EKS e os nós são cobrados por hora enquanto existirem. Fora das janelas de trabalho:

```bash
terraform destroy
```

O `terraform apply` reconstrói o ambiente inteiro em ~20 minutos — que é, ele próprio, a demonstração de infraestrutura como código funcionando.

## Arquitetura

```mermaid
graph TB
    Internet["Internet"]
    GH["GitHub Actions<br/>(CI/CD dos 4 repos)"]
    NR["New Relic"]

    subgraph AWS["AWS · us-east-1"]
        ECR["<b>ECR</b><br/>imagem da API"]
        OIDC["<b>IAM + OIDC</b><br/>role assumida pelo CI<br/>(sem chave estática)"]

        subgraph VPC["VPC 10.0.0.0/16 · 2 AZs"]
            subgraph Pub["subnets públicas"]
                ALB["<b>ALB</b><br/>(via AWS Load Balancer Controller)<br/>alvo do VPC Link do API Gateway"]
                NAT["NAT Gateway<br/>(egress único)"]
            end
            subgraph Priv["subnets privadas"]
                subgraph EKS["<b>EKS</b> 1.35 · node group 3× t3.small"]
                    Pods["pods da API<br/>HPA 2–10 · metrics-server"]
                    NRB["nri-bundle<br/>(métricas/logs/eventos do cluster)"]
                end
                RDS[("<b>RDS PostgreSQL</b><br/>criado em tc3-infra-db")]
            end
        end
    end

    Internet -->|"HTTPS"| ALB
    ALB --> Pods
    Pods -->|"SQL/TLS 5432"| RDS
    Pods -->|"egress"| NAT
    Pods -->|"pull imagem"| ECR
    GH -->|"assume role (OIDC)"| OIDC
    NRB -->|"métricas · logs · eventos"| NR
```

Este repositório provisiona a **base** (VPC, EKS, ECR, ALB Controller, OIDC) e a **observabilidade do cluster** (`nri-bundle`, dashboard e alertas). O **RDS** é criado em [`tc3-infra-db`](https://github.com/fiap-soat-oficina-tech-challenge/tc3-infra-db) e as **Lambdas + API Gateway** em [`tc3-auth-lambda`](https://github.com/fiap-soat-oficina-tech-challenge/tc3-auth-lambda), ambos lendo os outputs daqui pelo state remoto.

## Observabilidade

Métricas, logs, traces e alertas no New Relic, com todos os agentes falando
direto com a API — sem CloudWatch Logs, Metric Stream ou Firehose em nenhum
ponto do caminho.

O desenho completo, o contrato dos campos de log e o que se ganhou e se perdeu
ao sair do CloudWatch estão em [OBSERVABILIDADE.md](OBSERVABILIDADE.md).

Deste repositório saem a chave de ingestão no SSM, o agente de Kubernetes
(`nri-bundle`: CPU, memória e estado de nós, pods e contêineres, eventos do
cluster e logs), o dashboard, as políticas de alerta — incluindo a de consumo
do free tier — e as tags `environment: production` / `project:
tech-challenge-fiap` aplicadas a toda a telemetria. O agente do banco mora em
`tc3-infra-db` e a instrumentação da autenticação em `tc3-auth-lambda`, cada um
perto do recurso que monitora.

```bash
terraform output newrelic_dashboard_url
```

## Outputs consumidos por outros repositórios

`vpc_id` · `private_subnet_ids` · `public_subnet_ids` · `cluster_name` · `cluster_endpoint` · `cluster_oidc_provider_arn` · `node_security_group_id`
