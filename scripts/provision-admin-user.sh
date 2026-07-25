#!/usr/bin/env bash
# Executado dentro de um Job Kubernetes, na mesma imagem do bootstrap. Le a
# identidade master do RDS dos secrets injetados no cluster e os dados do admin
# inicial (CPF, nome e hash PBKDF2) de variaveis de ambiente, renderiza o SQL em
# arquivo temporario restrito e executa o provisionamento idempotente quando as
# migrations do Cadastro ja criaram dbo.Funcionarios.

# Os marcadores ($(ADMIN_*_SQL)) sao strings literais propositais, substituidas
# por literais T-SQL antes do sqlcmd. Nao devem expandir no shell.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/bootstrap/scripts}"
WORK_DIR="${WORK_DIR:-/work}"
SQL_ENCRYPT_TRUST_SERVER_CERT="${SQL_ENCRYPT_TRUST_SERVER_CERT:-true}"
LOGIN_TIMEOUT="${SQL_LOGIN_TIMEOUT:-30}"

RENDERED_SQL="${WORK_DIR}/provision-admin-user.rendered.sql"

log() { printf '%s %s\n' "[provision-admin]" "$*"; }
fail() { printf '%s %s\n' "[provision-admin][ERRO]" "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    if [ -f "$RENDERED_SQL" ]; then
        if command -v shred >/dev/null 2>&1; then
            shred -u "$RENDERED_SQL" 2>/dev/null || rm -f "$RENDERED_SQL"
        else
            rm -f "$RENDERED_SQL"
        fi
    fi
    unset SQLCMDPASSWORD 2>/dev/null || true
    return "$status"
}
trap cleanup EXIT

SQLCMD=""
for candidate in \
    "${SQLCMD_PATH:-}" \
    /opt/mssql-tools18/bin/sqlcmd \
    /opt/mssql-tools/bin/sqlcmd; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then SQLCMD="$candidate"; break; fi
done
if [ -z "$SQLCMD" ] && command -v sqlcmd >/dev/null 2>&1; then
    SQLCMD="$(command -v sqlcmd)"
fi
[ -n "$SQLCMD" ] || fail "sqlcmd nao encontrado na imagem."

[ -n "${RDS_HOST:-}" ] || fail "RDS_HOST ausente."
[ -n "${RDS_PORT:-}" ] || fail "RDS_PORT ausente."
case "$RDS_PORT" in
    ''|*[!0-9]*) fail "RDS_PORT invalido." ;;
esac

read_secret_value() {
    local env_name="$1"
    local label="$2"
    local value="${!env_name:-}"
    [ -n "$value" ] || fail "Valor ausente ou vazio: ${label}"
    local bad
    bad="$(printf '%s' "$value" | LC_ALL=C tr -cd '\r\n\000' | wc -c | tr -d '[:space:]')"
    [ "$bad" = "0" ] || fail "Valor de ${label} contem CR, LF ou NUL."
    printf '%s' "$value"
}

# Escape para literal T-SQL: duplica cada aspa simples. Nada mais e alterado.
escape_tsql() {
    local raw="$1"
    printf '%s' "${raw//\'/\'\'}"
}

log "Validando identidade master e pre-condicoes do admin inicial..."
MASTER_USER="$(read_secret_value MASTER_USERNAME 'master-username')"
MASTER_PASSWORD="$(read_secret_value MASTER_PASSWORD 'master-password')"

conn_args=(-S "tcp:${RDS_HOST},${RDS_PORT}" -U "$MASTER_USER" -d master -l "$LOGIN_TIMEOUT" -b -x -N)
if [ "$SQL_ENCRYPT_TRUST_SERVER_CERT" = "true" ]; then
    conn_args+=(-C)
    log "Aviso: validacao do certificado do servidor desabilitada (-C). Conexao permanece criptografada."
fi

export SQLCMDPASSWORD="$MASTER_PASSWORD"
unset MASTER_PASSWORD

