variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "tc3-oficina"
}

variable "environment" {
  description = "Ambiente lógico: homolog ou prod."
  type        = string
  default     = "homolog"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = <<-EOT
    Manter numa versão em standard support. Versões em extended support custam
    US$ 0,60 por hora de cluster em vez de US$ 0,10 — seis vezes mais, cobrado
    em silêncio. A 1.31 saiu do standard support em 26/11/2025. A 1.35 fica em standard
    support ate marco de 2027, com folga sobre o prazo do projeto.
  EOT
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = <<-EOT
    Tipo dos nós. t3.small (2 vCPU / 2 GiB) atende o HPA de 2–10 réplicas da
    aplicação; subir para t3.medium se os pods de sistema apertarem.
  EOT
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = <<-EOT
    Na Fase 4 o cluster roda três serviços com duas réplicas cada. Só os pods
    de sistema ocupam cerca de 25 das 33 vagas de três nós, e os serviços
    levariam a 31, sem espaço para a migration e o rollout. Quatro nós dão 44
    vagas.
  EOT
  type        = number
  default     = 4
}

variable "node_min_size" {
  description = <<-EOT
    O limite do t3.small é de pods, não de CPU: 11 por nó (ENIs × IPs da VPC
    CNI). Com os DaemonSets do nri-bundle, dois nós ficavam em 11/11 e a
    migration não era agendada. Três nós deixam folga para a migration e o
    rollout.

    O módulo do EKS ignora mudanças em desired_size depois da criação: para
    mudar o tamanho de um cluster existente, ajuste o node group na AWS antes
    de subir o mínimo aqui.
  EOT
  type        = number
  default     = 3
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "ci_role_name" {
  description = "Role que o GitHub Actions assume por OIDC, criada no bootstrap."
  type        = string
  default     = "tc3-github-actions"
}

variable "admin_user_name" {
  description = "Usuário IAM que administra o cluster a partir da máquina local."
  type        = string
  default     = "tc3-admin"
}

variable "cluster_admin_users" {
  description = <<-EOT
    Usuários IAM do time que precisam operar o cluster com kubectl. Admin na
    conta AWS não basta — o EKS tem autorização própria.
  EOT
  type        = list(string)
  default = [
    "mauricio.mathias",
    "miguel.moraes",
    "lucas.valadao",
    "rodrigo.souza",
  ]
}

# ─── New Relic ──────────────────────────────────────────────────────────────
# Os três valores saem de uma conta gratuita em newrelic.com/signup e entram
# como secrets do GitHub (TF_VAR_*). Não têm default de propósito: sem eles a
# stack sobe cega, e um plano que falha alto é melhor do que observabilidade
# que ninguém percebeu que não subiu.

variable "newrelic_account_id" {
  description = "Account ID numérico — canto superior direito da UI, em 'Administration'."
  type        = string

  # Falha no plan, e não no meio do apply: o provider rejeita ID não numérico
  # só depois de ter criado metade dos recursos.
  validation {
    condition     = can(regex("^[0-9]+$", var.newrelic_account_id))
    error_message = "newrelic_account_id deve ser o Account ID numérico da conta (ex.: 1234567). Um placeholder precisa ser substituído pelo valor real antes do apply."
  }
}

variable "newrelic_api_key" {
  description = <<-EOT
    User key (prefixo `NRAK-`). Autoriza a API de configuração — dashboards,
    políticas de alerta, monitores. Não confundir com a license key, que só
    autoriza ingestão e devolve 401 aqui.
  EOT
  type        = string
  sensitive   = true
}

variable "newrelic_license_key" {
  description = <<-EOT
    License key de ingestão (prefixo `NRAL-` ou 40 caracteres). É o que os
    agentes usam para enviar telemetria. Publicada no SSM para a aplicação, a
    Lambda e o Firehose lerem do mesmo lugar.
  EOT
  type        = string
  sensitive   = true

  # Chave com tamanho errado não falha em lugar nenhum visível: os agentes sobem,
  # recebem 403 do coletor e ficam mudos. Melhor parar o plan aqui.
  validation {
    condition     = length(var.newrelic_license_key) == 40
    error_message = "newrelic_license_key deve ter 40 caracteres (chave do tipo 'Ingest - License'). Um placeholder precisa ser substituído pela chave real antes do apply."
  }
}

variable "newrelic_tags" {
  description = <<-EOT
    Tags padrão do projeto em TODA a telemetria: atributos do agente de
    Kubernetes, campos de cada log coletado pelo Fluent Bit, tags do dashboard
    e das condições de alerta — e é por elas que alertas e painéis filtram.

    Os mesmos valores estão em `newrelic_tags` do terraform/ do OS e de
    tc3-auth-lambda, e em `NEW_RELIC_LABELS` do ConfigMap da aplicação. Mudar
    aqui sem mudar lá deixa condições olhando para dado que ninguém publica.

    Separadas de `environment` de propósito: aquela variável compõe o nome do
    cluster, do RDS e do prefixo do SSM, e trocá-la recriaria a infraestrutura
    inteira. Esta só muda como a telemetria é rotulada.
  EOT
  type        = map(string)
  default = {
    environment = "production"
    project     = "tech-challenge-fiap"
  }

  validation {
    condition     = alltrue([for chave in ["environment", "project"] : contains(keys(var.newrelic_tags), chave)])
    error_message = "newrelic_tags precisa conter as chaves 'environment' e 'project'."
  }

  # `:` e `;` são os separadores de NEW_RELIC_LABELS, e espaço quebraria o
  # `Record` do Fluent Bit.
  validation {
    condition     = alltrue([for chave, valor in var.newrelic_tags : can(regex("^[A-Za-z0-9_.-]+$", chave)) && can(regex("^[A-Za-z0-9_.-]+$", valor))])
    error_message = "Chaves e valores de newrelic_tags aceitam apenas letras, dígitos, '_', '.' e '-'."
  }
}

variable "newrelic_region" {
  description = "Datacenter da conta: US ou EU. Definido no cadastro e imutável."
  type        = string
  default     = "US"

  validation {
    condition     = contains(["US", "EU"], var.newrelic_region)
    error_message = "newrelic_region deve ser US ou EU."
  }
}

variable "newrelic_low_data_mode" {
  description = <<-EOT
    Modo econômico do agente de Kubernetes: intervalo de coleta de 30s em vez de
    15s e descarte de atributos verbosos. Ligado por padrão porque o free tier
    corta a ingestão ao passar de 100 GB/mês — e, diferente de uma cobrança
    extra, a conta trava até o mês virar.
  EOT
  type        = bool
  default     = true
}

variable "app_namespace" {
  description = <<-EOT
    Namespace onde a aplicação NestJS roda — usado nos filtros de evento do
    Kubernetes e nos alertas. Precisa bater com o `metadata.namespace` dos
    manifestos em `tech-challenge-fiap/k8s/`, hoje `oficina`. Um valor errado
    aqui não quebra o apply: as condições ficam sem dado e nunca disparam.
  EOT
  type        = string
  default     = "oficina"
}

variable "app_new_relic_name" {
  description = <<-EOT
    Nome da aplicação no APM, usado nos filtros de dashboards e alertas. Precisa
    bater com NEW_RELIC_APP_NAME do ConfigMap da aplicação
    (tech-challenge-fiap/k8s/app/01-configmap.yaml), que é de onde o agente o lê.
  EOT
  type        = string
  default     = "oficina-api"
}

variable "alert_emails" {
  description = "Destinatários dos alertas. Vazio cria a política sem canal de notificação."
  type        = list(string)
  default     = []
}

variable "synthetics_uptime_url" {
  description = <<-EOT
    URL pública do `GET /health` da aplicação — o liveness raso, que responde
    200 sem tocar no banco. É de propósito que não seja o `/health/ready`: um
    blip no RDS abriria incidente de disponibilidade externa quando o problema
    é outro, e o alerta de banco já cobre esse caso.

    Sai do output `api_endpoint` de tc3-auth-lambda, trocando `/auth` por
    `/health`. Vazia desliga o monitor externo — os alertas internos de uptime
    continuam valendo.
  EOT
  type        = string
  default     = ""
}

variable "synthetics_period" {
  description = <<-EOT
    Frequência do monitor externo. O free tier dá 500 checks/mês, então:

      EVERY_MINUTE      43.200/mês   estoura
      EVERY_30_MINUTES   1.440/mês   estoura
      EVERY_HOUR           720/mês   estoura
      EVERY_6_HOURS        120/mês   cabe   ← default
      EVERY_12_HOURS        60/mês   cabe

    Seis horas é pouco para detectar queda, e é justamente por isso que o
    uptime de verdade é medido pelos alertas internos (pods prontos, hosts
    saudáveis no ALB). Este monitor cobre o que os de dentro não veem: DNS,
    TLS e o caminho pela internet.
  EOT
  type        = string
  default     = "EVERY_6_HOURS"
}

variable "alerta_latencia_ms" {
  description = <<-EOT
    Latência p95 das transações web, em milissegundos, que abre incidente.

    Sem o metric stream do CloudWatch a medição saiu do ALB e passou para o
    agente de APM: `Transaction.duration` conta do momento em que o Node aceita
    a requisição até a resposta sair, e não inclui fila de conexão no
    balanceador nem tempo de rede. Na prática o número fica um pouco abaixo do
    que o cliente sente — o monitor de Synthetics é quem cobre essa diferença.

    2000 ms é o limiar do requisito. Em `t3.small` com HPA de 2 réplicas o pico
    de escala sobe a cauda por alguns minutos, então o gatilho exige 5 minutos
    acima do valor antes de abrir incidente.
  EOT
  type        = number
  default     = 2000
}

variable "alerta_utilizacao_pct" {
  description = "Percentual de CPU ou memória de um nó que abre incidente."
  type        = number
  default     = 85
}

variable "alerta_ingestao_gb" {
  description = <<-EOT
    Limiares de ingestão acumulada no mês (GB) para o alerta de consumo.

    O free tier dá 100 GB/mês e, ao passar disso, a conta não é cobrada: ela
    PARA de ingerir até o mês virar — dashboards e alertas ficam cegos juntos.
    O aviso em 70 dá margem para agir (desligar componente, reduzir log); o
    crítico em 85 é o último momento em que ainda dá tempo.
  EOT
  type = object({
    aviso   = number
    critico = number
  })
  default = {
    aviso   = 70
    critico = 85
  }

  validation {
    condition     = var.alerta_ingestao_gb.aviso < var.alerta_ingestao_gb.critico && var.alerta_ingestao_gb.critico < 100
    error_message = "alerta_ingestao_gb: aviso < critico < 100."
  }
}

variable "alerta_db_conexoes" {
  description = <<-EOT
    Conexões ativas no Postgres que abrem incidente.

    O teto do RDS é calculado a partir da memória da instância
    (`LEAST({DBInstanceClassMemory/9531392}, 5000)`): em `db.t4g.micro`, com
    1 GiB, dá algo perto de 112. O pool da aplicação e o da Lambda somados não
    deveriam passar de algumas dezenas, então 80 já indica vazamento de conexão
    — e ainda sobra margem para investigar antes do banco recusar conexão nova.
  EOT
  type        = number
  default     = 80
}
