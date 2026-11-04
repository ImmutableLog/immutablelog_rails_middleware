# ImmutableLog Rails Middleware

Middleware Rack para Rails (7.1 ou mais novo; testado no 7.1 e no 8.1) que captura as requisições HTTP que passam por ele e envia um evento de auditoria imutável para o ImmutableLog — todas, exceto `OPTIONS` (preflight) e os paths de `skip_paths` (comparação exata; padrão `/health`, `/healthz` e `/up`). Exceção não tratada no controller também gera evento, com status 500 e `error_*`.

O evento é montado ainda na thread da requisição e enviado numa `Thread` separada: a resposta não espera o ImmutableLog, e uma falha de envio só gera um `warn` no `Rails.logger`.

---

## Instalação

Nenhuma gem. O arquivo usa só a biblioteca padrão do Ruby (`net/http`, `json`, `ipaddr`, `securerandom`). Ruby 3.0+.

---

## Adicionar ao projeto

Copie `immutable_log_middleware.rb` para:

```
lib/immutable_log_middleware.rb
```

O arquivo define a classe `ImmutableLogMiddleware` no escopo de topo.

---

## Variáveis de ambiente

| Variável             | Obrigatório | Default                          | Descrição                              |
|----------------------|-------------|----------------------------------|----------------------------------------|
| `IMTBL_API_KEY`      | Sim         | —                                | Chave de API do ImmutableLog (scope `events:write`) |
| `IMTBL_URL`          | Não         | `https://api.immutablelog.com`   | URL base da API                        |
| `IMTBL_SERVICE_NAME` | Não         | `rails-service`                  | Nome do serviço (`meta.service`)       |
| `IMTBL_ENV`          | Não         | `production`                     | Ambiente (`meta.environment` e `meta.env`) |

São os defaults dos argumentos do construtor; o que você passar no `config.middleware.use` vale sobre a variável. Sem chave, o middleware registra um aviso e **não envia nada**.

> **Segurança:** nunca coloque a chave no código. Use variável de ambiente, `credentials.yml.enc` (`api_key: Rails.application.credentials.dig(:immutablelog, :api_key)`) ou um secrets manager.

---

## Registro na aplicação

```ruby
# config/application.rb
require_relative "../lib/immutable_log_middleware"

module MyApp
  class Application < Rails::Application
    # ...
    config.middleware.use ImmutableLogMiddleware,
      service: "my-rails-api",
      skip_paths: %w[/health /up /metrics]
  end
end
```

`config.middleware.use` põe o middleware **no fim da pilha**, logo antes das rotas — depois do `ActionDispatch::ShowExceptions`. É isso que faz a exceção do controller passar por ele antes de virar a página de erro. Confira com `bin/rails middleware`.

Argumentos (todos opcionais): `api_key:`, `api_url:`, `service:`, `env:`, `skip_paths:`, `trust_trail_header:`, `timeout:` (segundos, padrão 5), `logger:`.

---

## Como funciona

| Etapa               | Descrição                                                                    |
|---------------------|------------------------------------------------------------------------------|
| antes de `@app.call`| Copia método, path, User-Agent, `client_ip` e (se ligado) o header de trilha |
| `@app.call(env)`    | Executa o roteamento e o controller; captura exceção e a relança             |
| depois              | Lê status, rota-template e marcadores do `env` e monta o evento — ainda na thread da requisição |
| `Thread.new`        | Envia em segundo plano; a thread recebe só strings, nunca o `env`            |
| `Idempotency-Key`   | Um UUID novo por evento (`SecureRandom.uuid`), igual a `meta.request_id`     |

O middleware nunca lê o body da requisição: nem conteúdo, nem hash.

---

## Nome de evento e trilha customizados

Em qualquer controller:

```ruby
class PaymentsController < ApplicationController
  def create
    request.env["imtbl.event_name"] = "payment.created"
    request.env["imtbl.trail"] = "order-7782"
    render json: { ok: true }, status: :created
  end
end
```

- Sem nome definido, o evento é `http.{MÉTODO}.{path}` (ex.: `http.GET./users/42`).
- O core recusa trilha vazia, com mais de 256 caracteres ou com `:` (`400 invalid_immutable_trail`); por isso o middleware troca `:` por `-`, corta em 256 e omite a chave se sobrar vazio.
- **Header `X-Imtbl-Trail`:** só é lido com `trust_trail_header: true`, e só quando o controller não definiu a trilha. Fica desligado porque o header vem de quem chama o serviço: qualquer chamador poderia pendurar eventos numa trilha alheia do mesmo tenant.

---

## Chaves enviadas em `meta`

Todos os valores passam por `to_s`: o core só aceita `meta` como mapa string → string, e `http_status` vai como `"200"`, nunca como o inteiro `200`.

