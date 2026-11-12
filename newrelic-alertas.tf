# Política de alertas da oficina.
#
# Toda a telemetria daqui chega por agente que empurra dado: o agente de
# Kubernetes no cluster, o agente de APM dentro do pod, o Fluent Bit dos logs e
# a extension da Lambda. Não há mais polling nem Firehose no caminho, então a
# latência de ingestão é de segundos e os `aggregation_delay` ficam curtos e
# parecidos entre si.
#
# Onde os números moram:
#
#   K8sNodeSample / K8sPodSample / K8sContainerSample   agente de Kubernetes
#   Transaction / TransactionError                       agente de APM (Node)
#   Metric (Custom/OrdemServico/*)                       métricas customizadas
#   Log                                                  Fluent Bit (stdout)
#   AwsLambdaInvocation*                                 extension da Lambda
#   PostgresqlDatabaseSample                             nri-postgresql
#   NrMTDConsumption                                     consumo da própria conta
#
# As condições sobre `Log` e sobre o banco filtram pelas tags padrão do projeto
# (`environment`, `project` — var.newrelic_tags), escritas pela aplicação, pela
# Lambda e pelo agente de banco. É de propósito que não se filtre pelos
# atributos que o Fluent Bit acrescenta: esses vêm em snake_case
# (`cluster_name`, `namespace_name`) enquanto os eventos de Kubernetes usam
# camelCase, e misturar as duas convenções é o jeito mais rápido de escrever
# uma condição que nunca dispara.
#
# As condições de negócio da ordem de serviço leem as MÉTRICAS customizadas, e
# não o log: são agregadas no processo (não sofrem com amostragem nem com
# atraso do Fluent Bit) e continuam chegando mesmo que o log seja cortado para
# caber no free tier. O log fica para a investigação — é ele que tem o ordem_id
# e o trace.id de cada falha.

locals {
  # Status possíveis da ordem (enum StatusOrdemServico). Usados para montar os
  # nomes das métricas por status sem depender de LIKE em metricTimesliceName.
  status_ordem_servico = [
    "RECEBIDA",
    "EM_DIAGNOSTICO",
    "AGUARDANDO_APROVACAO",
    "EM_EXECUCAO",
    "FINALIZADA",
    "ENTREGUE",
  ]

  # Etapas em que a aplicação registra falha (telemetria-ordem-servico.ts).
  metricas_falha_ordem = [
    "'Custom/OrdemServico/Falha/criacao'",
    "'Custom/OrdemServico/Falha/transicao_status'",
  ]

  metricas_transicao_ordem = [
    for status in local.status_ordem_servico : "'Custom/OrdemServico/Transicao/${status}'"
  ]

  # Filtro padrão para eventos que carregam as tags do projeto.
  filtro_tags = "environment = '${local.nr_environment}' AND project = '${local.nr_project}'"
}

resource "newrelic_alert_policy" "oficina" {
  account_id = var.newrelic_account_id
  name       = "${local.cluster_name} — oficina"

  # Um incidente por condição. "PER_CONDITION_AND_TARGET" abriria um por pod,
  # o que num CrashLoop vira dezenas de e-mails do mesmo problema.
  incident_preference = "PER_CONDITION"
}

# ─── Latência das APIs ──────────────────────────────────────────────────────
# Medida pelo agente de APM dentro do processo. `duration` vem em segundos;
# multiplicamos por mil para o limiar ficar na mesma unidade do resto do mundo.

