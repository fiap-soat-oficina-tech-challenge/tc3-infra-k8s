# ─── Chave de ingestão ──────────────────────────────────────────────────────
# Mesmo padrão do DATABASE_URL do OS: o segredo nasce em um lugar só e
# os demais repositórios leem do SSM. Sem isso a license key precisaria estar
# repetida como secret nos quatro repositórios, e rotacioná-la viraria uma
# operação manual em quatro lugares.

locals {
  ssm_prefix = "/${var.project_name}/${var.environment}"

  # Nome com que a Lambda de autenticação se reporta ao APM. Espelha
  # `local.identificador` de tc3-auth-lambda; os dois precisam mudar juntos, ou
  # os alertas de integração ficam olhando para um nome que ninguém publica.
  lambda_app_name = "${var.project_name}-${var.environment}-auth"

  # Tags padrão (environment/project). Atalhos para as consultas NRQL, que as
  # usam como filtro em Log e nas amostras do banco.
  nr_environment = var.newrelic_tags["environment"]
  nr_project     = var.newrelic_tags["project"]

  # Mesmo formato de NEW_RELIC_LABELS do agente de APM — exportado para quem
  # quiser conferir contra o ConfigMap da aplicação.
  newrelic_labels = join(";", [for chave, valor in var.newrelic_tags : "${chave}:${valor}"])

  # ─── Filtros extras do Fluent Bit ─────────────────────────────────────────
  # Com `lowDataMode`, o chart aplica um filtro `nest` que LEVANTA os campos de
  # `kubernetes` para a raiz do registro ANTES dos filtros extras. Um grep por
  # `$kubernetes['namespace_name']` deixa de casar — em silêncio: nada quebra, e
  # kube-system e o próprio coletor continuam indo para o New Relic, gastando a
  # cota. A chave certa depende do modo; por isso ela é calculada aqui.
  fluentbit_chave_namespace = var.newrelic_low_data_mode ? "$namespace_name" : "$kubernetes['namespace_name']"

  fluentbit_extra_filters = join("\n", concat(
    [
      "[FILTER]",
      "    Name    grep",
      "    Alias   descarta-namespaces-de-plataforma",
      "    Match   kube.*",
      "    Exclude ${local.fluentbit_chave_namespace} ^(kube-system|kube-node-lease|newrelic)$",
      "",
      # As tags padrão em todo registro de log do cluster. A aplicação já as
      # escreve no próprio JSON; este filtro cobre o resto (Jobs, qualquer
      # workload futuro), para que nenhum log chegue sem environment/project.
      "[FILTER]",
      "    Name    record_modifier",
      "    Alias   tags-padrao-do-projeto",
      "    Match   *",
    ],
    [for chave, valor in var.newrelic_tags : "    Record  ${chave} ${valor}"],
  ))
}

resource "aws_ssm_parameter" "newrelic_license_key" {
  name        = "${local.ssm_prefix}/NEW_RELIC_LICENSE_KEY"
  description = "Chave de ingestão lida pela aplicação, pela Lambda e pelo agente de banco"
  type        = "SecureString"
  value       = var.newrelic_license_key
}

resource "aws_ssm_parameter" "newrelic_app_name" {
  name        = "${local.ssm_prefix}/NEW_RELIC_APP_NAME"
  description = "Nome da aplicação no APM — mantém o mesmo rótulo em todos os ambientes"
  type        = "String"
  value       = var.app_new_relic_name
}

# ─── Agente de Kubernetes ───────────────────────────────────────────────────
# O nri-bundle agrupa os componentes da solução de Kubernetes. Ligamos apenas os
# quatro que atendem os requisitos e deixamos o resto desligado: Pixie e o agente
# Prometheus sozinhos consomem, num cluster deste tamanho, mais do que os 100 GB
# mensais do free tier.

