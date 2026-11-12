# Dashboard da oficina, em quatro páginas que respondem a perguntas diferentes:
#
#   Ordens de serviço     o negócio: quantas entram, quanto tempo levam, onde param
#   API e integrações     a aplicação: latência, erro, e quem quebrou primeiro
#   Infraestrutura        o que sustenta as duas: cluster e banco
#   Consumo do free tier  o que sustenta a observabilidade: os 100 GB/mês
#
# Sobre janelas de tempo: o seletor do dashboard começa em 30 minutos, que não
# serve para painel de volume diário. Onde a janela faz parte da pergunta ela
# está escrita na própria consulta (`SINCE`), e o seletor deixa de valer para
# aquele painel. Nos demais o seletor manda, de propósito — é assim que se
# investiga um incidente estreitando o intervalo.
#
# Sobre as métricas customizadas (`Custom/OrdemServico/*`): são métricas
# timeslice do APM, publicadas pela aplicação (telemetria-ordem-servico.ts).
#   count(newrelic.timeslice.value)    quantas vezes aconteceu
#   average(newrelic.timeslice.value)  média dos valores registrados (segundos)
#   WITH METRIC_FORMAT '.../{x}'       transforma o último segmento do nome em
#                                      atributo `x`, que dá para usar no FACET

locals {
  # Filtro das consultas de métrica customizada da aplicação.
  filtro_app_metric = "appName = '${var.app_new_relic_name}'"

  # Filtro dos logs da aplicação: nome do serviço + tags padrão do projeto.
  filtro_app_log = "servico = '${var.app_new_relic_name}' AND environment = '${local.nr_environment}' AND project = '${local.nr_project}'"
}

