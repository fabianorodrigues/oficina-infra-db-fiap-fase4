#!/usr/bin/env bash
# Executa um Job de banco no cluster K3s por Systems Manager.
#
# O runner nunca ve valor secreto: ele envia apenas o manifesto (que so tem
# placeholders), o hash do manifesto e nomes de recursos. As credenciais sao
# lidas do Secrets Manager dentro da EC2, materializadas como Secret Kubernetes
# temporario e removidas em bloco finally que roda em sucesso, falha e timeout.
set -euo pipefail

MANIFEST=""
JOB_NAME=""
SECRET_NAME=""
SECRET_SOURCE=""
SUMMARY_TITLE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        --job-name) JOB_NAME="$2"; shift 2 ;;
        --secret-name) SECRET_NAME="$2"; shift 2 ;;
        --secret-source) SECRET_SOURCE="$2"; shift 2 ;;
        --summary-title) SUMMARY_TITLE="$2"; shift 2 ;;
        *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
    esac
done

for required in MANIFEST JOB_NAME SECRET_NAME SECRET_SOURCE; do
    if [ -z "${!required}" ]; then
        echo "Argumento obrigatorio ausente: --${required,,}" >&2
        exit 1
    fi
done

case "$SECRET_SOURCE" in
    bootstrap|isolation|admin) ;;
    *) echo "secret-source invalido: $SECRET_SOURCE" >&2; exit 1 ;;
esac

: "${AWS_REGION:?AWS_REGION ausente}"
: "${K8S_NAMESPACE:?K8S_NAMESPACE ausente}"
: "${K8S_INSTANCE_ID:?K8S_INSTANCE_ID ausente}"
: "${BOOTSTRAP_IMAGE:?BOOTSTRAP_IMAGE ausente}"
: "${RDS_HOST:?RDS_HOST ausente}"
: "${RDS_PORT:?RDS_PORT ausente}"
: "${JOB_TIMEOUT_SECONDS:?JOB_TIMEOUT_SECONDS ausente}"

if [ "$SECRET_SOURCE" = "bootstrap" ] || [ "$SECRET_SOURCE" = "admin" ]; then
    : "${MASTER_SECRET_ID:?MASTER_SECRET_ID ausente}"
fi

if [ "$SECRET_SOURCE" = "admin" ]; then
    : "${HASH_PARAMETER:?HASH_PARAMETER ausente}"
    : "${ADMIN_CPF:?ADMIN_CPF ausente}"
    : "${ADMIN_NOME:?ADMIN_NOME ausente}"
fi

MAX_BYTES="${MAX_MANIFEST_BYTES:-30000}"

[ -f "$MANIFEST" ] || { echo "Manifesto nao encontrado: $MANIFEST" >&2; exit 1; }
size=$(wc -c < "$MANIFEST")
if [ "$size" -gt "$MAX_BYTES" ]; then
    echo "Manifesto de ${size} bytes excede o limite de ${MAX_BYTES}. Truncamento silencioso e o modo de falha que este limite impede." >&2
    exit 1
fi

# O manifesto nao pode conter valor secreto: ele viaja no corpo do comando.
if grep -nEi '(password|senha|secret)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=]{8,}' "$MANIFEST" \
    | grep -v 'secretRef' | grep -v '__[A-Z_]*__'; then
    echo 'O manifesto parece conter um valor sensivel embutido.' >&2
    exit 1
fi

manifest_sha=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
manifest_b64=$(base64 -w0 < "$MANIFEST")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/remote.sh" <<'REMOTE_EOF'
set -euo pipefail
umask 077
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="$PATH:/usr/local/bin"

REGION='@@REGION@@'
NS='@@NAMESPACE@@'
JOB='@@JOB_NAME@@'
SECRET='@@SECRET_NAME@@'
SOURCE='@@SECRET_SOURCE@@'
IMAGE='@@IMAGE@@'
DB_HOST='@@RDS_HOST@@'
DB_PORT='@@RDS_PORT@@'
MASTER_SECRET_ID='@@MASTER_SECRET_ID@@'
HASH_PARAMETER='@@HASH_PARAMETER@@'
ADMIN_CPF_VALUE='@@ADMIN_CPF@@'
ADMIN_NOME_VALUE='@@ADMIN_NOME@@'
RUN_ID='@@RUN_ID@@'
TIMEOUT='@@TIMEOUT@@'
MANIFEST_SHA='@@MANIFEST_SHA@@'
MANIFEST_B64='@@MANIFEST_B64@@'

WORK="$(mktemp -d)"