log "Conectando ao RDS em ${RDS_HOST}:${RDS_PORT} como usuario master (senha via SQLCMDPASSWORD)."

precheck_query="SET NOCOUNT ON; IF DB_ID(N'OficinaCadastroDb') IS NULL SELECT N'MISSING_DATABASE'; ELSE IF NOT EXISTS (SELECT 1 FROM [OficinaCadastroDb].sys.tables t JOIN [OficinaCadastroDb].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'dbo' AND t.name = N'Funcionarios') SELECT N'MISSING_FUNCIONARIOS'; ELSE SELECT N'READY';"
precheck_result="$("$SQLCMD" "${conn_args[@]}" -h -1 -W -Q "$precheck_query" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '[:space:]')"

case "$precheck_result" in
    READY)
        log "Pre-condicoes conferidas: OficinaCadastroDb.dbo.Funcionarios existe."
        ;;
    MISSING_FUNCIONARIOS)
        fail "dbo.Funcionarios nao existe. Execute o Cadastro Deploy primeiro e depois rode o workflow Initial Admin Provision."
        ;;
    MISSING_DATABASE)
        fail "OficinaCadastroDb nao existe. Rode o bootstrap estrutural dos bancos antes."
        ;;
    *)
        fail "Resultado inesperado ao verificar pre-condicoes do admin inicial: ${precheck_result:-vazio}"
        ;;
esac

log "Validando dados do admin inicial..."
ADMIN_CPF_RAW="$(read_secret_value ADMIN_CPF 'ADMIN_INICIAL_CPF')"
ADMIN_NOME_RAW="$(read_secret_value ADMIN_NOME 'ADMIN_NOME')"
ADMIN_SENHA_HASH_RAW="$(read_secret_value ADMIN_SENHA_HASH 'ADMIN_SENHA_HASH')"

case "$ADMIN_CPF_RAW" in
    *[!0-9]*) fail "ADMIN_INICIAL_CPF deve conter apenas digitos." ;;
esac
[ "${#ADMIN_CPF_RAW}" -eq 11 ] || fail "ADMIN_INICIAL_CPF deve ter exatamente 11 digitos."

[ "${#ADMIN_NOME_RAW}" -le 150 ] || fail "ADMIN_NOME excede 150 caracteres."

case "$ADMIN_SENHA_HASH_RAW" in
    'PBKDF2-SHA256$'*) : ;;
    *) fail "ADMIN_SENHA_HASH nao usa o algoritmo PBKDF2-SHA256 esperado." ;;
esac
[ "${#ADMIN_SENHA_HASH_RAW}" -le 500 ] || fail "ADMIN_SENHA_HASH excede 500 caracteres."

hash_corpo="${ADMIN_SENHA_HASH_RAW#'PBKDF2-SHA256$'}"
hash_iteracoes="${hash_corpo%%'$'*}"
case "$hash_iteracoes" in
    ''|*[!0-9]*) fail "ADMIN_SENHA_HASH nao traz uma contagem de iteracoes numerica." ;;
esac
[ "$hash_iteracoes" -ge 100000 ] || fail "ADMIN_SENHA_HASH precisa de no minimo 100000 iteracoes."

# Precisa haver salt e hash separados por '$' apos a contagem de iteracoes.
hash_partes="$(printf '%s' "$ADMIN_SENHA_HASH_RAW" | tr -cd '$' | wc -c | tr -d '[:space:]')"
[ "$hash_partes" = "3" ] || fail "ADMIN_SENHA_HASH deve ter o formato PBKDF2-SHA256\$iteracoes\$salt\$hash."

ADMIN_CPF_SQL="$(escape_tsql "$ADMIN_CPF_RAW")"
ADMIN_NOME_SQL="$(escape_tsql "$ADMIN_NOME_RAW")"
ADMIN_SENHA_HASH_SQL="$(escape_tsql "$ADMIN_SENHA_HASH_RAW")"

unset ADMIN_CPF_RAW ADMIN_NOME_RAW ADMIN_SENHA_HASH_RAW