| Chave             | Valor                                                                 |
|-------------------|-----------------------------------------------------------------------|
| `type`            | `success` (2xx), `info` (3xx e <200), `error` (4xx/5xx)               |
| `event_type`      | mesmo valor de `type` (severidade, não nome — ver `GUIA_EVENTOS_CLIENTE.md`) |
| `event_name`      | `env["imtbl.event_name"]` ou `http.{MÉTODO}.{path}`                   |
| `service`         | `service:` / `IMTBL_SERVICE_NAME`                                     |
| `environment`     | `env:` / `IMTBL_ENV` (nome canônico, `CONTRACT.md` §4.1)              |
| `env`             | mesmo valor de `environment` (nome legado, mantido como nos outros middlewares) |
| `request_id`      | UUID do evento — o mesmo valor do header `Idempotency-Key`            |
| `http_method`     | `GET`, `POST`…                                                        |
| `http_status`     | status da resposta, em texto                                          |
| `http_route`      | `request.route_uri_pattern` sem o `(.:format)` final (`/users/:id`); em 404, o path concreto |
| `log_level`       | `error` para `type: error`, senão `info`                              |
| `client_ip`       | IP do cliente, **sem porta**; a chave é omitida se não houver IP válido |
| `error_type`      | classe da exceção (`RuntimeError`, `ActiveRecord::RecordNotFound`…)   |
| `error_message`   | mensagem da exceção, até 500 caracteres                               |
| `immutable_trail` | trilha, só quando definida                                            |

**De onde vem a rota-template:** do método público `ActionDispatch::Request#route_uri_pattern` (Rails 7.1+), com `env["action_dispatch.route_uri_pattern"]` como reserva. Não leia só a chave do `env`: no Rails 8.1 ela **não existe** até alguém chamar o método — o router guarda apenas o objeto da rota em `env["action_dispatch.route"]` e o padrão é calculado sob demanda. Antes do 7.1 não há nenhum dos dois, e `http_route` sai com o path concreto.

---

## Payload enviado

`payload` é uma string JSON (limite do core: 16 KB; os campos variáveis são cortados — path em 2048, User-Agent em 512):

```json
{
  "id": "uuid",
  "kind": "success",
  "message": "GET /users/42 -> 200",
  "timestamp": "2026-11-04T12:20:32Z",
  "context": { "ip": "203.0.113.7", "user_agent": "curl/8.4.0" },
  "request": { "request_id": "uuid", "method": "GET", "path": "/users/42" },
  "metrics": { "latency_ms": 1, "status_code": 200 },
  "severity": "low",
  "error": { "status_code": 500, "retryable": true, "exception": "...", "exception_message": "..." }
}
```

---

## Comportamento

| Situação                          | Resultado                                                         |
|-----------------------------------|-------------------------------------------------------------------|
| Chave vazia                       | Nenhum evento enviado (aviso no log)                              |
| `OPTIONS` ou path em `skip_paths` | Sem evento; a requisição segue normalmente                        |
| Exceção no controller             | Evento com status 500 e `error_*`; a exceção é relançada e o `ShowExceptions` responde como sempre. Exceções que o Rails mapeia para outro status (ex.: `RecordNotFound` → 404) também saem como 500 no evento |
| `rescue_from` no controller       | A exceção não chega ao middleware: evento com o status que o `rescue_from` gravou, sem `error_*` |
| Rota sem match (404)              | Evento com `http_route` igual ao path concreto                    |
| ImmutableLog fora do ar ou lento  | Resposta da aplicação igual e no mesmo tempo; `warn` no log; conexão em 1 s, total em `timeout`; sem retry |

---

## Proxy e X-Forwarded-For

`client_ip` vem, nesta ordem, do **primeiro item** de `X-Forwarded-For`, de `X-Real-IP` e de `REMOTE_ADDR`. Os headers são lidos **direto**, sem passar pelo `ActionDispatch::RemoteIp`/`config.action_dispatch.trusted_proxies` — a mesma regra dos outros middlewares ImmutableLog, e não o `request.remote_ip`.

- Atrás de um proxy/ALB que sobrescreve `X-Forwarded-For`, o valor é o IP do cliente, sem configurar nada.
- **Sem proxy na frente, quem chama o serviço forja o `client_ip`** só mandando o header, e o SIEM promove esse valor a `source.ip`. Regras de detecção por IP passam a confiar num dado que o chamador controla. Se o serviço fica exposto direto, garanta na borda que o header não chega do cliente.
- Só `client_ip` vira `source.ip` no SIEM. Uma chave `source_ip` em `meta` **não** é promovida.
- O valor sai sempre como IP puro: `203.0.113.7:4711` → `203.0.113.7`, `[2001:db8::1]:8080` → `2001:db8::1`, `::ffff:10.0.0.1` → `10.0.0.1`. Um valor que não é IP (ex.: `X-Forwarded-For: unknown`, ou uma faixa `10.0.0.0/8`) é ignorado e vale a fonte seguinte. O SIEM descarta, sem erro, `client_ip` com porta.

---

## Limitações conhecidas

- **Dado pessoal selado.** O IP do cliente (`client_ip` e `payload.context.ip`), o User-Agent e o path concreto vão para o bloco imutável e **não podem ser apagados depois**. Avalie isso contra a sua política de privacidade (IP é dado pessoal na LGPD). Não ponha dado sensível em path, nome de evento, trilha ou mensagem de exceção.
- **Path concreto no evento:** `payload.request.path` e o `event_name` padrão levam os IDs da URL (`/users/42`). `http_route` usa o template.
- **Entrega:** uma `Thread` por requisição, sem retry e sem fila. O evento se perde em falha de rede, se o ImmutableLog recusar, ou se o processo terminar (deploy, restart do Puma) antes do envio.
- **`Idempotency-Key`** é gerado pelo middleware (UUID por evento). O `X-Request-Id` recebido não é usado: ele vem do chamador, e dois eventos diferentes com o mesmo valor seriam tratados pelo core como duplicata (`200 duplicate`).
