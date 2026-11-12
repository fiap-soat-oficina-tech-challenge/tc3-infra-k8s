# Tags padrão do projeto (var.newrelic_tags → environment/project) nas
# entidades de configuração: dashboard e condições de alerta.
#
# Onde cada fonte de telemetria recebe as MESMAS tags:
#
#   Agente de Kubernetes      global.customAttributes            newrelic.tf
#   Logs do cluster           record_modifier do Fluent Bit      newrelic.tf
#   APM da aplicação          NEW_RELIC_LABELS (ConfigMap)       tech-challenge-fiap
#   Logs da aplicação         `base` do pino, da mesma variável  tech-challenge-fiap
#   Lambda de autenticação    NEW_RELIC_LABELS + atributos       tc3-auth-lambda
#   Agente de banco           NRIA_CUSTOM_ATTRIBUTES             terraform/ do OS
#   Monitor sintético         bloco `tag`                        newrelic-synthetics.tf
#   Dashboard e condições     este arquivo
#
# A política de alertas fica de fora: o provider não expõe o `entity_guid` dela.

locals {
  condicoes_nrql = merge(
    {
      api_latencia            = newrelic_nrql_alert_condition.api_latencia.entity_guid
      api_erros_5xx           = newrelic_nrql_alert_condition.api_erros_5xx.entity_guid
      k8s_cpu                 = newrelic_nrql_alert_condition.k8s_cpu.entity_guid
      k8s_memoria             = newrelic_nrql_alert_condition.k8s_memoria.entity_guid
      k8s_reinicios           = newrelic_nrql_alert_condition.k8s_reinicios.entity_guid
      uptime_pods             = newrelic_nrql_alert_condition.uptime_pods.entity_guid
      banco_conexoes          = newrelic_nrql_alert_condition.banco_conexoes.entity_guid
      banco_sem_coleta        = newrelic_nrql_alert_condition.banco_sem_coleta.entity_guid
      ordens_falhas           = newrelic_nrql_alert_condition.ordens_falhas.entity_guid
      ordens_paradas          = newrelic_nrql_alert_condition.ordens_paradas.entity_guid
      integracao_lambda       = newrelic_nrql_alert_condition.integracao_lambda.entity_guid
      integracao_lambda_lenta = newrelic_nrql_alert_condition.integracao_lambda_lenta.entity_guid
      integracao_banco        = newrelic_nrql_alert_condition.integracao_banco.entity_guid
      consumo_free_tier       = newrelic_nrql_alert_condition.consumo_free_tier.entity_guid
    },
    # Existe só com a URL do monitor configurada. A chave vem da variável (e
    # não do recurso) para ser conhecida já no plan, como o for_each exige.
    var.synthetics_uptime_url != "" ? {
      uptime_externo = newrelic_nrql_alert_condition.uptime_externo[0].entity_guid
    } : {},
  )

  entidades_com_tags = merge(
    { dashboard = newrelic_one_dashboard.oficina.guid },
    { for nome, guid in local.condicoes_nrql : "condicao_${nome}" => guid },
  )
}

resource "newrelic_entity_tags" "padrao" {
  for_each = local.entidades_com_tags

  guid = each.value

  dynamic "tag" {
    for_each = var.newrelic_tags

    content {
      key    = tag.key
      values = [tag.value]
    }
  }
}