# Roda em sucesso, falha e timeout. Sem isto, uma falha do Job deixaria o
# Secret temporario vivo no cluster.
cleanup() {
    status=$?
    k3s kubectl -n "$NS" delete secret "$SECRET" --ignore-not-found >/dev/null 2>&1 || true
    k3s kubectl -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT

printf '%s' "$MANIFEST_B64" | base64 -d > "$WORK/job.yaml"
printf '%s  %s\n' "$MANIFEST_SHA" "$WORK/job.yaml" | sha256sum -c - >/dev/null
echo "Manifesto recebido e hash conferido."

# O containerd do K3s nao tem credential helper de ECR: o token e obtido com a
# role da instancia, usado uma vez e limpo da memoria.
TOKEN="$(aws ecr get-login-password --region "$REGION")"
k3s ctr --namespace k8s.io images pull --user "AWS:$TOKEN" "$IMAGE" >/dev/null
unset TOKEN
echo "Imagem disponivel no node."

secret_file="$WORK/secret.yaml"
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' \
    "$SECRET" "$NS" > "$secret_file"

# printf e builtin e base64 le da entrada padrao: nenhum valor secreto aparece
# na linha de comando de um processo.
add_entry() {
    printf '  %s: %s\n' "$1" "$(printf '%s' "$2" | base64 -w0)" >> "$secret_file"
}

read_secret_json() {
    aws secretsmanager get-secret-value --secret-id "$1" --region "$REGION" \
        --query SecretString --output text
}

read_password() {
    read_secret_json "$1" | jq -r '.Password'
}

if [ "$SOURCE" = "bootstrap" ] || [ "$SOURCE" = "admin" ]; then
    master_json="$(read_secret_json "$MASTER_SECRET_ID")"
    add_entry MASTER_USERNAME "$(printf '%s' "$master_json" | jq -r '.username')"
    add_entry MASTER_PASSWORD "$(printf '%s' "$master_json" | jq -r '.password')"
    unset master_json
fi

if [ "$SOURCE" = "bootstrap" ]; then
    add_entry CADASTRO_APP_PASSWORD "$(read_password /oficina/cadastro/runtime-db)"
    add_entry CADASTRO_MIGRATOR_PASSWORD "$(read_password /oficina/cadastro/migration-db)"
    add_entry ESTOQUE_APP_PASSWORD "$(read_password /oficina/estoque/runtime-db)"
    add_entry ESTOQUE_MIGRATOR_PASSWORD "$(read_password /oficina/estoque/migration-db)"
    add_entry ORDENS_APP_PASSWORD "$(read_password /oficina/ordens/runtime-db)"
    add_entry ORDENS_MIGRATOR_PASSWORD "$(read_password /oficina/ordens/migration-db)"
    add_entry AUTH_READ_PASSWORD "$(read_password /oficina/auth/database)"
fi

if [ "$SOURCE" = "isolation" ]; then
    # A prova negativa se conecta como cada um dos seis logins funcionais e
    # nunca como o usuario master.
    add_entry CADASTRO_APP_PASSWORD "$(read_password /oficina/cadastro/runtime-db)"
    add_entry CADASTRO_MIGRATOR_PASSWORD "$(read_password /oficina/cadastro/migration-db)"
    add_entry ESTOQUE_APP_PASSWORD "$(read_password /oficina/estoque/runtime-db)"
    add_entry ESTOQUE_MIGRATOR_PASSWORD "$(read_password /oficina/estoque/migration-db)"
    add_entry ORDENS_APP_PASSWORD "$(read_password /oficina/ordens/runtime-db)"
    add_entry ORDENS_MIGRATOR_PASSWORD "$(read_password /oficina/ordens/migration-db)"
fi

if [ "$SOURCE" = "admin" ]; then
    add_entry ADMIN_CPF "$ADMIN_CPF_VALUE"
    add_entry ADMIN_NOME "$ADMIN_NOME_VALUE"
    add_entry ADMIN_SENHA_HASH "$(aws ssm get-parameter --name "$HASH_PARAMETER" \
        --with-decryption --region "$REGION" --query Parameter.Value --output text)"
fi

k3s kubectl apply -f "$secret_file" >/dev/null
if command -v shred >/dev/null 2>&1; then
    shred -u "$secret_file" 2>/dev/null || rm -f "$secret_file"
else
    rm -f "$secret_file"
fi
echo "Secret temporario criado no cluster."

sed -i \
    -e "s|__RUN_ID__|${RUN_ID}|g" \
    -e "s|__BOOTSTRAP_IMAGE__|${IMAGE}|g" \
    -e "s|__AWS_REGION__|${REGION}|g" \
    -e "s|__RDS_HOST__|${DB_HOST}|g" \
    -e "s|__RDS_PORT__|${DB_PORT}|g" \
    "$WORK/job.yaml"

if grep -qE '__[A-Z0-9_]+__' "$WORK/job.yaml"; then
    echo 'Placeholder nao substituido no manifesto.' >&2
    grep -nE '__[A-Z0-9_]+__' "$WORK/job.yaml" >&2
    exit 1
fi

k3s kubectl apply -f "$WORK/job.yaml" >/dev/null
echo "Job $JOB aplicado."

result=1
deadline=$(( $(date +%s) + TIMEOUT ))
while true; do
    complete_status="$(k3s kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed_status="$(k3s kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    if [ "$complete_status" = "True" ]; then
        result=0
        break
    fi

    if [ "$failed_status" = "True" ]; then
        failed_reason="$(k3s kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null || true)"
        echo "Job $JOB marcou Failed${failed_reason:+ ($failed_reason)}." >&2
        break
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Job $JOB nao concluiu dentro de ${TIMEOUT}s." >&2
        break
    fi

    sleep 5
done

echo "----- logs de $JOB -----"
k3s kubectl -n "$NS" logs "job/$JOB" --tail=-1 2>&1 || true
echo "----- fim dos logs -----"

if [ "$result" -ne 0 ]; then
    echo "Job $JOB nao concluiu com sucesso." >&2
    k3s kubectl -n "$NS" describe "job/$JOB" >&2 2>&1 || true
    exit 1
fi

echo "Job $JOB concluido com sucesso."
REMOTE_EOF

substitute() {
    local token="$1" value="$2"
    python_free_sed_value=$(printf '%s' "$value" | sed -e 's/[\/&|]/\\&/g')
    sed -i "s|@@${token}@@|${python_free_sed_value}|g" "$work/remote.sh"
}

substitute REGION "$AWS_REGION"
substitute NAMESPACE "$K8S_NAMESPACE"
substitute JOB_NAME "$JOB_NAME"
substitute SECRET_NAME "$SECRET_NAME"
substitute SECRET_SOURCE "$SECRET_SOURCE"
substitute IMAGE "$BOOTSTRAP_IMAGE"
substitute RDS_HOST "$RDS_HOST"
substitute RDS_PORT "$RDS_PORT"
substitute MASTER_SECRET_ID "${MASTER_SECRET_ID:-}"
substitute HASH_PARAMETER "${HASH_PARAMETER:-}"
substitute ADMIN_CPF "${ADMIN_CPF:-}"
substitute ADMIN_NOME "${ADMIN_NOME:-}"
substitute RUN_ID "$GITHUB_RUN_ID"
substitute TIMEOUT "$JOB_TIMEOUT_SECONDS"
substitute MANIFEST_SHA "$manifest_sha"
substitute MANIFEST_B64 "$manifest_b64"

if grep -q '@@[A-Z_]*@@' "$work/remote.sh"; then
    echo 'Token nao substituido no comando remoto.' >&2
    exit 1
fi

execution_timeout=$((JOB_TIMEOUT_SECONDS + 600))
jq -Rs --arg t "$execution_timeout" '{commands: [.], executionTimeout: [$t]}' \
    < "$work/remote.sh" > "$work/parameters.json"

command_id=$(aws ssm send-command \
    --instance-ids "$K8S_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "$JOB_NAME" \
    --region "$AWS_REGION" \
    --parameters "file://$work/parameters.json" \
    --query 'Command.CommandId' --output text)

echo "Run Command enviado: $command_id"

status=Pending
deadline=$(( $(date +%s) + JOB_TIMEOUT_SECONDS + 900 ))
while true; do
    status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$K8S_INSTANCE_ID" \
        --region "$AWS_REGION" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
        Success|Failed|Cancelled|TimedOut) break ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Run Command nao concluiu dentro da janela esperada (ultimo status: $status)." >&2
        break
    fi
    sleep 10
done

stdout_content=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$K8S_INSTANCE_ID" \
    --region "$AWS_REGION" --query StandardOutputContent --output text || true)
stderr_content=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$K8S_INSTANCE_ID" \
    --region "$AWS_REGION" --query StandardErrorContent --output text || true)

printf '%s\n' "$stdout_content"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        printf '## %s\n\n' "${SUMMARY_TITLE:-$JOB_NAME}"
        printf '```\n%s\n```\n' "$stdout_content"
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$status" != "Success" ]; then
    printf '%s\n' "$stderr_content" >&2
    echo "Execucao do Job $JOB_NAME falhou com status $status." >&2
    exit 1
fi