TEMPLATE="${SCRIPTS_DIR}/provision-admin-user.sql"
[ -f "$TEMPLATE" ] || fail "Script ausente: provision-admin-user.sql"

rendered="$(<"$TEMPLATE")"

t_cpf='$(ADMIN_CPF_SQL)'
t_nome='$(ADMIN_NOME_SQL)'
t_hash='$(ADMIN_SENHA_HASH_SQL)'

rendered="${rendered//"$t_cpf"/$ADMIN_CPF_SQL}"
rendered="${rendered//"$t_nome"/$ADMIN_NOME_SQL}"
rendered="${rendered//"$t_hash"/$ADMIN_SENHA_HASH_SQL}"

# Nenhum marcador pode restar apos a renderizacao.
for token in "$t_cpf" "$t_nome" "$t_hash"; do
    case "$rendered" in
        *"$token"*) fail "Marcador nao substituido no SQL renderizado." ;;
    esac
done

unset ADMIN_CPF_SQL ADMIN_NOME_SQL ADMIN_SENHA_HASH_SQL

sql_executavel="$(printf '%s\n' "$rendered" | sed 's/--.*$//' | tr '[:lower:]' '[:upper:]')"

for proibido in \
    'DROP ' 'DELETE ' 'TRUNCATE ' 'ALTER ' 'GRANT ' 'REVOKE ' 'DENY ' \
    'CREATE ' 'EXEC' 'MERGE ' 'BULK ' 'OPENROWSET' 'OPENQUERY' \
    'XP_' 'SP_' 'SHUTDOWN' 'RECONFIGURE' 'BACKUP ' 'RESTORE '; do
    case "$sql_executavel" in
        *"$proibido"*) fail "SQL renderizado contem operacao fora do escopo do provisionamento: ${proibido}" ;;
    esac
done

for obrigatorio in 'DBO.FUNCIONARIOS' 'OFICINACADASTRODB'; do
    case "$sql_executavel" in
        *"$obrigatorio"*) : ;;
        *) fail "SQL renderizado nao corresponde ao provisionamento esperado (faltou ${obrigatorio})." ;;
    esac
done

# Somente uma tabela pode ser escrita: dbo.Funcionarios. As duas escritas
# previstas sao o UPDATE do caminho idempotente e o INSERT do caminho novo.
# Contamos OCORRENCIAS (grep -o), nao linhas: varios statements podem estar na
# mesma linha e uma contagem por linha deixaria passar escrita em outra tabela.
contar_ocorrencias() {
    { printf '%s\n' "$sql_executavel" | grep -o -E "$1" || true; } | wc -l | tr -d '[:space:]'
}

escritas_funcionarios="$(contar_ocorrencias '(INSERT INTO|UPDATE)[[:space:]]+DBO\.FUNCIONARIOS')"
[ "$escritas_funcionarios" = "2" ] || fail "SQL renderizado nao tem exatamente as duas escritas previstas em dbo.Funcionarios (encontradas: ${escritas_funcionarios})."

total_escritas="$(contar_ocorrencias '(INSERT INTO|UPDATE)[[:space:]]')"
[ "$total_escritas" = "$escritas_funcionarios" ] || fail "SQL renderizado escreve em tabela fora de dbo.Funcionarios (${total_escritas} escritas, ${escritas_funcionarios} em dbo.Funcionarios)."

log "SQL renderizado validado: escopo restrito ao admin inicial em dbo.Funcionarios."

mkdir -p "$WORK_DIR"
( umask 077; printf '%s' "$rendered" > "$RENDERED_SQL" )
chmod 600 "$RENDERED_SQL" 2>/dev/null || true
unset rendered sql_executavel

log "Provisionando o admin inicial em OficinaCadastroDb.dbo.Funcionarios..."
if ! "$SQLCMD" "${conn_args[@]}" -i "$RENDERED_SQL"; then
    fail "Falha ao provisionar o admin inicial."
fi

log "Admin inicial provisionado e verificado. Nenhum valor sensivel foi impresso."
