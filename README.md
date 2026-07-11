# oficina-infra-db-fiap-fase4

Infraestrutura Terraform da Fase 4 para backend de state e stack de banco de dados da Oficina.

- Backend Terraform: [terraform/backend/README.md](terraform/backend/README.md)
- Infra DB: [terraform/infra-db/README.md](terraform/infra-db/README.md)

## Sincronizacao centralizada dos secrets SQL

Este repositorio e o unico proprietario das senhas SQL da stack. As sete senhas
sao recebidas como Repository Secrets, montadas em um payload JSON por destino e
gravadas nos containers ja provisionados no AWS Secrets Manager pelo workflow
`Database Secrets Sync`.

Nenhuma senha e versionada. O contrato versionado
[config/database-secrets.json](config/database-secrets.json) contem apenas
informacoes nao sensiveis: nomes de secrets, nomes de variaveis de ambiente,
bancos, usuarios e os parametros SSM de endpoint e porta.

### Ownership

Todas as senhas SQL pertencem ao repositorio `oficina-infra-db-fiap-fase4`.

Os repositorios consumidores nao recebem as senhas, nao recebem connection
strings por GitHub Secret e nao duplicam nenhum valor. Eles apenas referenciam
os nomes dos secrets no Secrets Manager e, posteriormente, consomem os valores
via CSI/ASCP ou acesso runtime autorizado.

### Repository Secrets (somente neste repositorio)

Senhas SQL sincronizadas por este workflow:

```text
SQL_CADASTRO_APP_PASSWORD
SQL_CADASTRO_MIGRATOR_PASSWORD
SQL_ESTOQUE_APP_PASSWORD
SQL_ESTOQUE_MIGRATOR_PASSWORD
SQL_ORDENS_APP_PASSWORD
SQL_ORDENS_MIGRATOR_PASSWORD
SQL_AUTH_READ_PASSWORD
```

Credenciais temporarias do AWS Academy (necessarias antes de acessar a AWS):

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

Repository Variable:

```text
AWS_REGION
```

### Destinos no Secrets Manager

| ID                 | Repository Secret                | Secret Manager                  | Banco                  | Usuario           |
| ------------------ | -------------------------------- | ------------------------------- | ---------------------- | ----------------- |
| cadastro-runtime   | SQL_CADASTRO_APP_PASSWORD        | /oficina/cadastro/runtime-db    | OficinaCadastroDb      | cadastro_app      |
| cadastro-migration | SQL_CADASTRO_MIGRATOR_PASSWORD   | /oficina/cadastro/migration-db  | OficinaCadastroDb      | cadastro_migrator |
| estoque-runtime    | SQL_ESTOQUE_APP_PASSWORD         | /oficina/estoque/runtime-db     | OficinaEstoqueDb       | estoque_app       |
| estoque-migration  | SQL_ESTOQUE_MIGRATOR_PASSWORD    | /oficina/estoque/migration-db   | OficinaEstoqueDb       | estoque_migrator  |
| ordens-runtime     | SQL_ORDENS_APP_PASSWORD          | /oficina/ordens/runtime-db      | OficinaOrdensServicoDb | ordens_app        |
| ordens-migration   | SQL_ORDENS_MIGRATOR_PASSWORD     | /oficina/ordens/migration-db    | OficinaOrdensServicoDb | ordens_migrator   |
| auth-read          | SQL_AUTH_READ_PASSWORD           | /oficina/auth/database          | OficinaCadastroDb      | auth_read         |

Cada container guarda um JSON com campos separados (`Server`, `Port`, `Database`,
`UserId`, `Password`, `Encrypt`, `TrustServerCertificate`,
`ConnectionTimeoutSeconds`) e um campo `ConnectionString` ja montado. `Server` e
`Port` vem do SSM Parameter Store; `Database` e `UserId` vem do contrato
versionado; `Password` vem do Repository Secret; a connection string e construida
por um builder seguro do .NET.

### Scripts

- [scripts/validate-database-secrets-config.ps1](scripts/validate-database-secrets-config.ps1):
  validacao local e offline do contrato (estrutura, unicidade, sete destinos e
  ausencia de dados sensiveis). Nao acessa a AWS.
- [scripts/validate-database-secret-containers.ps1](scripts/validate-database-secret-containers.ps1):
  validacao read-only dos containers (existencia, nome, ARN e, apos a
  sincronizacao, versao `AWSCURRENT`). Nunca le o conteudo dos secrets.
- [scripts/sync-database-secrets.ps1](scripts/sync-database-secrets.ps1):
  le cada senha de environment variable, monta o payload e executa
  `put-secret-value` em containers existentes. Possui `-DryRun` que constroi os
  sete payloads em memoria sem acessar a AWS. Nunca imprime senhas, connection
  strings ou o payload.

### Workflow Database Secrets Sync

Disparo manual, somente na branch `main`, com confirmacao explicita:

```text
GitHub
-> Actions
-> Database Secrets Sync
-> Run workflow
-> Branch main
-> confirmation SYNC
```

Sequencia: valida branch, confirmacao, `AWS_REGION` e a presenca dos sete
Repository Secrets; configura credenciais; valida identidade; valida o contrato;
valida os containers antes da sincronizacao; executa a sincronizacao; valida os
containers com `AWSCURRENT` obrigatorio; publica um Step Summary sanitizado.

A reexecucao e idempotente: o `ClientRequestToken` e um SHA-256 do payload
completo, portanto a mesma senha e a mesma configuracao nao criam uma nova
versao; uma senha alterada gera uma nova versao. O workflow nunca cria, atualiza
ou remove containers, apenas executa `put-secret-value`.

### Integracao com a CI

A pipeline [.github/workflows/infra-db-ci.yml](.github/workflows/infra-db-ci.yml)
valida estes arquivos em cada Pull Request, sem credenciais AWS e sem senhas
reais: JSON e contrato validos, PowerShell AST dos quatro scripts, DryRun com
valores sinteticos, Actionlint do workflow e buscas estaticas por credenciais,
connection strings e artefatos temporarios.

### Dependencias

```text
Infra DB provisionada
Containers de Secrets Manager existentes
Parametros SSM de endpoint (/oficina/infra/rds/endpoint) e porta (/oficina/infra/rds/port)
Credenciais AWS Academy validas
```

### Consumidores

```text
Cadastro runtime le  /oficina/cadastro/runtime-db
Cadastro migration le /oficina/cadastro/migration-db
Estoque runtime le  /oficina/estoque/runtime-db
Estoque migration le /oficina/estoque/migration-db
Ordens runtime le   /oficina/ordens/runtime-db
Ordens migration le  /oficina/ordens/migration-db
Auth CPF le         /oficina/auth/database
```

### Seguranca

- Nenhuma senha em Terraform, em `tfvars`, no state, em manifests ou em outputs.
- Nenhuma senha duplicada nos repositorios consumidores.
- Nenhum valor de secret e lido pelos scripts de validacao.
- Senhas recebidas somente por environment variable, nunca por argumento.
- Payload temporario criado no diretorio temporario do sistema, com permissao
  restritiva quando suportada, e removido no bloco `finally`.
- Reexecucao idempotente via `ClientRequestToken`.