resource "newrelic_nrql_alert_condition" "api_latencia" {
  account_id = var.newrelic_account_id
  policy_id  = newrelic_alert_policy.oficina.id
  type       = "static"
  name       = "API — latência p95 alta"
  description = join(" ", [
    "p95 do tempo de resposta da API acima do limiar.",
    "Verificar primeiro se o HPA escalou e se o Postgres não está saturado —",
    "o painel de banco do dashboard responde as duas em uma tela.",
  ])

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT percentile(duration, 95) * 1000
      FROM Transaction
      WHERE appName = '${var.app_new_relic_name}'
        AND transactionType = 'Web'
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.alerta_latencia_ms
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

resource "newrelic_nrql_alert_condition" "api_erros_5xx" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "API — respostas 5xx"
  description = "A aplicação está devolvendo erro de servidor."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  # `numeric()` porque a versão do agente define se `http.statusCode` chega como
  # número ou como string; a comparação direta falha em silêncio no segundo caso.
  nrql {
    query = <<-NRQL
      SELECT count(*)
      FROM Transaction
      WHERE appName = '${var.app_new_relic_name}'
        AND numeric(`http.statusCode`) >= 500
    NRQL
  }

  # Um 5xx isolado acontece em rollout; cinco em cinco minutos, não.
  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# ─── Consumo de recursos do Kubernetes ──────────────────────────────────────
# No nível do nó, não do contêiner: a aplicação pode não declarar limits, e
# `cpuCoresUtilization` de contêiner sem limite é nulo — o alerta existiria no
# console e nunca dispararia.

resource "newrelic_nrql_alert_condition" "k8s_cpu" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Kubernetes — CPU do nó saturada"
  description = "Nó acima do limiar de CPU alocável. O HPA pode não ter onde escalar."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT average(allocatableCpuCoresUtilization)
      FROM K8sNodeSample
      WHERE clusterName = '${local.cluster_name}'
      FACET nodeName
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.alerta_utilizacao_pct
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

resource "newrelic_nrql_alert_condition" "k8s_memoria" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Kubernetes — memória do nó saturada"
  description = "Memória alocável no limite. Precede despejo de pods."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT average(allocatableMemoryUtilization)
      FROM K8sNodeSample
      WHERE clusterName = '${local.cluster_name}'
      FACET nodeName
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.alerta_utilizacao_pct
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# Reinício é o sintoma que a métrica de recurso não mostra: um contêiner morto
# por OOM aparece como queda de memória, não como pico.
resource "newrelic_nrql_alert_condition" "k8s_reinicios" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Kubernetes — contêiner reiniciando"
  description = "Reinícios seguidos indicam CrashLoopBackOff ou OOMKilled."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT sum(restartCountDelta)
      FROM K8sContainerSample
      WHERE clusterName = '${local.cluster_name}'
        AND namespaceName = '${var.app_namespace}'
      FACET containerName
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# ─── Healthcheck e uptime ───────────────────────────────────────────────────
# O sinal interno de disponibilidade: pod pronto é o que o Kubernetes usa para
# mandar tráfego. Roda a cada minuto e não consome cota de Synthetics — por isso
# é ele, e não o monitor externo, que sustenta o alerta de queda.
#
# Com a saída do CloudWatch perdemos o `HealthyHostCount` do ALB, que era o
# sinal do meio do caminho. Sobrou o par de pontas: este alerta olha de dentro,
# o monitor de Synthetics olha de fora. Um balanceador saudável com pods
# saudáveis e DNS respondendo não tem como estar fora para o cliente.

resource "newrelic_nrql_alert_condition" "uptime_pods" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Uptime — nenhum pod pronto"
  description = "Nenhuma réplica da API está pronta para receber tráfego: a aplicação está fora."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT uniqueCount(podName)
      FROM K8sPodSample
      WHERE clusterName = '${local.cluster_name}'
        AND namespaceName = '${var.app_namespace}'
        AND status = 'Running'
        AND isReady = 1
    NRQL
  }

  # `below 1` só fecha se o dado chegar. Com o cluster inteiro fora não chega
  # nada, então a ausência de sinal também precisa contar como violação.
  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }

  # Sem sinal por 10 minutos abre incidente: cluster destruído, agente morto ou
  # ingestão cortada por limite de conta são todos "está fora" na prática.
  expiration_duration            = 600
  open_violation_on_expiration   = true
  close_violations_on_expiration = true
}