resource "newrelic_one_dashboard" "oficina" {
  account_id = var.newrelic_account_id
  name       = "${local.cluster_name} — oficina"

  # Visível para toda a conta. São quatro pessoas no time e ninguém quer
  # descobrir, no meio de um incidente, que o dashboard é privado de quem aplicou.
  permissions = "public_read_only"

  # ══ Página 1 ═════════════════════════════════════════════════════════════
  page {
    name = "Ordens de serviço"

    widget_billboard {
      title  = "Ordens criadas (24h)"
      row    = 1
      column = 1
      width  = 3
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(newrelic.timeslice.value) AS 'ordens criadas'
          FROM Metric
          WHERE ${local.filtro_app_metric}
            AND metricTimesliceName = 'Custom/OrdemServico/Criada'
          SINCE 24 hours ago
        NRQL
      }
    }

    widget_billboard {
      title  = "Ordens entregues (24h)"
      row    = 1
      column = 4
      width  = 3
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(newrelic.timeslice.value) AS 'ordens entregues'
          FROM Metric
          WHERE ${local.filtro_app_metric}
            AND metricTimesliceName = 'Custom/OrdemServico/Transicao/ENTREGUE'
          SINCE 24 hours ago
        NRQL
      }
    }

    widget_billboard {
      title  = "Falhas no processamento (24h)"
      row    = 1
      column = 7
      width  = 3
      height = 3

      # Mesmo sinal e mesmo limiar do alerta: o número que fica vermelho aqui é
      # o mesmo que abre incidente, e não um segundo critério para o time decorar.
      critical = 3
      warning  = 1

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(newrelic.timeslice.value) AS 'falhas'
          FROM Metric
          WHERE ${local.filtro_app_metric}
            AND metricTimesliceName IN (${join(", ", local.metricas_falha_ordem)})
          SINCE 24 hours ago
        NRQL
      }
    }

    widget_billboard {
      title  = "Tempo médio até a entrega (h)"
      row    = 1
      column = 10
      width  = 3
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(newrelic.timeslice.value) / 3600 AS 'horas'
          FROM Metric
          WHERE ${local.filtro_app_metric}
            AND metricTimesliceName = 'Custom/OrdemServico/TempoAteEntrega'
          SINCE 7 days ago
        NRQL
      }
    }

    widget_line {
      title  = "Volume diário de ordens de serviço"
      row    = 4
      column = 1
      width  = 12
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(newrelic.timeslice.value) AS 'ordens criadas'
          FROM Metric
          WHERE ${local.filtro_app_metric}
            AND metricTimesliceName = 'Custom/OrdemServico/Criada'
          TIMESERIES 1 day
          SINCE 30 days ago
        NRQL
      }
    }

    widget_bar {
      title  = "Tempo médio em cada status (minutos)"
      row    = 7
      column = 1
      width  = 6
      height = 3

      # A aplicação registra, a cada transição, quanto tempo a ordem passou no
      # status de onde está SAINDO — medido pelo histórico de status, no mesmo
      # commit da transição. Cobre os quatro caminhos que mudam status
      # (manual, envio de orçamento, decisão do cliente, webhook).
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(newrelic.timeslice.value) / 60 AS 'minutos'
          FROM Metric
          WHERE ${local.filtro_app_metric}
          WITH METRIC_FORMAT 'Custom/OrdemServico/TempoNoStatus/{status}'
          FACET status
          SINCE 7 days ago
        NRQL
      }
    }

    widget_bar {
      title  = "Falhas por etapa (24h)"
      row    = 7
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(newrelic.timeslice.value) AS 'falhas'
          FROM Metric
          WHERE ${local.filtro_app_metric}
          WITH METRIC_FORMAT 'Custom/OrdemServico/Falha/{etapa}'
          FACET etapa
          SINCE 24 hours ago
        NRQL
      }
    }

    widget_line {
      title  = "Tempo em cada status ao longo do tempo (minutos)"
      row    = 10
      column = 1
      width  = 12
      height = 3

      # A mesma medida do gráfico de barras, dia a dia: é aqui que se vê se a
      # oficina está ficando mais lenta em alguma etapa específica.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(newrelic.timeslice.value) / 60
          FROM Metric
          WHERE ${local.filtro_app_metric}
          WITH METRIC_FORMAT 'Custom/OrdemServico/TempoNoStatus/{status}'
          FACET status
          TIMESERIES 1 day
          SINCE 30 days ago
        NRQL
      }
    }

    # ── Investigação ─────────────────────────────────────────────────────────
    # Os números acima são agregados e não dizem QUAL ordem. Os dois painéis
    # abaixo leem o log, que tem ordem_id, correlationId e trace.id.

    widget_table {
      title  = "Transições por status de destino"
      row    = 13
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*) AS 'transições',
                 average(duracao_status_segundos) / 60 AS 'minutos no status anterior'
          FROM Log
          WHERE ${local.filtro_app_log}
            AND evento = 'ordem_servico.status_alterado'
          FACET status_novo, tipo_transicao
          SINCE 7 days ago
        NRQL
      }
    }

    widget_table {
      title  = "Últimas falhas — ponto de partida da investigação"
      row    = 13
      column = 7
      width  = 6
      height = 3

      # `trace.id` leva ao trace distribuído (API ↔ Lambda via W3C); o
      # `correlationId` segue a requisição por todos os logs dela.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT evento, `error.class`, `error.message`, ordem_id, correlationId, `trace.id`
          FROM Log
          WHERE ${local.filtro_app_log}
            AND evento LIKE 'ordem_servico.%_falhou'
          SINCE 24 hours ago
          LIMIT 20
        NRQL
      }
    }
  }

  # ══ Página 2 ═════════════════════════════════════════════════════════════
  page {
    name = "API e integrações"

    widget_billboard {
      title  = "Requisições por minuto"
      row    = 1
      column = 1
      width  = 3
      height = 3

      # Da métrica dimensional do APM, não do evento `Transaction`: os eventos
      # são amostrados acima do teto por pod (ConfigMap da aplicação), e a
      # contagem sairia menor justamente sob carga. A métrica não é amostrada.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT rate(count(apm.service.transaction.duration), 1 minute)
          FROM Metric
          WHERE appName = '${var.app_new_relic_name}'
            AND transactionType = 'Web'
        NRQL
      }
    }

    widget_billboard {
      title  = "Latência p95 (ms)"
      row    = 1
      column = 4
      width  = 3
      height = 3

      critical = var.alerta_latencia_ms

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT percentile(duration, 95) * 1000
          FROM Transaction
          WHERE appName = '${var.app_new_relic_name}'
            AND transactionType = 'Web'
        NRQL
      }
    }

    widget_billboard {
      title  = "Latência p99 (ms)"
      row    = 1
      column = 7
      width  = 3
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT percentile(duration, 99) * 1000
          FROM Transaction
          WHERE appName = '${var.app_new_relic_name}'
            AND transactionType = 'Web'
        NRQL
      }
    }

    widget_billboard {
      title  = "Taxa de erro (%)"
      row    = 1
      column = 10
      width  = 3
      height = 3

      critical = 5
      warning  = 1

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT percentage(count(*), WHERE numeric(`http.statusCode`) >= 500)
          FROM Transaction
          WHERE appName = '${var.app_new_relic_name}'
        NRQL
      }
    }

    widget_line {
      title  = "Latência das APIs — p95 e p99"
      row    = 4
      column = 1
      width  = 12
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT percentile(duration, 95, 99) * 1000
          FROM Transaction
          WHERE appName = '${var.app_new_relic_name}'
            AND transactionType = 'Web'
          TIMESERIES
        NRQL
      }
    }

    widget_table {
      title  = "Endpoints mais lentos (p95, ms)"
      row    = 7
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*) AS 'chamadas',
                 percentile(duration, 95) * 1000 AS 'p95 (ms)'
          FROM Transaction
          WHERE appName = '${var.app_new_relic_name}'
            AND transactionType = 'Web'
          FACET name
          LIMIT 15
        NRQL
      }
    }

    widget_line {
      title  = "Erros da aplicação por classe"
      row    = 7
      column = 7
      width  = 6
      height = 3

      # Com o `noticeError` no filtro global, a classe aqui é a exceção real
      # (PrismaClientKnownRequestError, TypeError...), não um "HttpError 500".
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*)
          FROM TransactionError
          WHERE appName = '${var.app_new_relic_name}'
          FACET `error.class`
          TIMESERIES
        NRQL
      }
    }

    # Integrações: o que a aplicação chama e não controla — banco, e-mail e o
    # webhook de orçamento. Os eventos saem do logger estruturado, no prefixo
    # `integracao.`.
    widget_line {
      title  = "Erros e falhas nas integrações"
      row    = 10
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*)
          FROM Log
          WHERE ${local.filtro_tags}
            AND level = 'error'
            AND evento LIKE 'integracao.%'
          FACET evento
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "Lambda de autenticação — invocações, erros e p95"
      row    = 10
      column = 7
      width  = 6
      height = 3

      # Três consultas no mesmo painel: volume e erro precisam ser lidos juntos,
      # e a duração explica os dois quando o Postgres está lento.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*) AS 'invocações',
                 filter(count(*), WHERE error IS true) AS 'erros',
                 percentile(duration, 95) * 1000 AS 'p95 (ms)'
          FROM AwsLambdaInvocation
          WHERE appName = '${local.lambda_app_name}'
          TIMESERIES
        NRQL
      }
    }

    # Prova visual da correlação W3C Trace Context. Um cliente que envia o mesmo
    # `traceparent` para /auth (Lambda) e para a API gera spans dos dois
    # serviços sob o MESMO trace.id. As linhas com 2 serviços no topo são esses
    # traces; clicar no trace.id abre o trace distribuído completo.
    widget_table {
      title  = "Traces distribuídos Lambda ↔ API (W3C)"
      row    = 13
      column = 1
      width  = 12
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT uniqueCount(appName) AS 'serviços no trace',
                 uniques(appName) AS 'quais',
                 count(*) AS 'spans'
          FROM Span
          WHERE appName IN ('${var.app_new_relic_name}', '${local.lambda_app_name}')
          FACET trace.id
          SINCE 1 hour ago
          LIMIT 20
        NRQL
      }
    }
  }

  # ══ Página 3 ═════════════════════════════════════════════════════════════
  page {
    name = "Infraestrutura"

    widget_line {
      title  = "CPU dos nós (% do alocável)"
      row    = 1
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(allocatableCpuCoresUtilization)
          FROM K8sNodeSample
          WHERE clusterName = '${local.cluster_name}'
          FACET nodeName
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "Memória dos nós (% do alocável)"
      row    = 1
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(allocatableMemoryUtilization)
          FROM K8sNodeSample
          WHERE clusterName = '${local.cluster_name}'
          FACET nodeName
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "CPU por contêiner (cores)"
      row    = 4
      column = 1
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(cpuUsedCores)
          FROM K8sContainerSample
          WHERE clusterName = '${local.cluster_name}'
            AND namespaceName = '${var.app_namespace}'
          FACET containerName
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "Memória por contêiner (MB)"
      row    = 4
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(memoryWorkingSetBytes) / 1e6
          FROM K8sContainerSample
          WHERE clusterName = '${local.cluster_name}'
            AND namespaceName = '${var.app_namespace}'
          FACET containerName
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "Réplicas prontas"
      row    = 7
      column = 1
      width  = 4
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT uniqueCount(podName)
          FROM K8sPodSample
          WHERE clusterName = '${local.cluster_name}'
            AND namespaceName = '${var.app_namespace}'
            AND status = 'Running'
            AND isReady = 1
          TIMESERIES
        NRQL
      }
    }

    widget_table {
      title  = "Reinícios de contêiner"
      row    = 7
      column = 5
      width  = 4
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT sum(restartCountDelta)
          FROM K8sContainerSample
          WHERE clusterName = '${local.cluster_name}'
            AND namespaceName = '${var.app_namespace}'
          FACET containerName, podName
          SINCE 6 hours ago
        NRQL
      }
    }

    # Vem do nri-kube-events. É o painel que transforma "a memória caiu" em
    # "o contêiner foi morto por OOM às 14h07" — e mostra `Unhealthy` quando
    # uma liveness/readiness probe falha.
    widget_table {
      title  = "Eventos do cluster"
      row    = 7
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT count(*)
          FROM InfrastructureEvent
          WHERE clusterName = '${local.cluster_name}'
            AND category = 'kubernetes'
          FACET `event.reason`
          SINCE 6 hours ago
        NRQL
      }
    }

    # ── Banco de dados ──────────────────────────────────────────────────────
    # Coletado pelo nri-postgresql, que roda no cluster e consulta o RDS direto.
    # Sem CloudWatch no caminho, os números vêm de `pg_stat_database` — a mesma
    # fonte que a AWS lia, sem o intermediário.

    widget_line {
      title  = "Postgres — conexões (atuais e teto)"
      row    = 10
      column = 1
      width  = 6
      height = 3

      # `db.connections` é o numbackends do banco. O teto vem junto para o
      # gráfico mostrar a folga, e não só o número absoluto.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT max(`db.connections`) AS 'conexões',
                 latest(`db.maxconnections`) AS 'teto (max_connections)'
          FROM PostgresqlDatabaseSample
          WHERE ${local.filtro_tags}
          TIMESERIES
        NRQL
      }
    }

    widget_line {
      title  = "Postgres — commits e rollbacks por segundo"
      row    = 10
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(`db.commitsPerSecond`) AS 'commits/s',
                 average(`db.rollbacksPerSecond`) AS 'rollbacks/s'
          FROM PostgresqlDatabaseSample
          WHERE ${local.filtro_tags}
          TIMESERIES
        NRQL
      }
    }

    widget_billboard {
      title  = "Postgres — cache hit (%)"
      row    = 13
      column = 1
      width  = 3
      height = 3

      # Fração das leituras servidas pelo shared_buffers. Abaixo de ~95% o banco
      # está indo ao disco com frequência — em db.t4g.micro, com 1 GiB de RAM, é
      # o primeiro sinal de que a instância ficou pequena.
      warning  = 95
      critical = 90

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT sum(`db.bufferHitsPerSecond`) / (sum(`db.bufferHitsPerSecond`) + sum(`db.readsPerSecond`)) * 100 AS 'cache hit %'
          FROM PostgresqlDatabaseSample
          WHERE ${local.filtro_tags}
        NRQL
      }
    }

    # Nomes do PostgreSQL 17 (a versão do banco do OS): a partir do 17
    # o nri-postgresql lê checkpoints de `pg_stat_checkpointer` (prefixo
    # `checkpointer.`) e escrita por backend de `pg_stat_io` (prefixo `io.`).
    # Os nomes `bgwriter.*` antigos dessas duas medidas deixam de existir.
    widget_line {
      title  = "Postgres — buffers e checkpoints"
      row    = 13
      column = 4
      width  = 5
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT average(`bgwriter.buffersWrittenByBackgroundWriterPerSecond`) AS 'buffers pelo bgwriter/s',
                 average(`io.buffersWrittenByBackendPerSecond`) AS 'buffers pelo backend/s',
                 average(`checkpointer.checkpointsScheduledPerSecond`) AS 'checkpoints agendados/s',
                 average(`checkpointer.checkpointsRequestedPerSecond`) AS 'checkpoints forçados/s'
          FROM PostgresqlInstanceSample
          WHERE ${local.filtro_tags}
          TIMESERIES
        NRQL
      }
    }

    widget_markdown {
      title  = "Como conferir os atributos do banco"
      row    = 13
      column = 9
      width  = 4
      height = 3

      text = <<-TEXTO
        Os nomes das métricas de Postgres vêm do próprio `nri-postgresql` e
        mudam entre versões — da integração e do Postgres (o 17 moveu
        checkpoints para `checkpointer.*`). Para listar o que está chegando:

        ```
        SELECT keyset() FROM PostgresqlDatabaseSample SINCE 1 hour ago
        SELECT keyset() FROM PostgresqlInstanceSample SINCE 1 hour ago
        ```

        Painel vazio quase sempre é nome de atributo, não coleta parada — o
        alerta **Banco — integração sem coletar** cobre o segundo caso.
      TEXTO
    }
  }

  # ══ Página 4 ═════════════════════════════════════════════════════════════
  # O free tier corta a ingestão ao passar de 100 GB no mês — e aí todos os
  # painéis e alertas das outras páginas ficam vazios ao mesmo tempo. Esta
  # página existe para que isso seja visto chegando, e para mostrar o que
  # cortar primeiro.
  page {
    name = "Consumo do free tier"

    widget_billboard {
      title  = "GB ingeridos no mês (limite: 100)"
      row    = 1
      column = 1
      width  = 4
      height = 3

      # Mesmos limiares do alerta "Conta — ingestão do mês perto do limite".
      warning  = var.alerta_ingestao_gb.aviso
      critical = var.alerta_ingestao_gb.critico

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT latest(GigabytesIngested) AS 'GB no mês'
          FROM NrMTDConsumption
          WHERE productLine = 'DataPlatform'
          SINCE 1 day ago
        NRQL
      }
    }

    widget_line {
      title  = "Ingestão diária por fonte (GB)"
      row    = 1
      column = 5
      width  = 8
      height = 3

      # `usageMetric` separa log, métrica, APM, spans e infraestrutura. É a
      # resposta para "o que está consumindo a cota".
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT sum(GigabytesIngested)
          FROM NrConsumption
          WHERE productLine = 'DataPlatform'
          FACET usageMetric
          TIMESERIES 1 day
          SINCE 30 days ago
        NRQL
      }
    }

    widget_table {
      title  = "Log — maiores emissores (7 dias)"
      row    = 4
      column = 1
      width  = 6
      height = 3

      # Com o lowDataMode, o Fluent Bit leva namespace e contêiner para a raiz
      # do registro. Um pod no topo desta lista é o primeiro candidato a
      # `fluentbit.io/exclude: "true"` ou a um LOG_LEVEL mais alto.
      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT bytecountestimate() / 1e9 AS 'GB', count(*) AS 'linhas'
          FROM Log
          FACET namespace_name, container_name, servico
          SINCE 7 days ago
          LIMIT 15
        NRQL
      }
    }

    widget_table {
      title  = "Eventos de APM por tipo (7 dias)"
      row    = 4
      column = 7
      width  = 6
      height = 3

      nrql_query {
        account_id = var.newrelic_account_id
        query      = <<-NRQL
          SELECT bytecountestimate() / 1e9 AS 'GB', count(*) AS 'eventos'
          FROM Transaction, TransactionError, Span, AwsLambdaInvocation
          FACET eventType(), appName
          SINCE 7 days ago
        NRQL
      }
    }

    widget_markdown {
      title  = "O que já está economizando — e o que cortar se precisar"
      row    = 7
      column = 1
      width  = 12
      height = 3

      text = <<-TEXTO
        **Já aplicado:** `lowDataMode` no cluster (coleta a cada 30s, sem labels/annotations no log) ·
        kube-system, kube-node-lease e newrelic fora do Fluent Bit · Job de migration e agente de banco
        excluídos por anotação · linhas de log sem o `req` completo (`quietReqLogger`) · 4xx sem stack ·
        encaminhamento de log do APM desligado (sem duplicata) · teto de 2.000 transações e 1.000 spans por
        minuto por pod · banco só com métricas de database · Synthetics a cada 6h.

        **Se o alerta de consumo abrir**, em ordem de impacto: (1) confira a tabela de log acima e exclua o
        maior emissor que não seja a API; (2) reduza `NEW_RELIC_SPAN_EVENTS_MAX_SAMPLES_STORED` no ConfigMap
        da aplicação; (3) suba `LOG_LEVEL` da API para `warn`; (4) aumente `newrelic_postgres_interval` no
        terraform/ do OS.
      TEXTO
    }
  }
}

output "newrelic_dashboard_url" {
  description = "Link direto do dashboard — vale colar no README e no card da entrega."
  value       = newrelic_one_dashboard.oficina.permalink
}
