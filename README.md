# oficina-infra-db

Fundação da solução **Oficina**: rede, banco de dados relacional, segredos de acesso e o estado remoto do Terraform compartilhado por toda a solução.

![Terraform](https://img.shields.io/badge/Terraform-1.10-7B42BC?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-VPC%20%C2%B7%20RDS%20%C2%B7%20Secrets%20Manager%20%C2%B7%20SSM-FF9900?logo=amazonaws&logoColor=white)
![SQL Server](https://img.shields.io/badge/RDS-SQL%20Server-CC2927?logo=microsoftsqlserver&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)

---

## Sumário

- [Visão geral](#visão-geral)
- [Ordem de deploy da solução](#ordem-de-deploy-da-solução)
- [Arquitetura](#arquitetura)
- [O que consome e o que publica](#o-que-consome-e-o-que-publica)
- [Configuração](#configuração)
- [Como executar](#como-executar)
- [Validação](#validação)
- [Execução local](#execução-local)
- [Limitações conhecidas](#limitações-conhecidas)
- [Próxima etapa](#próxima-etapa)

---

## Visão geral

A **Oficina** é uma plataforma de gestão de oficina mecânica implantada na AWS e distribuída em **6 repositórios** que compõem um único sistema. O cliente acessa uma **API Gateway HTTP**, que autentica na borda por uma **Lambda authorizer** e encaminha o tráfego, via **VPC Link**, para um **ALB interno** que roteia para três microsserviços **.NET 10 em Kubernetes (K3s)**. Os serviços se comunicam por HTTP interno e por filas **SQS FIFO**, e persistem em um **RDS SQL Server** compartilhado.

| Repositório | Responsabilidade | Etapas |
|---|---|:---:|
| **oficina-infra-db** *(este)* | Rede, banco de dados, segredos, estado do Terraform e admin inicial | 1, 3 e 6 |
| [oficina-infra](https://github.com/fabianorodrigues/oficina-infra-fiap-fase4) | Plataforma Kubernetes/ALB, entrada de API e observabilidade | 2, 9 e 10 |
| [oficina-auth-lambda](https://github.com/fabianorodrigues/oficina-auth-lambda-fiap-fase4) | Autenticação por CPF e validação de token | 4 |
| [oficina-cadastro](https://github.com/fabianorodrigues/oficina-cadastro-fiap-fase4) | Clientes, veículos, funcionários e catálogo de serviços | 5 |
| [oficina-estoque](https://github.com/fabianorodrigues/oficina-estoque-fiap-fase4) | Peças, insumos, saldos e reservas | 7 |
| [oficina-ordens-servico](https://github.com/fabianorodrigues/oficina-ordens-servico-fiap-fase4) | Ordens de serviço, orçamento e saga de pagamento | 8 e 11 |

**Papel deste repositório:** é a raiz da solução. Provisiona a rede (VPC), o banco (RDS SQL Server), os contêineres de segredo do banco e o bucket S3 que armazena o **estado do Terraform de todos os stacks**. Nada é implantado sem que esta etapa exista.

---

## Ordem de deploy da solução

Os repositórios têm dependências reais entre si. Esta é a sequência obrigatória — cada workflow valida suas precondições e falha se a etapa anterior não estiver concluída.

| # | Repositório | Workflow | Confirmação |
|:---:|---|---|:---:|
| **1** | **oficina-infra-db** | **Database Infrastructure Deploy** | `APPLY` |
| 2 | oficina-infra | Platform Deploy | `APPLY` |
| **3** | **oficina-infra-db** | **Database Bootstrap (estrutura)** | `BOOTSTRAP` |
| 4 | oficina-auth-lambda | Auth Deploy | `DEPLOY` |
| 5 | oficina-cadastro | Cadastro Deploy | `DEPLOY` |
| **6** | **oficina-infra-db** | **Initial Admin Provision** | `PROVISION_ADMIN` |
| 7 | oficina-estoque | Estoque Deploy | `DEPLOY` |
| 8 | oficina-ordens-servico | Ordens Deploy | `DEPLOY` |
| 9 | oficina-infra | Entrypoint Deploy | `APPLY` |
| 10 | oficina-infra | Observability Deploy | `DEPLOY` |
| 11 | oficina-ordens-servico | Collection Postman (execução manual) | — |

As etapas 7 e 8 não dependem do admin inicial e podem rodar em paralelo se desejado; a sequência acima é o caminho guiado para configuração completa. A etapa **6** é obrigatória no primeiro provisionamento do ambiente e opcional em redeploys do Cadastro quando o admin já existe. Ela precisa estar concluída antes da etapa 11. Após a etapa 9, execute o **Observability Deploy** (oficina-infra) com `mode=DEPLOY`.

> [!IMPORTANT]
> **Este repositório abre e retoma a sequência.** A **etapa 1** cria o bucket S3 de estado usado por todos os stacks — sem ela, os deploys de plataforma, autenticação e entrada abortam na verificação do bucket. A **etapa 3** (bootstrap estrutural) roda como *Job Kubernetes* e depende do cluster K3s e do repositório de imagem criados na etapa 2, por isso não é adjacente à etapa 1. A **etapa 6** usa um workflow separado para criar ou atualizar o administrador inicial somente depois que o Cadastro criou `OficinaCadastroDb.dbo.Funcionarios`.

---

## Arquitetura

```mermaid
flowchart TB
    subgraph VPC["VPC dedicada · 10.40.0.0/16"]
        direction TB
        Pub["2 subnets públicas<br/>Internet Gateway + NAT"]
        Priv["2 subnets privadas"]
        RDS[("RDS SQL Server<br/>criptografado · sem acesso público")]
        Pub --> Priv --> RDS
    end

    subgraph Contratos["Publicado para os demais repositórios"]
        direction LR
        SSM["SSM Parameter Store<br/>10 parâmetros de rede e RDS"]
        SM["Secrets Manager<br/>7 segredos de banco"]
        S3[("Bucket S3<br/>estado do Terraform")]
    end

    Bootstrap["Database Bootstrap<br/>Job Kubernetes · cria bancos, logins e permissões"]

    VPC --> SSM
    VPC --> SM
    Bootstrap --> RDS

    classDef data fill:#CC2927,stroke:#7a1717,color:#fff
    classDef pub fill:#1f6feb,stroke:#0b3d91,color:#fff
    class RDS,S3 data
    class SSM,SM pub
```

O acoplamento entre repositórios é feito **por nome de parâmetro no SSM e no Secrets Manager**. Não há leitura de estado entre stacks: cada stack lê apenas o que o anterior publicou.

---

## O que consome e o que publica

### Consome

Nada. Este repositório é a raiz do grafo de dependências. O **Database Bootstrap** (etapa 3) é a única exceção: consome o node do cluster K3s, o namespace e o repositório de imagem `db-bootstrap` publicados pela plataforma na etapa 2.

### Publica

| Recurso | Caminho | Consumido por |
|---|---|---|
| VPC | `/oficina/infra/vpc/id` | infra, auth |
| Subnets privadas | `/oficina/infra/subnets/private/{1,2}` | infra, auth |
| Subnets públicas | `/oficina/infra/subnets/public/{1,2}` | infra |
| RDS | `/oficina/infra/rds/{identifier,endpoint,port}` | bootstrap |
| Grupo de segurança do RDS | `/oficina/infra/rds/security-group-id` | infra, auth |
| Segredo master do RDS | `/oficina/infra/rds/master-secret-arn` | bootstrap |
| Credenciais dos serviços | `/oficina/{cadastro,estoque,ordens}/{runtime,migration}-db` | cadastro, estoque, ordens |
| Credencial de leitura da autenticação | `/oficina/auth/database` | auth |
| Estado do Terraform | Bucket S3 `oficina-terraform-state-<conta>-<região>` | infra, auth |

### Matriz de bancos e logins

Criada pelo **Database Bootstrap** (etapa 3):

| Banco | Login de runtime | Login de migração | Somente leitura |
|---|---|---|---|
| `OficinaCadastroDb` | `cadastro_app` | `cadastro_migrator` | `auth_read` |
| `OficinaEstoqueDb` | `estoque_app` | `estoque_migrator` | — |
| `OficinaOrdensServicoDb` | `ordens_app` | `ordens_migrator` | — |

O login `auth_read` permite que a autenticação consulte a tabela de funcionários sem receber permissão de escrita.

---

## Configuração

Configure em **Settings → Secrets and variables → Actions** do repositório.

### Secrets

| Secret | Uso | Obrigatório |
|---|---|:---:|
| `AWS_ACCESS_KEY_ID` · `AWS_SECRET_ACCESS_KEY` · `AWS_SESSION_TOKEN` | Credenciais temporárias da AWS | **Sim** |
| `SQL_CADASTRO_APP_PASSWORD` · `SQL_CADASTRO_MIGRATOR_PASSWORD` | Senhas dos logins do banco de cadastro | **Sim** |
| `SQL_ESTOQUE_APP_PASSWORD` · `SQL_ESTOQUE_MIGRATOR_PASSWORD` | Senhas dos logins do banco de estoque | **Sim** |
| `SQL_ORDENS_APP_PASSWORD` · `SQL_ORDENS_MIGRATOR_PASSWORD` | Senhas dos logins do banco de ordens | **Sim** |
| `SQL_AUTH_READ_PASSWORD` | Senha do login de leitura da autenticação | **Sim** |
| `RDS_ADMIN_CIDR` | CIDR IPv4 (`/32`) autorizado a acessar a porta 1433 para administração via SSMS. Vazio mantém o RDS fechado | Não |
| `ADMIN_INICIAL_CPF` · `ADMIN_INICIAL_PASSWORD` | Credenciais do usuário administrador inicial. Exigidas **apenas** pelo workflow **Initial Admin Provision** (etapa 6) | **Sim, para provisionar o admin** |

O deploy verifica a presença das 7 senhas antes de iniciar e falha listando as que faltarem. Use senhas que atendam à política do SQL Server (maiúscula, minúscula, dígito e no mínimo 8 caracteres).

O `ADMIN_INICIAL_CPF` precisa ter exatamente 11 dígitos, sem pontuação, e o `ADMIN_INICIAL_PASSWORD` no máximo 256 caracteres — o workflow valida ambos e falha antes de executar.

### Variables

| Variable | Uso | Obrigatório |
|---|---|:---:|
| `AWS_REGION` | Região de todos os recursos | **Sim** |
| `SQL_TOOLS_IMAGE` | Imagem base com as ferramentas de linha de comando do SQL Server, usada pelo bootstrap e pelo provisionamento do admin. Exige tag ou digest explícito — `latest` é rejeitado | **Sim, para os Jobs de banco** |
| `INSTANCE_PROFILE_NAME` (em oficina-infra) | Instance profile da EC2 do K3s usado pelos Jobs Kubernetes do bootstrap | **Sim, para o bootstrap** |
| `TF_STATE_BUCKET` | Compatibilidade com um bucket de estado pré-existente | Não |

### Papéis IAM das Jobs Kubernetes — não provisionados automaticamente

O **Database Bootstrap** e o **Initial Admin Provision** rodam como Jobs Kubernetes no cluster K3s, acionados por Systems Manager. Este repositório **não configura role alguma**: os Jobs usam a role do instance profile da EC2 do cluster, definida uma única vez em `oficina-infra` pela variável `INSTANCE_PROFILE_NAME`. Nenhum workflow da solução cria ou altera recursos IAM.

| Onde | Variable | Permissões mínimas exigidas pelos Jobs de banco |
|---|---|---|
| oficina-infra | `INSTANCE_PROFILE_NAME` | Registro no Systems Manager, `ecr:GetAuthorizationToken` e pull da imagem `db-bootstrap`, `secretsmanager:GetSecretValue` no segredo master do RDS e nos 7 segredos de banco, e `ssm:GetParameter` com `kms:Decrypt` em `/oficina/deploy/*` para o hash temporário do admin |

> [!NOTE]
> As credenciais são lidas do Secrets Manager **dentro da EC2** e materializadas como Secret Kubernetes temporário, removido em bloco `finally` que roda em sucesso, falha e timeout. Nenhum valor secreto passa pelo runner do GitHub.

Consulte o ARN de uma role existente com:

```powershell
aws iam get-role --role-name "<ROLE_NAME>" --query "Role.Arn" --output text
```

### O que é provisionado automaticamente

O bucket de estado é criado e reconciliado pelo próprio workflow, e **todas as variáveis do Terraform têm valor padrão** — não é necessário criar recursos de rede ou banco manualmente.

> [!WARNING]
> O CIDR da VPC (`10.40.0.0/16`), a engine, a classe de instância e o armazenamento do RDS são **fixos no código Terraform**. Não há *variables* do GitHub para alterá-los: mudanças exigem editar `terraform/infra-db/variables.tf` e abrir um pull request. A única variável Terraform sem valor padrão é a região, preenchida por `AWS_REGION`. A secret opcional `RDS_ADMIN_CIDR` não altera a rede; apenas adiciona uma exceção de entrada no grupo de segurança do RDS.

---

## Como executar

Ambos os workflows rodam apenas na branch `main`, exigem uma confirmação **sensível a maiúsculas** e não podem ser executados em paralelo consigo mesmos.

### Etapa 1 — Database Infrastructure Deploy

**Actions → Database Infrastructure Deploy → Run workflow → `confirmation` = `APPLY`**

Cria e reconcilia o bucket de estado → valida o plano do Terraform → aplica a rede, o RDS e os contêineres de segredo → grava as 7 senhas no Secrets Manager → revalida. Um passo de segurança **interrompe o deploy se o plano previr exclusão** de VPC, subnet, instância de banco, segredo ou parâmetro.

Duração típica: 15 a 25 minutos, dominada pela criação do RDS.

### Etapa 3 — Database Bootstrap

Execute **apenas depois** do Platform Deploy (etapa 2), pois roda como Job Kubernetes (K3s) no cluster criado por ele.

**Actions → Database Bootstrap → Run workflow → `confirmation` = `BOOTSTRAP`**

Constrói a imagem de bootstrap a partir de `SQL_TOOLS_IMAGE`, publica no ECR `db-bootstrap`, aplica o manifesto do Job Kubernetes, executa o Job no namespace da solução, aguarda a conclusão e valida o código de saída. Cria os bancos, os logins e as permissões da matriz acima. É idempotente — reexecutar não duplica objetos. As senhas são injetadas como *secrets* do Job e não aparecem nos logs.

Este workflow não cria usuários de aplicação. Nesse momento a tabela `dbo.Funcionarios` ainda não existe, porque ela é criada pelas migrations do Cadastro na etapa 5.

<a id="etapa-6-admin-inicial"></a>

### Etapa 6 — Usuário administrador inicial

Execute **apenas depois** do Cadastro Deploy (etapa 5), pois esse workflow grava o administrador inicial na tabela `dbo.Funcionarios` criada pelas migrations do Cadastro.

**Actions → Initial Admin Provision → Run workflow → `confirmation` = `PROVISION_ADMIN`**

O workflow constrói ou reutiliza a imagem `db-bootstrap`, deriva o hash PBKDF2 a partir de `ADMIN_INICIAL_PASSWORD`, envia apenas o hash como `SecureString` temporário e executa um Job Kubernetes restrito ao provisionamento de uma única linha em `OficinaCadastroDb.dbo.Funcionarios`.

> [!IMPORTANT]
> Esse workflow exige que **as migrations do Cadastro já estejam aplicadas**. Se `dbo.Funcionarios` não existir, ele falha com orientação para executar a etapa 5 primeiro. Se o admin já existir, ele atualiza nome, hash da senha, perfil Admin e status ativo, então pode ser usado para corrigir ou rotacionar a credencial inicial.

Essa etapa é obrigatória no primeiro provisionamento do ambiente e opcional em redeploys normais do Cadastro quando o administrador já existe. Esse administrador é a credencial usada na **etapa 11**, na validação funcional pela collection Postman. Sem ele, não há como autenticar na API.

---

## Validação

### Pelo Console AWS

| Serviço | O que verificar |
|---|---|
| **VPC** | 1 VPC, 4 subnets, 1 Internet Gateway, 1 NAT Gateway |
| **RDS** | Instância `Available`, **Publicly accessible = No**, criptografia habilitada |
| **Secrets Manager** | 7 segredos, cada um com uma versão `AWSCURRENT` |
| **Parameter Store** | 10 parâmetros sob `/oficina/infra/` |
| **S3** | Bucket de estado com versionamento e criptografia ativos |
| **Systems Manager → Run Command (após a etapa 3)** | Comandos de bootstrap e de isolamento com status `Success` |

### Pela AWS CLI

<details>
<summary>Comandos de validação</summary>

```bash
REGIAO=<sua-regiao>

# Parâmetros publicados para os demais repositórios
aws ssm get-parameters-by-path --path /oficina/infra --recursive \
  --region "$REGIAO" --query 'Parameters[].Name' --output table

# RDS disponível e fechado para a internet
aws rds describe-db-instances --region "$REGIAO" \
  --query 'DBInstances[].{Status:DBInstanceStatus,Publico:PubliclyAccessible,Cripto:StorageEncrypted}' \
  --output table

# Cada segredo deve ter exatamente uma versão corrente
for s in cadastro/runtime-db cadastro/migration-db estoque/runtime-db \
         estoque/migration-db ordens/runtime-db ordens/migration-db auth/database; do
  echo -n "/oficina/$s -> "
  aws secretsmanager describe-secret --secret-id "/oficina/$s" \
    --region "$REGIAO" --query 'length(VersionIdsToStages)' --output text
done
```

</details>

O resumo da execução do bootstrap lista os bancos, logins e permissões aplicados, sem expor credenciais.

---

## Execução local

Este repositório não provisiona recursos localmente: toda alteração é aplicada pelos workflows, para manter o estado do Terraform consistente. Localmente é possível reproduzir a validação estática da CI:

```bash
cd terraform/infra-db
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

---

## Limitações conhecidas

- **RDS de instância única**, single-AZ, sem alta disponibilidade e com 1 dia de retenção de backup.
- **NAT Gateway único** para as duas subnets privadas: ponto único de falha na saída.
- **Sem monitoramento avançado do banco** (Performance Insights, alarmes, exportação de logs).
- **Credenciais estáticas** com token de sessão, em vez de federação OIDC.

---

## Próxima etapa

**Etapa 2 — obrigatória.** Pré-condição: a etapa 1 concluída, com o bucket S3 de estado, a VPC e o RDS `Available`.

**→ [oficina-infra](https://github.com/fabianorodrigues/oficina-infra-fiap-fase4)** — seção [Como executar → Etapa 2](https://github.com/fabianorodrigues/oficina-infra-fiap-fase4#etapa-2--platform-deploy). Provisiona a EC2 com K3s, o ALB interno, os repositórios de imagem e as filas.

Concluída a etapa 2, **retorne a este README**, seção [Como executar → Etapa 3](#etapa-3--database-bootstrap), para executar o **Database Bootstrap estrutural**.

Depois da etapa 5, **retorne mais uma vez** a [Etapa 6 — Usuário administrador inicial](#etapa-6-admin-inicial) para provisionar o administrador exigido pela etapa 11.