# ─── Banco de dados ─────────────────────────────────────────────────────────
# Vem do nri-postgresql, que roda no cluster e consulta o RDS direto. Sem o
# CloudWatch não existe mais `aws.rds.DatabaseConnections`, e este é o
# substituto: o número sai do próprio `pg_stat_database`, que é a fonte que o
# CloudWatch também lia.
#
# O atributo é `db.connections` (numbackends). A versão anterior desta condição
# usava `db.connections.active`, que a integração não publica: a consulta
# devolvia nulo e o alerta existia no console sem nunca poder disparar.

resource "newrelic_nrql_alert_condition" "banco_conexoes" {
  account_id = var.newrelic_account_id
  policy_id  = newrelic_alert_policy.oficina.id
  type       = "static"
  name       = "Banco — conexões perto do teto"
  description = join(" ", [
    "Conexões ativas no Postgres acima do limiar.",
    "Em `db.t4g.micro` o teto é de ~112; passar dele derruba a aplicação e a",
    "Lambda ao mesmo tempo, com erro de conexão em vez de lentidão.",
  ])

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 60
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT max(`db.connections`)
      FROM PostgresqlDatabaseSample
      WHERE ${local.filtro_tags}
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.alerta_db_conexoes
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# O agente de banco é o único componente da stack que fica fora do caminho da
# requisição: se ele morrer, nada quebra e ninguém percebe. Daí a condição por
# ausência de dado.
resource "newrelic_nrql_alert_condition" "banco_sem_coleta" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Banco — integração sem coletar"
  description = "O nri-postgresql parou de reportar: sem métrica de banco até voltar."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT count(*)
      FROM PostgresqlDatabaseSample
      WHERE ${local.filtro_tags}
    NRQL
  }

  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }

  expiration_duration            = 900
  open_violation_on_expiration   = true
  close_violations_on_expiration = true
}

# ─── Falhas no processamento de ordens de serviço ───────────────────────────
# Lê a métrica customizada `Custom/OrdemServico/Falha/<etapa>`, que a aplicação
# incrementa só em defeito do sistema (banco fora, bug). Regra de negócio que
# recusa o pedido — estoque insuficiente, serviço inativo — devolve 4xx e NÃO
# conta: é a oficina funcionando, não falhando. A versão anterior contava todo
# `level = 'error'` do log, e uma peça em falta abria incidente.
#
# Métrica timeslice: `count(newrelic.timeslice.value)` é o número de
# incrementos no período. O agente prefixa `Custom/` ao nome que o código usa.

resource "newrelic_nrql_alert_condition" "ordens_falhas" {
  account_id = var.newrelic_account_id
  policy_id  = newrelic_alert_policy.oficina.id
  type       = "static"
  name       = "Ordem de serviço — falhas no processamento"
  description = join(" ", [
    "A aplicação registrou falhas ao criar ou transicionar ordens de serviço.",
    "No Log, filtrar evento LIKE 'ordem_servico.%_falhou' e seguir o trace.id",
    "até o trace distribuído; o erro também está no Errors Inbox do APM.",
  ])

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT count(newrelic.timeslice.value)
      FROM Metric
      WHERE appName = '${var.app_new_relic_name}'
        AND metricTimesliceName IN (${join(", ", local.metricas_falha_ordem)})
    NRQL
  }

  # Uma falha isolada é caso de suporte; três em cinco minutos é incidente.
  critical {
    operator              = "above"
    threshold             = 3
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }

  warning {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# Ordem que entra em processamento e não muda de estado é falha silenciosa: não
# gera erro, não gera 5xx, e só aparece quando o cliente liga perguntando.
resource "newrelic_nrql_alert_condition" "ordens_paradas" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Ordem de serviço — fluxo parado"
  description = "Ordens foram criadas, mas nenhuma mudou de status na última hora."

  # Fora do horário de uso não existe ordem nenhuma, e isso não é defeito.
  # Nasce desligada: ligar quando houver tráfego contínuo que a justifique.
  #
  # `event_timer` usa `aggregation_timer` (não `aggregation_delay`, que é das
  # agregações event_flow/cadence).
  enabled                      = false
  aggregation_method           = "event_timer"
  aggregation_window           = 3600
  aggregation_timer            = 300
  violation_time_limit_seconds = 86400

  # Nenhuma transição = nenhuma métrica publicada. Sem preencher a janela vazia
  # com zero, o `below 1` nunca teria dado para avaliar e a condição, que existe
  # justamente para o caso "não aconteceu nada", nunca dispararia.
  fill_option = "static"
  fill_value  = 0

  nrql {
    query = <<-NRQL
      SELECT count(newrelic.timeslice.value)
      FROM Metric
      WHERE appName = '${var.app_new_relic_name}'
        AND metricTimesliceName IN (${join(", ", local.metricas_transicao_ordem)})
    NRQL
  }

  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 3600
    threshold_occurrences = "ALL"
  }
}

