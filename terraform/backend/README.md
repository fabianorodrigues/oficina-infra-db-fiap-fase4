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
```

`AWS_REGION` deve ser a regiao da conta AWS utilizada. O workflow
`Database Infrastructure Deploy` resolve o bucket pelo formato deterministico:

```text
oficina-terraform-state-<account-id>-<AWS_REGION>
```

Durante migracao, `TF_STATE_BUCKET` pode existir como fallback temporario se um
bucket legado ja tiver state. Nao crie o bucket pelo Console. A criacao e a
reconciliacao devem ocorrer somente pelo workflow manual consolidado.

## Execucao

Depois do Pull Request aprovado e mergeado na `main`:

```text
GitHub
Actions
Database Infrastructure Deploy
Run workflow
Branch main
confirmation APPLY
Run workflow
```

O workflow falha se a branch nao for `main`, se a confirmacao nao for exatamente `APPLY`, se `AWS_REGION` estiver vazia ou se a validacao do backend falhar.

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
