# Terraform Backend

Este backend armazena os Terraform States da solução Oficina, de forma independente de qualquer bucket, state ou recurso pré-existente.

## Repository Secrets

No GitHub, acesse:

```text
oficina-infra-db-fiap-fase4
Settings
Secrets and variables
Actions
Secrets
```

Crie ou atualize:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

## Repository Variables

No GitHub, acesse:

```text
oficina-infra-db-fiap-fase4
Settings
Secrets and variables
Actions
Variables
```

Crie:

```text
AWS_REGION
TF_STATE_BUCKET
TF_STATE_REGION
```

`AWS_REGION` deve ser a regiao da conta AWS utilizada. `TF_STATE_REGION` deve ter o mesmo valor. `TF_STATE_BUCKET` deve ser globalmente unico.

Formato sugerido para o bucket:

```text
oficina-terraform-state-<ACCOUNT_ID>-<REGIAO>
```

Para obter o Account ID, configure as credenciais temporarias localmente e execute:

```powershell
aws sts get-caller-identity
```

Nao crie o bucket pelo Console. A criacao e a reconciliacao devem ocorrer somente pelo workflow manual.

## Execucao

Depois do Pull Request aprovado e mergeado na `main`:

```text
GitHub
Actions
Terraform Backend Deploy
Run workflow
Branch main
confirmation CREATE
Run workflow
```

O workflow falha se a branch nao for `main`, se a confirmacao nao for exatamente `CREATE`, se alguma variable obrigatoria estiver vazia ou se `AWS_REGION` e `TF_STATE_REGION` forem diferentes.

## Validacao

Verifique o workflow verde e o summary sanitizado. O backend deve apresentar:

- bucket na regiao esperada;
- versionamento habilitado;
- criptografia SSE-S3 com AES256;
- bloqueio total de acesso publico;
- Object Ownership como `BucketOwnerEnforced`;
- tags obrigatorias;
- politica que nega `aws:SecureTransport=false`.

## States Futuros

As stacks futuras devem usar chaves independentes:

```text
oficina/infra-db/terraform.tfstate
oficina/platform/terraform.tfstate
oficina/entrypoint/terraform.tfstate
```

O exemplo `backend-config.example.hcl` usa:

```hcl
use_lockfile = true
```

Esse locking nativo do backend S3 deve ser confirmado contra a versao minima do Terraform adotada pelas stacks futuras. Se a versao escolhida nao suportar `use_lockfile`, registre a incompatibilidade antes das proximas stacks. Nao crie tabela DynamoDB automaticamente nesta etapa.

## Limpeza

Nao existe pipeline de destroy e nao existe script para excluir o bucket neste repositorio.