# ─── Falhas nas integrações ─────────────────────────────────────────────────

resource "newrelic_nrql_alert_condition" "integracao_lambda" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Integração — erros na Lambda de autenticação"
  description = "A autenticação por CPF está falhando: ninguém novo consegue entrar."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  # `AwsLambdaInvocationError` é gerado pela extension dentro da própria função.
  # Substitui o `aws.lambda.Errors` que vinha do CloudWatch e chega antes: não
  # espera o ciclo de agregação de métrica da AWS.
  nrql {
    query = <<-NRQL
      SELECT count(*)
      FROM AwsLambdaInvocationError
      WHERE appName = '${local.lambda_app_name}'
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = 3
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# Timeout não conta como erro na Lambda: a invocação é encerrada pelo runtime e
# a extension não chega a reportar exceção. O sintoma é a duração encostando no
# teto configurado.
resource "newrelic_nrql_alert_condition" "integracao_lambda_lenta" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Integração — Lambda de autenticação lenta"
  description = "p95 da autenticação acima de 3s: normalmente é conexão com o Postgres."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT percentile(duration, 95) * 1000
      FROM AwsLambdaInvocation
      WHERE appName = '${local.lambda_app_name}'
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = 3000
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

resource "newrelic_nrql_alert_condition" "integracao_banco" {
  account_id  = var.newrelic_account_id
  policy_id   = newrelic_alert_policy.oficina.id
  type        = "static"
  name        = "Integração — falhas de acesso ao banco"
  description = "A aplicação ou a Lambda registrou erro de conexão ou consulta ao Postgres."

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 180
  violation_time_limit_seconds = 86400

  # Cobre os dois lados do banco: a API no cluster e a Lambda de autenticação,
  # que escreve o mesmo formato de log. Por isso o filtro é pelas tags do
  # projeto e não por `servico`.
  nrql {
    query = <<-NRQL
      SELECT count(*)
      FROM Log
      WHERE ${local.filtro_tags}
        AND level = 'error'
        AND (evento = 'integracao.banco.falha'
          OR message LIKE '%ECONNREFUSED%'
          OR message LIKE '%PrismaClient%'
          OR message LIKE '%too many connections%')
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = 3
    threshold_duration    = 300
    threshold_occurrences = "ALL"
  }
}

# ─── Mensageria da Saga (Fase 4) ────────────────────────────────────────────
# Uma mensagem na DLQ é falha técnica que esgotou as 5 tentativas de consumo
# (docs/contratos.md do OS Service): alguém precisa corrigir a causa e
# reprocessar a mensagem (redrive). Uma condição cobre as três DLQs, com um
# sinal por fila (FACET), então o incidente diz qual fila encheu.
#
# É a única condição que lê métrica do CloudWatch: o SQS não tem agente, e a
# métrica chega pelo Metric Stream da conta (stack NewRelic-Metric-Streams,
# criada à mão, fora deste Terraform). Sem o stream, a condição não recebe dado
# e não dispara. DLQ vazia e parada também não publica métrica, e isso não é
# violação: a condição só olha valores acima de zero.

locals {
  filas_dlq = [
    "oficina-os-saga-replies-dlq",
    "oficina-billing-commands-dlq",
    "oficina-execution-commands-dlq",
  ]
}

resource "newrelic_nrql_alert_condition" "mensageria_dlq" {
  account_id = var.newrelic_account_id
  policy_id  = newrelic_alert_policy.oficina.id
  type       = "static"
  name       = "Mensageria — mensagem na DLQ"
  description = join(" ", [
    "Uma mensagem da Saga esgotou as tentativas e foi para a DLQ. Ver nos logs",
    "do serviço consumidor o erro do correlationId da mensagem, corrigir a causa",
    "e reprocessar com o redrive da DLQ para a fila de origem.",
  ])

  enabled                      = true
  aggregation_method           = "event_flow"
  aggregation_window           = 300
  aggregation_delay            = 180
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT max(aws.sqs.ApproximateNumberOfMessagesVisible)
      FROM Metric
      WHERE aws.sqs.QueueName IN (${join(", ", [for fila in local.filas_dlq : "'${fila}'"])})
      FACET aws.sqs.QueueName
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 300
    threshold_occurrences = "AT_LEAST_ONCE"
  }
}