resource "kubernetes_namespace" "newrelic" {
  metadata {
    name = "newrelic"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "newrelic_bundle" {
  name       = "newrelic-bundle"
  repository = "https://helm-charts.newrelic.com"
  chart      = "nri-bundle"
  version    = "7.0.23"
  namespace  = kubernetes_namespace.newrelic.metadata[0].name

  # O chart cria DaemonSets em todos os nós; em cluster pequeno o agendamento
  # demora mais que o default de 5 minutos.
  timeout = 900

  values = [yamlencode({
    global = {
      cluster     = local.cluster_name
      lowDataMode = var.newrelic_low_data_mode

      # Tags padrão (environment/project) como atributos em toda amostra do
      # agente de Kubernetes — nó, pod, contêiner, eventos. Atenção: o chart
      # de logging NÃO lê esta chave; nos logs as tags entram pelo filtro
      # `record_modifier` do Fluent Bit (local.fluentbit_extra_filters).
      customAttributes = var.newrelic_tags
    }

    # CPU, memória, rede e estado dos pods — o requisito de consumo de recursos.
    "newrelic-infrastructure" = {
      enabled = true

      # Lê cgroups e /proc do host para chegar em uso real de CPU e memória; sem
      # isso o agente reporta só o que a API do Kubernetes já sabe.
      privileged = true
    }

    # O agente deriva daqui o estado declarado (réplicas desejadas, motivo de
    # pod pendente). O cluster não tem uma instalação própria, então sobe junto.
    "kube-state-metrics" = {
      enabled = true
    }

    # Eventos do cluster (OOMKilled, FailedScheduling, BackOff) como eventos
    # consultáveis. É o que dá causa aos alertas de recurso: sem eles o alerta
    # diz que a memória subiu, não que o contêiner foi morto por falta dela.
    "nri-kube-events" = {
      enabled = true
    }

    # Encaminha o stdout dos pods. A aplicação não precisa de nenhuma alteração
    # para os logs chegarem — basta escrever JSON na saída padrão, que o New
    # Relic desestrutura em atributos consultáveis.
    "newrelic-logging" = {
      enabled     = true
      lowDataMode = var.newrelic_low_data_mode

      # O chart já liga esta sonda por padrão (GET /api/v1/health na porta
      # 2020 do Fluent Bit). Declarada aqui para não depender do default de
      # uma versão futura do chart: um coletor travado reinicia em vez de
      # parar de enviar log em silêncio.
      livenessProbe = {
        enabled             = true
        initialDelaySeconds = 10
        periodSeconds       = 30
        timeoutSeconds      = 5
        failureThreshold    = 3
      }

      fluentBit = {
        # Respeita a anotação `fluentbit.io/exclude: "true"` em pods que não
        # devem ser coletados (o Job de migration e o agente de banco usam).
        k8sLoggingExclude = "true"

        config = {
          # O log do próprio coletor entra no seu próprio pipeline e se
          # realimenta; kube-system é ruído de plataforma que não responde a
          # nenhuma pergunta desta entrega. Os dois juntos costumam ser a maior
          # fatia do volume num cluster ocioso. Detalhes em locals, acima.
          extraFilters = local.fluentbit_extra_filters
        }
      }
    }

    # Webhook que injeta NEW_RELIC_METADATA_KUBERNETES_* (cluster, namespace,
    # deployment, pod) nos pods da aplicação. O agente de APM lê essas variáveis
    # e carimba cada transação e cada log com a identidade do workload — é o que
    # liga o APM ao cluster sem o manifesto precisar saber de nada.
    #
    # Não injeta a license key nem o app name: esses dois continuam vindo do
    # Secret e do ConfigMap da aplicação.
    "nri-metadata-injection" = {
      enabled = true
    }

    # Desligados explicitamente. O default do chart já é false para todos, mas
    # deixar registrado evita que uma atualização de chart ligue algo caro sem
    # ninguém notar — e o custo aqui é a conta travar até o mês virar.
    "newrelic-prometheus-agent" = { enabled = false }
    "nri-prometheus"            = { enabled = false }
    "newrelic-pixie"            = { enabled = false }
    "pixie-chart"               = { enabled = false }
    "nr-ebpf-agent"             = { enabled = false }
    "k8s-agents-operator"       = { enabled = false }
    "newrelic-infra-operator"   = { enabled = false }
  })]

  # Fora de `values` para não aparecer no diff do plan nem no comentário do PR.
  # O valor vem de TF_VAR_newrelic_license_key (secret do CI ou .env local).
  set_sensitive {
    name  = "global.licenseKey"
    value = var.newrelic_license_key
  }

  depends_on = [
    module.eks,
    helm_release.metrics_server,
  ]
}

output "newrelic_labels" {
  description = "Tags padrão no formato de NEW_RELIC_LABELS — deve ser idêntico ao do ConfigMap da aplicação."
  value       = local.newrelic_labels
}
