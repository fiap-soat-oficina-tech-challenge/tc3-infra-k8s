# Observabilidade

Métricas, logs, traces e alertas da oficina no New Relic, sem CloudWatch no
caminho. A única exceção é o alerta das DLQs da Saga (seção 5), porque o SQS
não tem agente.

Este documento vale para os cinco repositórios do projeto. Na Fase 4, cada
microsserviço é um app próprio no APM (`oficina-api` para o OS Service,
`oficina-billing` e `oficina-execution`), com o mesmo formato de log, e o
`correlationId` da OS vai em toda mensagem da Saga: filtrar os logs por ele
mostra o fluxo de uma OS nos três serviços (ver [Consultas úteis](#consultas-úteis)). Mora aqui porque é
`tc3-infra-k8s` quem detém a conta do New Relic no Terraform — a chave de
ingestão, os dashboards e as políticas de alerta.

---

## A decisão

O caminho de menor esforço para levar telemetria da AWS ao New Relic é a
integração nativa: CloudWatch Metric Stream → Kinesis Firehose → New Relic para
métrica, e CloudWatch Logs → subscription filter → Lambda de ingestão para log.
Funciona, é o que a documentação do fornecedor recomenda, e foi como este
projeto começou.

Ele foi trocado por um desenho em que **cada agente fala direto com o New
Relic**. Três razões, em ordem de peso:

1. **Custo que não aparece no orçamento.** Firehose cobra por GB ingerido,
   CloudWatch Logs cobra por GB ingerido *e* por GB armazenado, e o log da
   Lambda é cobrado duas vezes — uma na AWS, outra no New Relic. Num ambiente de
   estudo, isso é a maior linha depois do cluster.
2. **Dependência de fornecedor no caminho da telemetria.** Com o Firehose no
   meio, uma mudança de conta AWS obriga a refazer a esteira de observabilidade
   inteira, e não só a infraestrutura.
3. **Latência.** O metric stream agrega em janelas de 60s antes de enviar. O
   agente empurra em segundos — e é a diferença entre o alerta abrir junto com o
   incidente ou três minutos depois.

O preço está pago em [Limitações conhecidas](#limitações-conhecidas). Não é
zero.

---

## Arquitetura

```
   ┌─ EKS ─────────────────────────────────────────────┐
   │                                                   │
   │  pods da API ──stdout──▶ Fluent Bit ──────────┐   │
   │       │                                       │   │
   │       └─── agente APM (Node) ─────────────┐   │   │
   │                                           │   │   │
   │  DaemonSet newrelic-infrastructure ───────┤   │   │
   │  kube-state-metrics · nri-kube-events ────┤   │   │
   │                                           │   │   │
   │  Deployment nri-postgresql ──psql──▶ RDS  │   │   │
   │       └───────────────────────────────────┤   │   │
   └───────────────────────────────────────────┼───┼───┘
                                               │   │
   ┌─ Lambda de autenticação ──────────────┐   │   │
   │  handler ─▶ agente ─▶ extension ──────┼───┤   │
   └───────────────────────────────────────┘   │   │
                                               ▼   ▼
                                          ┌──────────────┐
                                          │  New Relic   │
                                          │  (free tier) │
                                          └──────────────┘
```

Nenhuma seta passa por CloudWatch Logs, Metric Stream ou Firehose. A única exceção é o alerta das DLQs da Saga (seção 5), porque o SQS não tem agente.

### Onde cada peça mora

| Repositório | Arquivo | O que faz |
|---|---|---|
| `tc3-infra-k8s` | `newrelic.tf` | Publica a license key no SSM, instala o `nri-bundle`, filtros e tags do Fluent Bit |
| `tc3-infra-k8s` | `newrelic-dashboard.tf` | Dashboard de quatro páginas (inclui consumo do free tier) |
| `tc3-infra-k8s` | `newrelic-alertas.tf` | Política, condições (inclui consumo do free tier) e notificação por e-mail |
| `tc3-infra-k8s` | `newrelic-tags.tf` | Tags `environment`/`project` no dashboard e nas condições |
| `tc3-infra-k8s` | `newrelic-synthetics.tf` | Monitor externo de disponibilidade |
| `tech-challenge-fiap` (OS) | `terraform/newrelic-postgres.tf` | Usuário de leitura, agente que raspa o RDS do OS, sondas e tags |
| `tc3-auth-lambda` | `infra/lambda.tf` | Layer, wrapper e variáveis da extension (license key por nome de parâmetro SSM) |
| `tc3-auth-lambda` | `infra/apigateway.tf` | CORS liberando os cabeçalhos W3C e expondo `traceresponse` |
| `tc3-auth-lambda` | `src/handler.ts`, `src/observabilidade.ts` | Log JSON com `trace.id`/`span.id`, tags, `traceresponse` W3C |
| `tech-challenge-fiap` | `src/app.module.ts` | Pino: contrato de campos, tags, trace, volume enxuto |
| `tech-challenge-fiap` | `src/common/observability/` | Agente, métricas customizadas, `noticeError`, flush no shutdown |
| `tech-challenge-fiap` | `src/modules/ordem-servico/application/shared/telemetria-ordem-servico.ts` | Métricas e eventos de negócio da OS |
| `tech-challenge-fiap` | `src/infra/database/prisma/repositories/prisma.ordem-servico.repository.ts` | Tempo por status medido no commit da transição |
| `tech-challenge-fiap` | `k8s/app/01-configmap.yaml` | Configuração do agente de APM (sem credencial) |
| `tech-challenge-fiap` | `k8s/app/04-deployment.yaml` | License key por `secretKeyRef`; sondas startup/readiness/liveness |
| `tech-challenge-fiap` | `Dockerfile`, `docker-compose.yml` | Agente carregado por `node -r newrelic`; chaves só em runtime |
| `tech-challenge-fiap` | `.github/workflows/cd.yml` | Sincroniza a license key do SSM para o Secret |

### Credenciais: de onde vêm, por onde passam

Nenhuma credencial está em código, manifesto, Dockerfile ou `.tfvars`
versionado. Cada repositório tem um `.env` na raiz — **ignorado pelo git**
(`.env` e `.env.*` no `.gitignore` dos quatro) — com os valores locais.

```
.env / secret do GitHub ──TF_VAR_newrelic_license_key──▶ tc3-infra-k8s ──▶ SSM (SecureString)
                                                              │                  │
                                         helm set_sensitive ◀─┘                  ├─▶ CD da API ──▶ Secret app-secret ──▶ pod (secretKeyRef)
                                         (nri-bundle)                            ├─▶ terraform/ do OS ──▶ Secret nri-postgresql ──▶ agente de banco
                                                                                 └─▶ extension da Lambda (lê em runtime pelo NOME do parâmetro)
```

Localmente: `set -a; source .env; set +a` antes do `terraform plan` (os `.env`
dos repositórios Terraform mapeiam `TF_VAR_*`); o `docker compose` da API lê o
`.env` sozinho. Com placeholders, o plan de tc3-infra-k8s falha de propósito: o
account ID precisa ser numérico e a license key precisa ter 40 caracteres.

---

## Pré-requisitos

Uma conta gratuita em [newrelic.com/signup](https://newrelic.com/signup) e três
valores dela:

| Valor | Onde achar | Variável do Terraform |
|---|---|---|
| Account ID | canto superior direito da UI, em *Administration* | `newrelic_account_id` |
| User key (`NRAK-…`) | *API keys* → *Create a key* → tipo **User** | `newrelic_api_key` |
| License key | *API keys* → chave do tipo **Ingest - License** | `newrelic_license_key` |

As duas chaves fazem coisas diferentes e trocá-las é o erro mais comum: a *user
key* autoriza a API de configuração (criar dashboard, criar alerta) e a *license
key* autoriza ingestão de telemetria. Trocadas, o `apply` devolve 401.

### O que cadastrar no GitHub

Os workflows mapeiam cada segredo para a variável correspondente no bloco `env:`
— não basta cadastrar o secret. O Terraform lê `TF_VAR_<nome exato da variável>`,
em minúsculas: um secret chamado `TF_VAR_NEWRELIC_API_KEY` definiria uma variável
`NEWRELIC_API_KEY`, que não existe em lugar nenhum, e o `plan` continuaria
pedindo o valor pela entrada padrão até o job estourar o tempo.

**Secrets** (*Settings → Secrets and variables → Actions → Secrets*):

| Nome | Repositórios | Para quê |
|---|---|---|
| `NEW_RELIC_ACCOUNT_ID` | `tc3-infra-k8s`, `tc3-auth-lambda` | provider do Terraform e marcação de trace na Lambda |
| `NEW_RELIC_API_KEY` | `tc3-infra-k8s` | criar dashboard, alertas e monitor |
| `NEW_RELIC_LICENSE_KEY` | `tc3-infra-k8s` | ingestão; daqui vai para o SSM, e os demais repositórios leem de lá |

**Variables** (mesma tela, aba *Variables*) — configuração, não segredo, e por
isso fora dos secrets: mascarar um e-mail de alerta ou a ARN de uma layer pública
só atrapalha quem está depurando o pipeline.

| Nome | Repositório | Efeito se ficar vazia |
|---|---|---|
| `ALERT_EMAILS` | `tc3-infra-k8s` | política sobe sem canal de notificação — os incidentes continuam abrindo no console |
| `SYNTHETICS_UPTIME_URL` | `tc3-infra-k8s` | monitor externo não é criado; os alertas internos de uptime continuam valendo |
| `NEWRELIC_LAYER_ARN` | `tc3-auth-lambda` | **o `plan` falha**, com a explicação na mensagem — de propósito, porque a alternativa é uma função sem instrumentação que ninguém percebe |

`ALERT_EMAILS` é lista e o Terraform a lê como JSON, então o formato é
`["fulano@exemplo.com","sicrano@exemplo.com"]`. O workflow usa `[]` como
fallback: string vazia abortaria o plan com erro de conversão de tipo.

Aplicando da própria máquina, os mesmos valores vão em `terraform.tfvars` — veja
`terraform.tfvars.example` em cada repositório.

### Ordem de aplicação

```
bootstrap  →  tc3-infra-k8s  →  tc3-auth-lambda  →  terraform/ dos serviços
```

A ordem não é sugestão. `tc3-infra-k8s` cria o namespace `newrelic` e publica a
license key no SSM; o `terraform/` do OS monta o agente de banco dentro desse
namespace e lê a chave de lá; `tc3-auth-lambda` lê a mesma chave. Aplicar fora de ordem
falha com "namespace not found" ou "parameter not found".

---

## 1. Kubernetes

`tc3-infra-k8s/newrelic.tf` instala o `nri-bundle` por Helm. O bundle agrupa uma
dúzia de componentes; quatro estão ligados:

| Componente | O que entrega |
|---|---|
| `newrelic-infrastructure` | CPU, memória, rede e disco de nós, pods e contêineres |
| `kube-state-metrics` | Estado declarado: réplicas desejadas, motivo de pod pendente |
| `nri-kube-events` | Eventos do cluster — `OOMKilled`, `FailedScheduling`, `BackOff` |
| `newrelic-logging` | Fluent Bit recolhendo o stdout de todos os pods |

Os demais estão desligados explicitamente, e não por omissão. O default do chart
já é `false` para todos eles, mas uma atualização de chart pode ligar algo caro
sem ninguém notar — e o custo aqui não é uma cobrança extra: é a ingestão do mês
travar ao passar de 100 GB.

Dois ajustes merecem nota:

**`lowDataMode`** sobe o intervalo de coleta de 15s para 30s e descarta atributos
verbosos. Ligado por padrão. Metade dos pontos, metade do volume, e nenhuma
pergunta desta entrega precisa de resolução de 15 segundos.

**Filtro de log do Fluent Bit.** O log do próprio coletor entra no seu próprio
pipeline e se realimenta; `kube-system` é ruído de plataforma. Os dois juntos
costumam ser a maior fatia do volume num cluster ocioso, então saem no filtro.

A chave do filtro depende do `lowDataMode`. Com ele ligado (o default), o chart
aplica um filtro `nest` que **levanta** os campos de `kubernetes` para a raiz do
registro *antes* dos filtros extras — e um grep por `$kubernetes['namespace_name']`
simplesmente não casa. A primeira versão deste filtro tinha exatamente esse
defeito: nada quebrava, e kube-system e o coletor continuavam indo para o New
Relic. Por isso a chave agora é calculada em `newrelic.tf`
(`local.fluentbit_chave_namespace`). Renderizado com `lowDataMode = true`:

```
[FILTER]
    Name    grep
    Alias   descarta-namespaces-de-plataforma
    Match   kube.*
    Exclude $namespace_name ^(kube-system|kube-node-lease|newrelic)$

[FILTER]
    Name    record_modifier
    Alias   tags-padrao-do-projeto
    Match   *
    Record  environment production
    Record  project tech-challenge-fiap
```

Os dois filtros foram executados num Fluent Bit 3.2 com registros simulados: o
de `oficina` passa com as tags acrescentadas; os de `kube-system` e `newrelic`
são descartados. Com a chave antiga, os três passavam.

**Sondas.** O Fluent Bit tem liveness (`/api/v1/health`) declarada em
`newrelic.tf`; o kube-state-metrics traz as suas pelo chart. O agente de
infraestrutura e o nri-kube-events não expõem sonda no chart `nri-bundle` — a
ausência de sinal deles é coberta pelo alerta *Uptime — nenhum pod pronto*, que
abre incidente quando as amostras param de chegar.

---

## 2. Banco de dados

Sem CloudWatch não existe `AWS/RDS`. A monitoria passa a ser feita por um
`Deployment` no cluster rodando a imagem `newrelic/infrastructure-bundle` com a
integração `nri-postgresql` configurada — declarado em
`terraform/newrelic-postgres.tf`, no repositório do OS.

O agente abre conexão no endpoint do RDS e lê `pg_stat_database`,
`pg_stat_bgwriter` e companhia. São as mesmas visões do catálogo que a AWS lê
para montar as métricas do CloudWatch, sem o intermediário.

**Por que este código mora no repositório do banco, e não no do cluster.** O
cluster nasce antes do banco: em `tc3-infra-k8s` o endpoint e a senha do RDS
ainda não existem. Colocar o agente lá exigiria dois `apply` em sequência, com o
primeiro falhando de propósito. No repositório do banco, tudo o que a integração
precisa já está no mesmo `state`.

**Usuário de leitura.** O agente não usa o usuário da aplicação. Um Job de
bootstrap cria `newrelic_monitor` com a role `pg_monitor` — a role que o próprio
Postgres oferece para ferramenta de monitoria: enxerga as visões de estatística
inteiras e nenhuma tabela de negócio.

O Job existe porque criar role exige executar SQL, e o RDS não é alcançável de
fora da VPC — nem do runner do GitHub Actions. De dentro do cluster, que já tem
rota e já está autorizado no security group, é uma linha de `psql`. O SQL é
idempotente: roda de novo a cada rotação de senha e não faz nada quando não há o
que mudar.

Ele traz um custo que vale dizer em voz alta: a credencial de administrador do
banco passa a existir num Secret do namespace `newrelic`. Em ambiente com mais
gente, a alternativa é um bastion executando o SQL uma vez, à mão.

**Sondas do agente.** O servidor de status do agente de infraestrutura escuta
**só em localhost** (`Status.Enable("localhost", port)` no código do agente), e
o kubelet sonda pelo IP do pod — uma sonda `httpGet` falharia sempre e a
liveness deixaria o pod em CrashLoop. As três sondas são `exec` com o `wget` do
BusyBox da imagem:

| Sonda | Endpoint | Por quê |
|---|---|---|
| startup | `/v1/status/ready` | O servidor de status só sobe depois da checagem de rede da inicialização; até 3 min de folga |
| liveness | `/v1/status/ready` | Processo de pé. Não usa `/health`: reiniciar não conserta chave errada |
| readiness | `/v1/status/health` | Devolve 500 com credencial recusada ou backend fora — o pod fica NotReady em vez de Running e mudo |

**Nomes das métricas.** A primeira versão do alerta de conexões e do painel de
banco usava `db.connections.active` e `db.bgwriter.*` — atributos que a
integração não publica; o alerta existia no console sem poder disparar. Os
nomes corretos, conferidos na documentação do `nri-postgresql` e no changelog
da v2.16.0 (suporte ao PostgreSQL 17):

| Medida | Atributo | Evento |
|---|---|---|
| Conexões no banco | `db.connections` | `PostgresqlDatabaseSample` |
| Teto de conexões | `db.maxconnections` | `PostgresqlDatabaseSample` |
| Checkpoints (PG 17+) | `checkpointer.checkpointsScheduledPerSecond`, `checkpointer.checkpointsRequestedPerSecond` | `PostgresqlInstanceSample` |
| Escrita por backend (PG 17+) | `io.buffersWrittenByBackendPerSecond` | `PostgresqlInstanceSample` |
| Escrita pelo bgwriter | `bgwriter.buffersWrittenByBackgroundWriterPerSecond` | `PostgresqlInstanceSample` |

**Conferindo os nomes das métricas.** Os atributos que a integração envia mudam
entre versões. Depois do primeiro apply:

```sql
SELECT keyset() FROM PostgresqlDatabaseSample SINCE 1 hour ago
SELECT keyset() FROM PostgresqlInstanceSample SINCE 1 hour ago
```

Painel de banco vazio quase sempre é nome de atributo, não coleta parada — o
alerta *Banco — integração sem coletar* cobre o segundo caso.

---

## 3. Lambda de autenticação

A layer do New Relic traz duas coisas no mesmo pacote, e a diferença entre elas
é o que torna este desenho possível:

- **o agente Node**, que instrumenta a função;
- **a extension**, um processo do runtime que roda ao lado do handler.

O agente sozinho escreve telemetria no stdout, e alguém precisa recolher — na
receita oficial, um log group do CloudWatch com uma subscription apontando para
uma segunda Lambda de ingestão. A extension recolhe no próprio processo e faz
POST direto na API do New Relic ao fim de cada invocação.

```
handler ──▶ agente ──▶ extension ──HTTPS──▶ New Relic
```

O caminho de saída é a NAT da VPC: a função roda em subnet privada, e sem rota
para a internet a extension acumula telemetria até o timeout e descarta.

### Variáveis injetadas

| Variável | Valor | Para quê |
|---|---|---|
| `NEW_RELIC_LAMBDA_HANDLER` | `index.handler` | O handler real; quem o Lambda chama é o wrapper da layer |
| `NEW_RELIC_LAMBDA_EXTENSION_ENABLED` | `true` | Liga a extension. Desligada, volta a depender do CloudWatch |
| `NEW_RELIC_EXTENSION_SEND_FUNCTION_LOGS` | `true` | **O item central:** push do log da função direto para a API |
| `NEW_RELIC_EXTENSION_SEND_EXTENSION_LOGS` | `false` | O log do agente é diagnóstico dele, não da aplicação |
| `NEW_RELIC_ACCOUNT_ID` | account id | Conta de destino |
| `NEW_RELIC_TRUSTED_ACCOUNT_KEY` | account id | Aceita a entrada `<conta>@nr` do `tracestate` W3C vinda da API |
| `NEW_RELIC_LICENSE_KEY_SSM_PARAMETER_NAME` | **nome** do parâmetro no SSM | A extension lê a chave em runtime. A chave em si não fica na configuração da função nem no state do Terraform |
| `NEW_RELIC_LABELS` | `environment:production;project:tech-challenge-fiap` | Tags padrão — o handler as escreve em todo log e na invocação |
| `NEW_RELIC_DISTRIBUTED_TRACING_EXCLUDE_NEWRELIC_HEADER` | `true` | Propagação só W3C (`traceparent`/`tracestate`) |
| `NEW_RELIC_TELEMETRY_ENDPOINT` | por datacenter | Conta EU enviando para o coletor US recebe 403 em silêncio |
| `NEW_RELIC_LOG_ENDPOINT` | por datacenter | Idem, para o log |
| `NEW_RELIC_DISTRIBUTED_TRACING_ENABLED` | `true` | Liga o trace da autenticação ao da API |
| `NEW_RELIC_NO_CONFIG_FILE` | `true` | Toda a configuração vem daqui; não há `newrelic.js` no bundle |
| `NEW_RELIC_DATA_COLLECTION_TIMEOUT` | `5s` | Acima disso, telemetria passa a atrasar resposta ao cliente |

### Correlação W3C Trace Context

A Lambda e a API falam o padrão W3C (`traceparent` / `tracestate`), e não só o
cabeçalho proprietário do New Relic — qualquer cliente ou ferramenta que
propague W3C costura as duas pontas no mesmo trace.

```
cliente ──traceparent: 00-<trace-id>-<span>-01──▶ API Gateway ──▶ Lambda /auth
   │                                                               │ agente adota <trace-id>
   │◀─────────── traceresponse: 00-<trace-id>-<span-da-lambda>-01 ─┘
   │
   └──traceparent: 00-<trace-id>-...──▶ API Gateway ──▶ ALB ──▶ API (EKS)
                                                                  │ agente adota <trace-id>
```

| Peça | Onde | O que faz |
|---|---|---|
| Entrada | agente da layer / agente Node da API | Lê `traceparent`/`tracestate` do evento do API Gateway (Lambda) e da requisição HTTP (API) e adota o trace-id recebido |
| Saída | `NEW_RELIC_DISTRIBUTED_TRACING_EXCLUDE_NEWRELIC_HEADER=true` | Propaga só os cabeçalhos W3C |
| Confiança | `NEW_RELIC_TRUSTED_ACCOUNT_KEY` | Aceita a entrada `<conta>@nr` do `tracestate` e mantém a amostragem da origem |
| CORS | `apigateway.tf` | Libera `traceparent`, `tracestate`, `newrelic` e `x-correlation-id` no preflight — sem isso o navegador descarta os cabeçalhos antes de enviar |
| Resposta | `handler.ts` | Devolve `traceresponse` (W3C Level 2) com o trace da invocação, e o CORS o expõe ao front |
| Log | `handler.ts` / `app.module.ts` | `trace.id` e `span.id` em toda linha — liga log ↔ trace |

O `correlationId` segue a mesma ideia do lado dos logs: a Lambda reaproveita o
`x-correlation-id` do cliente (validado: formato de id, até 128 caracteres),
como a API já fazia.

A API foi verificada rodando a imagem com o agente ligado: enviando
`traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-…`, as linhas de log da
requisição saem com `"trace.id":"4bf92f3577b34da6a3ce929d0e0e4736"`. Na AWS, o
teste equivalente está em [Verificação depois do deploy](#verificação-depois-do-deploy).

### O log group não existe mais

Ligar a extension não basta: a Lambda continua criando e alimentando o log group
do CloudWatch por conta própria, porque a política gerenciada
`AWSLambdaVPCAccessExecutionRole` embute `logs:CreateLogGroup` e
`logs:PutLogEvents`.

A política foi trocada por uma própria, com as permissões de ENI e sem `logs`.
Sem permissão de escrita, não há log group e não há cobrança.

O efeito colateral é real: o CloudWatch fica vazio de verdade, inclusive quando
a extension é quem falha. Para esse caso, `cloudwatch_logs_enabled = true`
devolve o comportamento padrão em um `apply`.

### Layer

A ARN muda por região e a cada release do agente, e não dá para descobrir por
data source: a layer é pública mas mora na conta `451483290750`, e a API só
lista versões de layer da própria conta. A lista publicada está em
<https://layers.newrelic-external.com> — procurar `NewRelicNodeJS22X` na região
do projeto.

```hcl
newrelic_layer_arn = "arn:aws:lambda:us-east-1:451483290750:layer:NewRelicNodeJS22X:NN"
```

O `apply` falha com mensagem explicando isso se a variável ficar vazia com
`newrelic_enabled = true`.

O agente **não** entra no pacote da função: o `esbuild` o marca como externo
(`--external:newrelic`) e o `require` resolve em runtime a partir de
`/opt/nodejs/node_modules`, que é onde a layer monta.

---

## 4. Aplicação: log estruturado e correlação

A aplicação já entrava nesta entrega com `nestjs-pino` configurado: JSON no
stdout e um `correlationId` por requisição, reaproveitado do cabeçalho
`x-correlation-id` quando a chamada vem do API Gateway ou da Lambda. O que
faltava era a outra metade da correlação — ligar cada linha ao trace do APM — e
os eventos de negócio que sustentam os painéis.

Nada disso trocou o logger. Um segundo logger conviveria mal com o primeiro:
duas configurações de nível, dois formatos e o dobro de volume.

O agente sobe por `node -r newrelic dist/src/main.js` — antes de qualquer módulo
da aplicação. É essa ordem que permite a ele instrumentar Express e Prisma no
momento em que são importados; carregado depois, o agente sobe e não enxerga
nada.

### O que foi acrescentado ao pino

Em `src/app.module.ts`, quatro ajustes na configuração existente. Três deles
parecem cosméticos e não são: com os nomes padrão do pino, o log chega ao New
Relic e é indexado errado.

| Opção | De | Para | Por quê |
|---|---|---|---|
| `messageKey` | `msg` | `message` | `message` é o campo que o New Relic trata como corpo do log. Com outro nome, a lista mostra o JSON cru |
| `formatters.level` | `30`, `50` | `"info"`, `"error"` | Nível numérico não é mapeado para severidade |
| `timestamp` | `time` | `timestamp` | `time` não é reconhecido: o registro assumiria o horário de ingestão, e um atraso no Fluent Bit reordenaria a linha do tempo justamente durante um incidente |
| `base` | `pid`, `hostname` | `servico`, `environment`, `project` | Os atributos por onde alertas e painéis filtram — escritos pela aplicação, a partir de `NEW_RELIC_LABELS` (a mesma variável das tags da entidade no APM) |
| `quietReqLogger` + `serializers` | `req` inteiro em toda linha | só `correlationId`; `req` = método + rota na linha de conclusão | Headers, query e IP deixam de se repetir em cada linha (0,6–1 KB por linha, estimado) e a placa da consulta pública não vai para o log |

E o quinto, que é o ponto da tarefa:

```ts
mixin: () => metadadosDeTrace(),
```

`metadadosDeTrace()` devolve `newrelic.getLinkingMetadata()`. O `mixin` do pino
roda a cada linha, então **todo** log da aplicação — inclusive os que o Nest
emite por conta própria — sai carimbado com a identidade do trace.

### Contrato de campos

Um JSON por linha no stdout. O Fluent Bit quebra por linha e o New Relic
desestrutura o JSON em atributos consultáveis.

| Campo | Exemplo | De onde vem |
|---|---|---|
| `message` | `"ordem_servico.criada"` | Corpo do log. Nome obrigatório |
| `level` | `info` \| `warn` \| `error` | Severidade. Filtro dos alertas |
| `servico` | `oficina-api`, `auth-lambda` | `base` do pino / literal na Lambda |
| `environment` | `production` | `NEW_RELIC_LABELS` (ConfigMap / variável da Lambda) |
| `project` | `tech-challenge-fiap` | `NEW_RELIC_LABELS` (ConfigMap / variável da Lambda) |
| `timestamp` | epoch ms | `timestamp` do pino |
| `correlationId` | UUID | `customProps` do pino-http, preso ao logger da requisição |
| `evento` | `ordem_servico.criada` | Hierárquico: os painéis filtram por prefixo com `LIKE` |
| `trace.id` | `9a1c…` | **`getLinkingMetadata()`** — liga o log ao trace distribuído |
| `span.id` | `4f70…` | **`getLinkingMetadata()`** — liga o log à operação exata |
| `entity.guid` / `entity.name` | | **`getLinkingMetadata()`** — liga o log à aplicação no APM |
| `error.message` / `error.class` / `error.stack` | | `registrarFalha()`, nos nomes que o New Relic correlaciona com o erro no APM |

Os campos de dados de cada evento vão em `snake_case`, para casar com o jeito
que a consulta NRQL os referencia.

### Como fica na prática

```json
{"level":"info","timestamp":1789243924881,"servico":"oficina-api",
 "environment":"production","project":"tech-challenge-fiap",
 "correlationId":"7d2f…","trace.id":"9a1c…","span.id":"4f70…",
 "entity.guid":"MzQ…","entity.name":"oficina-api","hostname":"oficina-api-7d9f-2xk",
 "evento":"ordem_servico.status_alterado","ordem_id":"os-1","codigo":"OS-2026-000042",
 "status_anterior":"EM_DIAGNOSTICO","status_novo":"AGUARDANDO_APROVACAO",
 "tipo_transicao":"AVANCO","usuario_id":"u-3",
 "duracao_status_segundos":1840,"duracao_total_segundos":5230,
 "message":"ordem_servico.status_alterado"}
```

Com `trace.id` no registro, o pulo entre log e trace funciona nos dois sentidos:
do log para o trace, e do trace para todos os logs emitidos dentro dele.

### Eventos de negócio sem injetar logger

Um evento de negócio precisa do logger **da requisição** — é ele que carrega o
`correlationId`. Injetar `PinoLogger` no construtor de cada caso de uso
resolveria, ao custo de mudar a assinatura de todos eles e dos seus testes, só
para registrar log.

A saída está em `src/common/observability/telemetria.ts`: o bootstrap chama
`configurarTelemetria(app.get(PinoLogger))` uma vez, e os casos de uso usam
`registrarEvento()` / `registrarFalha()` como funções de módulo. O `PinoLogger`
do nestjs-pino resolve, a cada chamada, o logger da requisição corrente via
AsyncLocalStorage — guardar a instância não congela contexto nenhum.

Efeito colateral útil: em teste unitário ninguém chama `configurarTelemetria`, e
as funções viram no-op. A saída do jest fica limpa sem precisar de mock.

### Encaminhamento de log: um caminho só

O agente de APM sabe encaminhar log por conta própria. Fica **desligado**
(`NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=false`): o Fluent Bit do
`nri-bundle` já recolhe o stdout do pod, e ligar os dois enviaria cada linha
duas vezes. O teto de 100 GB/mês é compartilhado entre tudo.

O `local_decorating` também fica desligado — ele anexaria os mesmos campos de
trace como texto solto no fim da linha, quebrando o JSON que o `mixin` já
monta direito.

### Eventos emitidos

| Evento | Onde | Alimenta |
|---|---|---|
| `ordem_servico.criada` | `create-ordem-servico.use-case.ts` | Investigação (a contagem vem da métrica) |
| `ordem_servico.status_alterado` | `prisma.ordem-servico.repository.ts` (commit da transição) | Tabela de transições, investigação |
| `ordem_servico.criacao_falhou` / `transicao_status_falhou` | caso de uso / repositório | Tabela "Últimas falhas" |
| `ordem_servico.criacao_rejeitada` (`warn`) | `create-ordem-servico.use-case.ts` | Regra de negócio recusou (estoque, serviço inativo) — **não** é falha |
| `integracao.email.falha` | `transicionar-status.use-case.ts` | Painel de integrações |
| `integracao.banco.falha` | `handler.ts` da Lambda | Alerta de acesso ao banco |
| `api.erro_interno` | `all-exceptions.filter.ts` | Erros 5xx com stack (também vão ao Errors Inbox via `noticeError`) |
| `auth.*` | `handler.ts` da Lambda | Funil de autenticação |
| `aplicacao.iniciada` / `aplicacao.falha_ao_iniciar` | `main.ts` | Rastro de rollout |

Validação que devolve 404 ou 422 **não** emite evento de falha: cliente sem
cadastro ou peça sem estoque é operação normal da oficina, não defeito do
sistema. Misturar os dois é o que faz um alerta perder credibilidade.

Nenhum evento carrega CPF ou placa. O log sai do cluster para um serviço
externo, e nenhuma pergunta do dashboard exige dado pessoal para ser respondida.

### Métricas customizadas

Os mesmos acontecimentos também saem como **métricas customizadas do APM**
(`newrelic.incrementMetric` / `recordMetric`), emitidas junto com o evento de log
por `application/shared/telemetria-ordem-servico.ts`. São elas que sustentam os
painéis de negócio e o alerta de falhas: agregadas no processo e enviadas a cada
60s, custam uma fração do volume do log e não dependem do Fluent Bit.

| Métrica (no New Relic) | Tipo | Quando |
|---|---|---|
| `Custom/OrdemServico/Criada` | contador | Ordem criada |
| `Custom/OrdemServico/TempoNoStatus/<STATUS>` | valor (s) | Em cada transição, tempo que a ordem passou no status de onde saiu |
| `Custom/OrdemServico/Transicao/<STATUS>` | contador | Transição para `<STATUS>` |
| `Custom/OrdemServico/TempoAteEntrega` | valor (s) | Avanço para `ENTREGUE`: lead time da abertura à entrega |
| `Custom/OrdemServico/Falha/<etapa>` | contador | Falha de sistema em `criacao` ou `transicao_status` |

O código passa os nomes **sem** `Custom/`: o agente acrescenta o prefixo sozinho
(conferido no código do agente, `api.js`). Consulta:

```sql
FROM Metric SELECT average(newrelic.timeslice.value) / 60
WHERE appName = 'oficina-api'
WITH METRIC_FORMAT 'Custom/OrdemServico/TempoNoStatus/{status}'
FACET status SINCE 7 days ago
```

Cardinalidade controlada: o único segmento variável é o status (6 valores) ou a
etapa (2). ID de ordem nunca entra em nome de métrica.

No desligamento (SIGTERM do rollout ou do scale-in do HPA), `TelemetriaShutdown`
chama `newrelic.shutdown({ collectPendingData: true })` — sem isso, cada pod
removido descartava até 60s de métricas.

#### Tempo por status

A duração sai do histórico de status, e não do `updatedAt` da ordem: qualquer
edição — acrescentar um serviço, corrigir a observação — mexe no `updatedAt`, e
o número passaria a medir "tempo desde a última alteração", que não é a
pergunta. O histórico só recebe registro em transição, então a diferença entre a
última entrada e a nova é exatamente o tempo que a ordem passou no status de
onde está saindo.

A medição é feita em `PrismaOrdemServicoRepository.transicionarStatus`, **dentro
da mesma transação** que grava a transição, e emitida só depois do commit. É o
único ponto por onde passam os quatro caminhos que mudam status — transição
manual, envio de orçamento, decisão do cliente e webhook de orçamento. A versão
anterior media só a transição manual, e o tempo em `AGUARDANDO_APROVACAO` (que
sai por decisão do cliente ou webhook) nunca aparecia no painel.

### Volume de log

O `pino-http` prendia o objeto `req` inteiro ao logger da requisição — método,
URL, query, headers, IP e porta repetidos em **toda** linha emitida dentro dela.
Agora, com `quietReqLogger`, as linhas de dentro da requisição levam só o
`correlationId`, e a linha de conclusão leva `req` reduzido a método e rota (sem
query string — a consulta pública recebe a placa por ela). Na verificação local
com a imagem da API, o tamanho médio ficou em ~320 bytes por linha.

Outras duas fontes de volume cortadas na aplicação: 4xx deixou de ser logado em
`error` com stack (1–2 KB por 401/404) e passou a `warn` com uma linha; e a
imagem sobe com `node` direto, sem as linhas em texto puro do `npm run` e do
`prisma migrate` no stdout.


## 5. Dashboard e alertas

### Dashboard

Quatro páginas, cada uma respondendo a uma pergunta diferente. O link sai no
output `newrelic_dashboard_url` depois do apply.

| Página | Painéis |
|---|---|
| **Ordens de serviço** | Criadas, entregues e falhas em 24h · tempo até a entrega · volume diário · tempo médio em cada status (barras e série diária) · falhas por etapa — tudo sobre as métricas customizadas · transições por destino e últimas falhas (log, para investigação) |
| **API e integrações** | p95 e p99 · throughput (métrica não amostrada) · taxa de erro · endpoints mais lentos · erros por classe · falhas de integração · Lambda de autenticação · traces distribuídos Lambda ↔ API (W3C) |
| **Infraestrutura** | CPU e memória de nós e contêineres · réplicas prontas · reinícios · eventos do cluster · conexões e teto, commits/rollbacks, cache hit e checkpoints do Postgres |
| **Consumo do free tier** | GB no mês · ingestão diária por fonte · maiores emissores de log · eventos de APM por tipo · o que cortar primeiro |

Dashboard e condições de alerta recebem as tags `environment`/`project` por
`newrelic-tags.tf`; o monitor sintético, pelo próprio bloco `tag`.

O seletor de tempo do dashboard começa em 30 minutos, que não serve para painel
de volume diário. Onde a janela faz parte da pergunta ela está escrita na
consulta (`SINCE`), e o seletor deixa de valer para aquele painel. Nos demais o
seletor manda — é assim que se investiga um incidente, estreitando o intervalo.

### Condições de alerta

| Condição | Sinal | Gatilho |
|---|---|---|
| API — latência p95 alta | `Transaction` (APM) | p95 > 2000 ms por 5 min |
| API — respostas 5xx | `Transaction` | > 5 em 5 min |
| Ordem de serviço — falhas no processamento | `Metric` (`Custom/OrdemServico/Falha/*`) | > 3 em 5 min (aviso em > 0) — só falha de sistema, não rejeição de negócio |
| Ordem de serviço — fluxo parado | `Metric` (`Custom/OrdemServico/Transicao/*`) | nenhuma transição em 1h, janela vazia conta como 0 *(nasce desligada)* |
| Conta — ingestão do mês perto do limite | `NrMTDConsumption` | aviso > 70 GB, crítico > 85 GB |
| Integração — erros na Lambda | `AwsLambdaInvocationError` | > 3 em 5 min |
| Integração — Lambda lenta | `AwsLambdaInvocation` | p95 > 3000 ms |
| Integração — falhas de acesso ao banco | `Log` | > 3 em 5 min |
| Banco — conexões perto do teto | `PostgresqlDatabaseSample` | > 80 conexões |
| Banco — integração sem coletar | ausência de dado | sem amostra por 15 min |
| Kubernetes — CPU / memória do nó | `K8sNodeSample` | > 85% por 5 min |
| Kubernetes — contêiner reiniciando | `K8sContainerSample` | > 2 reinícios em 5 min |
| Uptime — nenhum pod pronto | `K8sPodSample` | zero réplicas prontas, ou 10 min sem sinal |
| Uptime — healthcheck externo | `SyntheticCheck` | qualquer falha *(se a URL estiver configurada)* |
| Mensageria — mensagem na DLQ | `Metric` (`aws.sqs.ApproximateNumberOfMessagesVisible`, via Metric Stream) | qualquer mensagem em uma das três DLQs da Saga, com um sinal por fila |

Duas escolhas de desenho valem explicação.

**Uptime é medido por dentro, não pelo monitor externo.** O free tier dá 500
checks por mês; a cada 6 horas cabe, a cada minuto não. Detectar queda em seis
horas não serve, então quem sustenta o alerta de queda é a condição sobre pods
prontos, que roda a cada minuto e não consome cota. O monitor externo cobre o
que nenhum sinal de dentro cobre: DNS, validade do certificado e o caminho pela
internet pública.

**Ausência de sinal conta como violação.** `below 1` só fecha se o dado chegar —
com o cluster inteiro fora, não chega nada. Por isso a condição de uptime tem
`expiration_duration = 600` com `open_violation_on_expiration`: cluster
destruído, agente morto ou ingestão cortada por limite de conta são todos "está
fora" na prática.

**Log e banco filtram pelas tags `environment` e `project`, não por
`cluster_name`.** Os atributos que o Fluent Bit acrescenta vêm em `snake_case`
(`cluster_name`, `namespace_name`) enquanto os eventos de Kubernetes usam
`camelCase` (`clusterName`, `namespaceName`). Misturar as duas convenções é o
jeito mais rápido de escrever uma condição que nunca dispara. As tags padrão
são escritas por nós — aplicação, Lambda e agente de banco — e não têm essa
ambiguidade.

**A DLQ é lida do CloudWatch.** O SQS não tem agente que empurre métrica, então
o alerta das DLQs (`oficina-os-saga-replies-dlq`, `oficina-billing-commands-dlq`
e `oficina-execution-commands-dlq`) usa o Metric Stream da conta, da stack
`NewRelic-Metric-Streams` criada à mão. É a dependência que o resto do desenho
evita, aceita aqui porque a alternativa seria cada serviço adivinhar a última
tentativa de uma mensagem. Sem o stream, a condição fica sem dado e não dispara:
remover a stack desliga este alerta. Mensagem na DLQ significa que a Saga parou
naquela OS. O conserto é corrigir a causa e fazer o *redrive* para a fila de
origem, e os consumidores são idempotentes, então reprocessar é seguro.

### Tags padrão

Toda telemetria carrega `environment: production` e `project: tech-challenge-fiap`:

| Fonte | Mecanismo | Arquivo |
|---|---|---|
| Agente de Kubernetes | `global.customAttributes` | `newrelic.tf` |
| Logs do cluster | `record_modifier` do Fluent Bit | `newrelic.tf` |
| APM da API | `NEW_RELIC_LABELS` | `k8s/app/01-configmap.yaml` |
| Logs da API | `base` do pino, lido de `NEW_RELIC_LABELS` | `src/app.module.ts` |
| Lambda | `NEW_RELIC_LABELS` → log + `addCustomAttributes` na invocação | `infra/lambda.tf`, `src/handler.ts` |
| Agente de banco | `NRIA_CUSTOM_ATTRIBUTES` | `newrelic-postgres.tf` |
| Dashboard e condições | `newrelic_entity_tags` | `newrelic-tags.tf` |
| Monitor sintético | bloco `tag` | `newrelic-synthetics.tf` |

Os valores estão em `newrelic_tags` nos três repositórios de infraestrutura e em
`NEW_RELIC_LABELS` no ConfigMap — os quatro precisam mudar juntos.

`newrelic_tags` é **separada** de `environment` de propósito: aquela compõe o
nome do cluster, do RDS e do prefixo do SSM (`homolog`), e trocá-la por
`production` recriaria a infraestrutura inteira, com perda do banco. As tags
só mudam como a telemetria é rotulada.

Também de propósito, as tags **não** entram no `default_tags` da AWS: o IAM
trata chave de tag sem distinguir maiúsculas, e `project` ao lado do `Project`
que já existe faria o apply de toda role falhar com "Duplicate tag keys".

### Notificação

Um destino por endereço — o tipo `EMAIL` do New Relic não aceita lista. Com
`alert_emails = []` a política sobe sem canal, o que é útil enquanto os limiares
ainda estão sendo calibrados.

---

## Consultas úteis

```sql
-- A requisição inteira, ponta a ponta
SELECT * FROM Log WHERE correlationId = 'COLE-AQUI' SINCE 1 day ago

-- Fase 4: o fluxo de uma OS nos três serviços. Atrás do ALB, o correlationId é
-- o X-Amzn-Trace-Id (Self=...;Root=...), então o filtro usa o Root
SELECT timestamp, servico, evento, message FROM Log
WHERE correlationId LIKE '%Root=COLE-AQUI%' SINCE 1 day ago

-- Quantas linhas de cada serviço o fluxo de uma OS gerou
SELECT count(*) FROM Log WHERE correlationId LIKE '%Root=COLE-AQUI%' FACET servico SINCE 1 day ago

-- Todos os logs emitidos dentro de um trace
SELECT * FROM Log WHERE `trace.id` = 'COLE-AQUI'

-- O que mais falhou nas últimas 24h
SELECT count(*) FROM Log WHERE level = 'error' FACET evento SINCE 1 day ago

-- Onde as ordens estão parando (métrica customizada)
FROM Metric SELECT average(newrelic.timeslice.value) / 60 WHERE appName = 'oficina-api'
WITH METRIC_FORMAT 'Custom/OrdemServico/TempoNoStatus/{status}' FACET status SINCE 7 days ago

-- Métricas customizadas que a aplicação está publicando
SELECT uniques(metricTimesliceName) FROM Metric
WHERE appName = 'oficina-api' AND metricTimesliceName LIKE 'Custom/%' SINCE 1 day ago

-- Traces que atravessam Lambda e API (correlação W3C)
SELECT uniqueCount(appName), uniques(appName) FROM Span
WHERE appName IN ('oficina-api', 'tc3-oficina-homolog-auth') FACET trace.id SINCE 1 hour ago

-- Endpoints mais lentos
SELECT percentile(duration, 95, 99) * 1000 FROM Transaction
WHERE appName = 'oficina-api' FACET name SINCE 1 hour ago

-- Autenticação: volume, erro e cauda
SELECT count(*), filter(count(*), WHERE error IS true), percentile(duration, 95)
FROM AwsLambdaInvocation WHERE appName LIKE '%-auth' SINCE 1 day ago

-- Quanto de cada fonte está sendo ingerido (o que consome o free tier)
FROM NrConsumption SELECT sum(GigabytesIngested) WHERE productLine = 'DataPlatform'
FACET usageMetric SINCE 30 days ago

-- Acumulado do mês (o número que o alerta de consumo acompanha)
FROM NrMTDConsumption SELECT latest(GigabytesIngested) WHERE productLine = 'DataPlatform'
```

---

## Verificação depois do deploy

```bash
# Agentes de pé
kubectl get pods -n newrelic

# O agente de banco conectou?
kubectl logs -n newrelic deploy/nri-postgresql --tail=50

# O Job de bootstrap rodou?
kubectl get job -n newrelic nr-postgres-bootstrap

# A aplicação está reportando ao APM? Toda linha deve ser JSON
kubectl logs -n oficina deploy/oficina-api --tail=50 | jq -c '{level, environment, project, "trace.id"}'

# Sondas: nenhum evento Unhealthy recente
kubectl get events -n oficina --field-selector reason=Unhealthy
kubectl get pods -n newrelic -l app.kubernetes.io/name=nri-postgresql   # READY 1/1

# Correlação W3C: o trace-id enviado volta no traceresponse da Lambda...
TRACE=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8)
curl -si -X POST "$API_GATEWAY/auth" \
  -H "traceparent: 00-${TRACE}-${SPAN}-01" -H 'content-type: application/json' \
  -d '{"cpf":"<cpf-cadastrado>"}' | grep -i '^traceresponse'   # 00-${TRACE}-…-01
# ...e a chamada seguinte à API, com o mesmo trace-id, cai no mesmo trace:
curl -s "$API_GATEWAY/ordens-servico/minhas" -H "authorization: Bearer <token>" \
  -H "traceparent: 00-${TRACE}-$(openssl rand -hex 8)-01" >/dev/null
# No New Relic: SELECT uniques(appName) FROM Span WHERE trace.id = '<TRACE>'
```

Na UI do New Relic, em ordem:

1. **APM & Services** → `oficina-api` e `tc3-oficina-homolog-auth` aparecem.
2. **Kubernetes** → o cluster aparece com nós e pods.
3. **Logs** → filtrar por `servico = 'oficina-api'`; abrir uma linha e conferir
   se o link para o trace distribuído está lá.
4. **Dashboards** → `tc3-oficina-homolog — oficina`, quatro páginas com dado.
5. **Alerts** → a política com todas as condições e nenhum incidente aberto.

Se o APM aparece e o log não, o problema é Fluent Bit. Se o log aparece sem
`trace.id`, o problema é o agente não ter subido antes da aplicação — conferir
se o comando é `node -r newrelic`.

---

## Custo

O free tier dá 100 GB de ingestão por mês. Passar disso não gera cobrança: a
ingestão **para** até o mês virar, o que é pior. As decisões que mantêm o
consumo baixo:

| Decisão | Onde |
|---|---|
| `lowDataMode` no agente de Kubernetes | `newrelic.tf` |
| Pixie, agente Prometheus e eBPF desligados | `newrelic.tf` |
| `kube-system`, `kube-node-lease` e `newrelic` fora da coleta de log (filtro corrigido para o `lowDataMode`) | `newrelic.tf` |
| Job de migration e agente de banco excluídos por `fluentbit.io/exclude` | `03-migration-job.yaml`, `newrelic-postgres.tf` |
| Encaminhamento de log do APM desligado (default do agente v12 é ligado; evita duplicata) | `01-configmap.yaml`, `Dockerfile` |
| Linhas de log sem o `req` completo (`quietReqLogger`) e sem query string | `src/app.module.ts` |
| 4xx em `warn`, sem stack | `all-exceptions.filter.ts` |
| stdout só com JSON (`node` direto no CMD; `dotenv` silencioso) | `Dockerfile`, `env.ts` |
| `LOG_LEVEL=info` explícito | `01-configmap.yaml` |
| Teto de 2.000 transações e 1.000 spans por minuto por pod | `01-configmap.yaml` |
| Métricas de negócio como métrica customizada (agregada) em vez de só log | `telemetria-ordem-servico.ts` |
| Banco: só métricas de database, não de tabela e índice | `newrelic-postgres.tf` |
| Amostras de host do agente de banco desligadas | `newrelic-postgres.tf` |
| Log da extension da Lambda não enviado | `lambda.tf` |
| Synthetics a cada 6h (500 checks/mês) | `newrelic-synthetics.tf` |
| **Alerta de consumo** em 70 / 85 GB e página "Consumo do free tier" | `newrelic-alertas.tf`, `newrelic-dashboard.tf` |

Na AWS, o desenho elimina: Firehose (por GB), CloudWatch Logs da Lambda (por GB
ingerido e armazenado), export do log do Postgres para o CloudWatch e o bucket
S3 de rejeitados do Firehose.

Para acompanhar o consumo, a página **Consumo do free tier** do dashboard.

---

## Limitações conhecidas

Sair do CloudWatch tem preço. O que se perdeu, e o que ficou no lugar:

| Perdido | Substituto | Diferença que importa |
|---|---|---|
| `aws.applicationelb.TargetResponseTime` | `Transaction.duration` do APM | O APM conta do momento em que o Node aceita a requisição; não inclui fila de conexão no balanceador nem tempo de rede. O número fica um pouco abaixo do que o cliente sente — o monitor de Synthetics cobre a diferença |
| `aws.applicationelb.HealthyHostCount` | pods prontos + Synthetics | Some o sinal do meio do caminho. Um ALB com target group mal configurado e pods saudáveis só apareceria no monitor externo, que roda a cada 6h |
| `aws.apigateway.*` | — | O API Gateway não é instrumentável por agente. Latência e erro dele passam a ser inferidos pelas pontas |
| `aws.rds.*` | `nri-postgresql` | Ganha cache hit ratio, locks e bloat por tabela; perde o que só o hipervisor enxerga, como `BurstBalance` do EBS e CPU da instância |
| `aws.lambda.*` | `AwsLambdaInvocation` | Praticamente equivalente e mais rápido. Fica de fora o que acontece antes do handler existir — falha de inicialização do runtime, throttling |

Nenhuma dessas lacunas é cega por completo: todas têm um sinal adjacente que
denuncia o problema mais devagar. É uma troca consciente de granularidade por
custo e independência, e está registrada aqui para não ser redescoberta no meio
de um incidente.

---

## Para voltar atrás

O desenho anterior, com Metric Stream e Firehose, está no histórico do
repositório. Reverter significa restaurar `newrelic-aws.tf`, devolver
`enabled_cloudwatch_logs_exports` ao RDS, trocar a política de IAM da Lambda de
volta pela gerenciada e reescrever as condições de alerta que hoje leem
`Transaction` para lerem `Metric` com `aws.Namespace`. Os dois desenhos não
convivem: rodando juntos, cada métrica de ALB e de Lambda seria contada duas
vezes.
