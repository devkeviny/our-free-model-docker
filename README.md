# Our Free Model Docker (`our-free-model-docker`)

Implantação Docker privada, desacoplada e de fácil manutenção para o projeto público [Ebony-Vinyl/dsh-our-free-model](https://github.com/Ebony-Vinyl/dsh-our-free-model).

Este repositório contém **exclusivamente a camada de infraestrutura, containerização, proxy e orquestração**. O código original do upstream **não é mantido em fork nem copiado permanentemente**, sendo clonado dinamicamente durante o `docker build`.

---

## 🏗️ Arquitetura

```text
               [ Cliente Externo / OmniRoute / Hermes ]
                                  │
                                  ▼
      ┌────────────────────────────────────────────────────────┐
      │                    Docker Container                    │
      │                                                        │
      │   Ingress Proxy (Node.js) : 0.0.0.0:18900              │
      │   (Reescreve Host: 127.0.0.1 para satisfazer o fence)  │
      │                           │                            │
      │                           ▼                            │
      │   Our Free Model Standalone : 127.0.0.1:18901          │
      │   (Volume persistente: /data)                          │
      └───────────────────────────┬────────────────────────────┘
                                  │
                                  ▼ (HTTP_PROXY / HTTPS_PROXY)
      ┌────────────────────────────────────────────────────────┐
      │             Smart Egress Proxy Sidecar                 │
      │             (:8899) [Python Asíncrono]                 │
      │                                                        │
      │   • disabled: saída direta transparente                │
      │   • single:   túnel via proxy único configurado        │
      │   • pool:     rotação, healthcheck, cooldown e         │
      │               failover automático (estilo yt-dlp)      │
      └───────────────────────────┬────────────────────────────┘
                                  │
                                  ▼
             [ Provedores / Canais Gratuitos Upstream ]
           (Kilo AI, Canais de Contas, Google Gemini, etc.)
```

---

## 🚀 Modos de Atualização do Upstream

Você pode controlar exatamente qual versão do upstream é utilizada através da variável `UPSTREAM_REF`:

### 1. Modo Latest (Mais recente)
Busca automaticamente o commit mais recente da branch `main` do upstream ao reconstruir:
```env
UPSTREAM_REF=main
```
> **Nota sobre Cache do Docker:** Para forçar o Docker a buscar commits novos ao dar Rebuild no Coolify, incremente o `CACHEBUST` nas variáveis de ambiente:
> ```env
> CACHEBUST=20261013-01
> ```

### 2. Modo Pinned (Commit fixo testado)
Fixa a imagem em um commit específico auditado e estável:
```env
UPSTREAM_REF=ddb451c2f24bac0b0f8b03b2473efbb1f0aefb68
```

---

## 🔍 Script de Verificação de Atualizações

Para verificar se há novas atualizações disponíveis no upstream sem executar nenhuma ação destrutiva:

```bash
./check-upstream-update.sh
```

**Exemplo de saída:**
```text
========================================================
 Our Free Model - Upstream Version Audit
========================================================
Target Repository: https://github.com/Ebony-Vinyl/dsh-our-free-model.git
Tracked Ref:       main
--------------------------------------------------------
Currently Deployed SHA:  ddb451c2f24bac0b0f8b03b2473efbb1f0aefb68
Upstream Latest SHA:     ddb451c2f24bac0b0f8b03b2473efbb1f0aefb68
--------------------------------------------------------
Status: [OK] UP-TO-DATE
========================================================
```

---

## 🛡️ Camada de Egress / Smart Proxy

Inspirada no padrão `ProxyManager` / `SmartProxyTester` do projeto `devkeviny/yt-dlp-server`, esta implantação inclui um sidecar de proxy desacoplado (`proxy/`):

- **`PROXY_MODE=disabled` (Padrão):** Opera como um encaminhador direto e transparente. Zero dependência de proxies externos.
- **`PROXY_MODE=single`:** Direciona todas as requisições de saída por um proxy HTTP/SOCKS5 único (`PROXY_SINGLE_URL`).
- **`PROXY_MODE=pool`:** 
  - Recebe uma lista de proxies em `PROXY_POOL_URLS` ou `/data/proxies.json`.
  - Audita periodicamente a saúde de cada proxy contra endpoints neutros (`PROXY_HEALTH_TARGET`).
  - Coloca proxies com falha em **quarentena temporária** (`PROXY_COOLDOWN_SECONDS=300`) sem descartá-los permanentemente.
  - Alterna a saída (*failover*) em caso de queda.
  - Salva o estado dos proxies ativos em `/data/proxies_active.json`.
  - Se todos os proxies falharem, realiza **fallback seguro para conexão direta** (`PROXY_ALLOW_DIRECT_FALLBACK=true`).
  - Respeita cabeçalhos `Retry-After` em erros HTTP 429 sem queimar quotas.

---

## 📦 Implantação no Coolify

### 1. Criar Aplicação no Coolify
1. No painel do Coolify, selecione seu Projeto e clique em **+ New Resource**.
2. Escolha **Private Repository (GitHub App / Deploy Key)** e selecione `devkeviny/our-free-model-docker`.
3. Escolha o tipo de build: **Docker Compose**.
4. O Coolify detectará o arquivo `docker-compose.yml`.

### 2. Configurar Variáveis de Ambiente
Copie de `.env.example` para as Environment Variables do Coolify:

```env
PORT=18900
UPSTREAM_REF=main
CACHEBUST=1
OFM_PROBE=false
OFM_NO_REFRESH=false
EGRESS_PROXY_URL=http://proxy:8899
PROXY_MODE=disabled
```

### 3. Volumes Persistentes
O Compose já declara o volume `ofm_data` montado em `/data`. Ele armazena:
- `settings.json` (incluindo a chave de API `forwardKey`).
- Credenciais e cookies de canais (`channel-credentials.json`, `channel-pack/`).
- Estatísticas de uso e modelos cacheados.

Ao reiniciar ou recriar o container, **todos os dados e sua API Key são preservados**.

### 4. Suporte ARM64 (Oracle Ampere)
Todas as imagens base (`node:22-bookworm-slim` e `python:3.12-slim`) possuem suporte nativo a `linux/arm64` e foram testadas e validadas em Ubuntu 24.04 ARM64.

---

## 🔑 Autenticação e Chave de API

O Our Free Model gera automaticamente uma chave única no primeiro boot em `/data/settings.json` no campo `forwardKey`.

### Obter a Chave de API:
Via terminal ou Docker:
```bash
docker exec our-free-model node -e 'console.log(JSON.parse(fs.readFileSync("/data/settings.json")).forwardKey)'
```

Exemplo de chave gerada: `ofm-h2fm...`

- **Endpoint de Saúde (sem autenticação):** `GET http://<host>:18900/health`
- **Lista de Modelos:** `GET http://<host>:18900/v1/models` (Requer `Authorization: Bearer <forwardKey>`)
- **Chat Completions:** `POST http://<host>:18900/v1/chat/completions` (Requer `Authorization: Bearer <forwardKey>`)

---

## 🔗 Integração com o OmniRoute

Para conectar o Our Free Model ao OmniRoute:

### Opção A: No `config.yaml` do Hermes / OmniRoute
Adicione em `custom_providers`:

```yaml
custom_providers:
  - name: our-free-model
    api_base: http://<ip-ou-dominio-coolify>:18900/v1
    api_key: "<sua-forwardKey>"
    models:
      - liquid/lfm-2.5-2.6b:free
      - kilo-auto/free
      - stepfun/step-5-preview-free
      - inclusionai/ling-3.1-flash
```

### Opção B: Via API do OmniRoute
Faça uma chamada `POST /api/providers`:
```bash
curl -X POST https://omniroute.estudiopleiades.qzz.io/api/providers \
  -H "Authorization: Bearer $OMNIROUTE_MGMT_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "our-free-model",
    "baseUrl": "http://<coolify-host>:18900/v1",
    "apiKey": "<sua-forwardKey>",
    "isActive": true
  }'
```

---

## 🧪 Testes Automatizados

O repositório inclui a suíte completa de testes de aceitação:

```bash
./tests/run_tests.sh
```

A suíte valida os 11 requisitos:
1. Build da imagem Docker do zero;
2. Inicialização dos serviços no Docker Compose;
3. Healthcheck de ambos os containers;
4. Resposta de `/v1/models` com a chave gerada;
5. Requisição OpenAI de chat em modelo gratuito ativo (`liquid/lfm-2.5-2.6b:free`);
6. Persistência de volume e integridade da chave após restart;
7. Inicialização correta com proxy desabilitado;
8. Conectividade e encaminhamento do proxy;
9. Simulação de falha de proxy e failover/fallback;
10. Simulação de build com commit fixado (`UPSTREAM_REF=<sha>`) e cache-bust;
11. Verificação de integridade: zero código de upstream commitado.
