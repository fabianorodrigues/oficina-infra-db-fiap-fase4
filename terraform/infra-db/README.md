# Infra DB

Esta stack cria a VPC independente e o RDS SQL Server privado da Fase 4 do projeto Oficina.

## Recursos criados

- VPC `oficina` com DNS support e DNS hostnames habilitados.
- 2 subnets publicas e 2 subnets privadas nas duas primeiras Availability Zones disponiveis.
- Internet Gateway, NAT Gateway unico e Elastic IP do NAT.
- Route table publica com saida para Internet Gateway.
- Route table privada com saida para NAT Gateway.
- Security Group `oficina-rds-sg` sem regras de ingresso.
- DB Subnet Group usando somente subnets privadas.
- RDS SQL Server privado `oficina-sqlserver`.
- Master secret gerenciado pelo proprio RDS no Secrets Manager.
- 7 containers vazios no Secrets Manager para credenciais funcionais futuras.
- SSM Parameters String com configuracoes nao sensiveis para stacks futuras.

## O que nao e criado

- Bancos logicos.
- Usuarios SQL.
- Migrations.
- EKS.
- ECR.
- SQS.
- API Gateway.
- Lambdas.
- Secret versions ou valores de secrets.

O RDS sera criado inicialmente sem acesso de aplicacoes. As regras de ingresso serao adicionadas somente quando as identidades de rede do EKS e da Lambda Auth forem conhecidas.

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

Obrigatorias:

```text
AWS_REGION
TF_STATE_BUCKET
TF_STATE_REGION
TF_STATE_KEY_INFRA_DB
VPC_CIDR
RDS_DATABASE_PORT
```

Valores planejados:

```text
TF_STATE_KEY_INFRA_DB=oficina/infra-db/terraform.tfstate
VPC_CIDR=10.40.0.0/16
RDS_DATABASE_PORT=1433
```

Opcionais, somente se o AWS Academy nao aceitar os defaults:

```text
RDS_ENGINE
RDS_INSTANCE_CLASS
RDS_ALLOCATED_STORAGE
RDS_STORAGE_TYPE
```

Defaults Terraform:

```text
RDS_ENGINE=sqlserver-ex
RDS_INSTANCE_CLASS=db.t3.micro
RDS_ALLOCATED_STORAGE=20
RDS_STORAGE_TYPE=gp3
```

## Como executar

Depois do Pull Request aprovado e mergeado na `main`:

```text
GitHub
Actions
Infra DB Deploy
Run workflow
Branch main
confirmation APPLY
Run workflow
```

O workflow falha se a branch nao for `main`, se a confirmacao nao for exatamente `APPLY`, se variables obrigatorias estiverem vazias, se `AWS_REGION` e `TF_STATE_REGION` forem diferentes ou se a validacao read-only pos-apply falhar.

## Como validar

Validacoes esperadas:

- workflow `Infra DB Deploy` verde;
- GitHub Step Summary sanitizado;
- RDS com status `Available`;
- RDS com `Publicly accessible: No`;
- RDS criptografado;
- Security Group do RDS sem ingresso publico na porta 1433;
- containers de secrets presentes sem valores versionados por esta stack;
- SSM Parameters presentes.

Depois da execucao, a validacao pode ser repetida com:

```powershell
./scripts/validate-infra-db.ps1 -Region <regiao-do-academy>
```

## Proxima etapa

A proxima etapa criara os componentes de plataforma, como:

```text
EKS
ECR
SQS
Addons
```

Depois disso, etapas especificas deverao executar:

```text
Database Secrets Sync
Database Bootstrap
```

Essas etapas criarao os bancos logicos, usuarios SQL e valores funcionais de secrets.

## AWS Academy indisponivel

Esta implementacao pode ser validada estaticamente sem acesso ao AWS Academy. O primeiro `terraform plan` real e o primeiro `terraform apply` real devem ocorrer somente pelo workflow manual `Infra DB Deploy`, na branch `main`, depois do retorno do acesso ao Academy.

Validacoes AWS pendentes ate o retorno do acesso:

- autenticacao STS;
- permissoes IAM;
- disponibilidade do engine SQL Server;
- disponibilidade da classe de instancia;
- compatibilidade de `gp3`;
- suporte a `manage_master_user_password`;
- disponibilidade do identificador `oficina-sqlserver`;
- plan real;
- apply;
- criacao e validacao dos recursos AWS;
- idempotencia da segunda execucao.
