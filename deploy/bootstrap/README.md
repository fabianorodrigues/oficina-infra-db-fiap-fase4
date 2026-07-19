# Bootstrap dos bancos SQL Server (deploy)

Bootstrap estrutural, idempotente e centralizado dos bancos, logins, usuarios e
permissoes da stack Oficina (Fase 4). Executado por um Kubernetes Job dentro do
EKS/VPC, consumindo o master secret gerenciado pelo RDS e os sete secrets SQL
via Secrets Store CSI Driver + ASCP.

## O que cria

```text
3 bancos:  OficinaCadastroDb, OficinaEstoqueDb, OficinaOrdensServicoDb
7 logins:  cadastro_app, cadastro_migrator, estoque_app, estoque_migrator,
           ordens_app, ordens_migrator, auth_read
7 usuarios nos bancos correspondentes
Roles e permissoes minimas + a role auth_reader em OficinaCadastroDb
Isolamento entre bancos (remove usuarios gerenciados em banco indevido)
```

## O que NAO cria

```text
Tabelas funcionais   Migrations EF   Seeds   Dados de teste
```

## Componentes

| Arquivo | Papel |
| ------- | ----- |
| `service-account.yaml` | ServiceAccount consumidora `db-bootstrap` (identidade e policy pertencem a Platform). Sem annotation em pod-identity; o renderer adiciona a annotation IRSA quando aplicavel. |
| `secret-provider-class.template.yaml` | SecretProviderClass do CSI/ASCP. Monta apenas `username`/`password` do master e o campo `Password` de cada secret SQL, via `jmesPath`, com aliases individuais. Nao sincroniza Kubernetes Secret. |
| `job.template.yaml` | Job de execucao unica: `restartPolicy: Never`, `backoffLimit: 0`, `activeDeadlineSeconds: 900`, `ttlSecondsAfterFinished: 1800`, securityContext restrito, volumes CSI (RO), scripts (ConfigMap) e `emptyDir` (RAM) para o SQL renderizado. |
| `kustomization.yaml` | Gera o ConfigMap `oficina-db-bootstrap-scripts` a partir dos scripts canonicos em `scripts/`, sem duplicacao e com nome estavel. |

## Fluxo de dados (por que endpoint/porta vem da pipeline)

A identidade `db-bootstrap` recebe da Platform **somente**
`secretsmanager:DescribeSecret`/`GetSecretValue` sobre o master secret e os sete
secrets SQL — nao recebe `ssm:GetParameter`. Alem disso, o master secret
gerenciado pelo RDS contem apenas `username` e `password`. Portanto:

```text
CSI/ASCP  -> master-username, master-password (master secret)
CSI/ASCP  -> *-password (campo Password dos sete secrets SQL)
Pipeline  -> RDS_HOST e RDS_PORT (nao sensiveis, lidos do SSM pela Action)
```

O endpoint e a porta sao nao sensiveis e entram como variaveis de ambiente do
Job. Nenhuma senha, connection string ou credencial AWS entra em variavel de
ambiente do Kubernetes.

## Dependencias (proprietarios)

```text
Infra DB (Etapa 5):   RDS privado, master secret, containers de secrets, SSM
                      (/oficina/infra/rds/{endpoint,port,master-secret-arn,
                      security-group-id})
Secrets Sync (Etapa 7): sete secrets SQL sincronizados (AWSCURRENT)
Platform:             EKS 'oficina', namespace 'oficina', CSI Driver, ASCP,
                      ServiceAccount db-bootstrap + Pod Identity (ou IRSA),
                      leitura do master secret e dos sete secrets, SSM
                      /oficina/infra/cluster/name, rede EKS -> RDS
```

Nenhum desses recursos e criado por este repositorio: a ServiceAccount aqui e
apenas a declaracao do consumidor. Ausencias sao pre-condicoes a corrigir nos
repositorios proprietarios antes do provisionamento.

## Execucao futura

```text
GitHub -> Actions -> Database Bootstrap Deploy -> Run workflow
       -> Branch: main
       -> confirmation: BOOTSTRAP
```

Pre-requisitos de configuracao do workflow:

```text
Repository Secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
Repository Variables: AWS_REGION, SQL_TOOLS_IMAGE (imagem com sqlcmd, nunca :latest)
```

A imagem `SQL_TOOLS_IMAGE` (ex.: uma tag versionada de
`mcr.microsoft.com/mssql-tools18`) deve ter sua disponibilidade validada antes
do provisionamento. Nenhuma tag `:latest` e aceita.

## Idempotencia

O workflow pode ser repetido com seguranca para:

```text
Criar objetos ausentes      Atualizar passwords (ALTER LOGIN)
Corrigir usuarios orfaos     Reaplicar permissoes
Validar isolamento           Reexecutar a validacao read-only
```

Cada execucao usa um nome de Job unico
(`oficina-db-bootstrap-<run-id>-<attempt>`) para evitar conflito de
imutabilidade, e o TTL remove o Job concluido automaticamente.

## Seguranca

```text
- Nenhum secret no Git; nenhuma password em ConfigMap ou manifest.
- Nenhum Kubernetes Secret funcional (syncSecret desabilitado; sem secretObjects).
- Valores permanecem apenas no volume CSI somente leitura.
- Master secret gerenciado pelo RDS; senha master via SQLCMDPASSWORD (nunca -P).
- Sete passwords entram no SQL como literais T-SQL escapados, nunca em argv.
- SQL renderizado vive em emptyDir (RAM), com 600, e e removido ao final.
- Conexao ao RDS sempre criptografada.
- Logs sanitizados: nenhum valor de secret e impresso; sem 'set -x'.
```