# ─── Consumo do free tier ───────────────────────────────────────────────────
# O limite de 100 GB/mês não gera cobrança ao ser ultrapassado: a conta PARA de
# ingerir até o mês virar, e todos os alertas acima ficam cegos ao mesmo tempo.
# Este é o único alerta que protege os outros.
#
# `NrMTDConsumption` é o acumulado do mês, calculado pelo próprio New Relic a
# cada hora (com ~3h de atraso). Por ser um dado infrequente, a documentação
# recomenda `event_timer`: a janela fecha quando o dado chega, sem esperar
# relógio. O painel "Consumo do free tier" do dashboard mostra de onde vem cada
# GB — é por ele que se decide o que cortar quando este alerta abrir.

resource "newrelic_nrql_alert_condition" "consumo_free_tier" {
  account_id = var.newrelic_account_id
  policy_id  = newrelic_alert_policy.oficina.id
  type       = "static"
  name       = "Conta — ingestão do mês perto do limite do free tier"
  description = join(" ", [
    "Ingestão acumulada no mês se aproximando de 100 GB, quando a conta para de",
    "receber dados. Ver a página 'Consumo do free tier' do dashboard e reduzir",
    "a maior fonte (normalmente Log ou spans sob teste de carga).",
  ])

  enabled                      = true
  aggregation_method           = "event_timer"
  aggregation_window           = 3600
  aggregation_timer            = 300
  violation_time_limit_seconds = 86400

  nrql {
    query = <<-NRQL
      SELECT latest(GigabytesIngested)
      FROM NrMTDConsumption
      WHERE productLine = 'DataPlatform'
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.alerta_ingestao_gb.critico
    threshold_duration    = 3600
    threshold_occurrences = "AT_LEAST_ONCE"
  }

  warning {
    operator              = "above"
    threshold             = var.alerta_ingestao_gb.aviso
    threshold_duration    = 3600
    threshold_occurrences = "AT_LEAST_ONCE"
  }
}

# ─── Notificação ────────────────────────────────────────────────────────────
# Um destino por endereço: o tipo EMAIL do New Relic não aceita lista.

resource "newrelic_notification_destination" "email" {
  for_each = toset(var.alert_emails)

  account_id = var.newrelic_account_id
  name       = "email-${replace(each.value, "/[^a-zA-Z0-9]/", "-")}"
  type       = "EMAIL"

  property {
    key   = "email"
    value = each.value
  }
}

resource "newrelic_notification_channel" "email" {
  for_each = newrelic_notification_destination.email

  account_id     = var.newrelic_account_id
  name           = "canal-${each.key}"
  type           = "EMAIL"
  destination_id = each.value.id
  product        = "IINT"

  property {
    key   = "subject"
    value = "[${var.project_name}/${var.environment}] {{ issueTitle }}"
  }
}

resource "newrelic_workflow" "oficina" {
  count = length(var.alert_emails) > 0 ? 1 : 0

  account_id            = var.newrelic_account_id
  name                  = "${local.cluster_name} — notificação"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "incidentes-da-oficina"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.oficina.id]
    }
  }

  dynamic "destination" {
    for_each = newrelic_notification_channel.email

    content {
      channel_id = destination.value.id
    }
  }
}
