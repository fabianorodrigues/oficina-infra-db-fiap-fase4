#!/usr/bin/env bash
# =============================================================================
# run-database-bootstrap.sh
# -----------------------------------------------------------------------------
# Executado dentro do Kubernetes Job db-bootstrap. Le a identidade master e as
# sete senhas funcionais a partir do volume CSI (Secrets Store CSI Driver +
# ASCP), renderiza o SQL de bootstrap em um arquivo temporario em RAM, conecta
# ao RDS SQL Server com conexao criptografada e executa o bootstrap e a
# validacao idempotentes.
#
# Regras de seguranca:
#   * nunca imprime senhas, connection strings, payloads ou o SQL renderizado;
#   * nunca usa 'set -x';
#   * a senha master vai por SQLCMDPASSWORD (variavel de ambiente do sqlcmd),
#     nunca por -P na linha de comando;
#   * as sete senhas funcionais entram no SQL como literais T-SQL ja escapados,
#     nunca como argumentos de linha de comando;
#   * o SQL renderizado vive apenas em emptyDir (RAM), com permissao 600, e e
#     removido no encerramento.
# =============================================================================

# Os marcadores de senha ($(..._PASSWORD_SQL)) sao strings literais propositais,
# substituidas por literais T-SQL antes do sqlcmd. Nao devem expandir no shell.
# shellcheck disable=SC2016

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuracao (nao sensivel). Sobrescrevivel por variavel de ambiente.
# -----------------------------------------------------------------------------
SECRETS_DIR="${SECRETS_DIR:-/mnt/secrets}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/bootstrap/scripts}"
WORK_DIR="${WORK_DIR:-/work}"
SQL_ENCRYPT_TRUST_SERVER_CERT="${SQL_ENCRYPT_TRUST_SERVER_CERT:-true}"
LOGIN_TIMEOUT="${SQL_LOGIN_TIMEOUT:-30}"

RENDERED_SQL="${WORK_DIR}/bootstrap-databases.rendered.sql"

log() { printf '%s %s\n' "[db-bootstrap]" "$*"; }
fail() { printf '%s %s\n' "[db-bootstrap][ERRO]" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Limpeza garantida de artefatos e segredos em memoria.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Localiza o binario sqlcmd (imagem mssql-tools18 ou PATH).
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 1. Endpoint e porta (nao sensiveis) chegam por variavel de ambiente do Job.
# -----------------------------------------------------------------------------
[ -n "${RDS_HOST:-}" ] || fail "RDS_HOST ausente."
[ -n "${RDS_PORT:-}" ] || fail "RDS_PORT ausente."
case "$RDS_PORT" in
    ''|*[!0-9]*) fail "RDS_PORT invalido." ;;
esac

# -----------------------------------------------------------------------------
# 2. Leitura segura de um arquivo montado, rejeitando CR, LF e NUL.
#    Ecoa o conteudo em stdout apenas para captura por command substitution;
#    o valor jamais e impresso.
# -----------------------------------------------------------------------------
read_secret_file() {
    local file="$1"
    local label="$2"
    [ -f "$file" ] || fail "Arquivo montado ausente: ${label}"
    [ -s "$file" ] || fail "Arquivo montado vazio: ${label}"
    local bad
    bad="$(LC_ALL=C tr -cd '\r\n\000' < "$file" | wc -c | tr -d '[:space:]')"
    [ "$bad" = "0" ] || fail "Valor de ${label} contem CR, LF ou NUL."
    local value
    value="$(<"$file")"
    [ -n "$value" ] || fail "Valor de ${label} vazio apos leitura."
    printf '%s' "$value"
}

# Escape para literal T-SQL: duplica cada aspa simples. Nada mais e alterado.
escape_tsql() {
    local raw="$1"
    printf '%s' "${raw//\'/\'\'}"
}

log "Validando arquivos montados pelo CSI..."
MASTER_USER="$(read_secret_file "${SECRETS_DIR}/master-username" 'master-username')"
MASTER_PASSWORD="$(read_secret_file "${SECRETS_DIR}/master-password" 'master-password')"

CADASTRO_APP_RAW="$(read_secret_file "${SECRETS_DIR}/cadastro-app-password" 'cadastro-app-password')"
CADASTRO_MIGRATOR_RAW="$(read_secret_file "${SECRETS_DIR}/cadastro-migrator-password" 'cadastro-migrator-password')"
ESTOQUE_APP_RAW="$(read_secret_file "${SECRETS_DIR}/estoque-app-password" 'estoque-app-password')"
ESTOQUE_MIGRATOR_RAW="$(read_secret_file "${SECRETS_DIR}/estoque-migrator-password" 'estoque-migrator-password')"
ORDENS_APP_RAW="$(read_secret_file "${SECRETS_DIR}/ordens-app-password" 'ordens-app-password')"
ORDENS_MIGRATOR_RAW="$(read_secret_file "${SECRETS_DIR}/ordens-migrator-password" 'ordens-migrator-password')"
AUTH_READ_RAW="$(read_secret_file "${SECRETS_DIR}/auth-read-password" 'auth-read-password')"

# -----------------------------------------------------------------------------
# 3. Escape T-SQL das sete senhas funcionais.
# -----------------------------------------------------------------------------
CADASTRO_APP_SQL="$(escape_tsql "$CADASTRO_APP_RAW")"
CADASTRO_MIGRATOR_SQL="$(escape_tsql "$CADASTRO_MIGRATOR_RAW")"
ESTOQUE_APP_SQL="$(escape_tsql "$ESTOQUE_APP_RAW")"
ESTOQUE_MIGRATOR_SQL="$(escape_tsql "$ESTOQUE_MIGRATOR_RAW")"
ORDENS_APP_SQL="$(escape_tsql "$ORDENS_APP_RAW")"
ORDENS_MIGRATOR_SQL="$(escape_tsql "$ORDENS_MIGRATOR_RAW")"
AUTH_READ_SQL="$(escape_tsql "$AUTH_READ_RAW")"

# Libera as versoes cruas assim que os literais escapados existem.
unset CADASTRO_APP_RAW CADASTRO_MIGRATOR_RAW ESTOQUE_APP_RAW ESTOQUE_MIGRATOR_RAW \
      ORDENS_APP_RAW ORDENS_MIGRATOR_RAW AUTH_READ_RAW

# -----------------------------------------------------------------------------
# 4. Renderizacao do SQL em memoria (substituicao literal, sem regex/sed).
# -----------------------------------------------------------------------------
BOOTSTRAP_TEMPLATE="${SCRIPTS_DIR}/bootstrap-databases.sql"
VALIDATE_SQL="${SCRIPTS_DIR}/validate-databases.sql"
[ -f "$BOOTSTRAP_TEMPLATE" ] || fail "Script ausente: bootstrap-databases.sql"
[ -f "$VALIDATE_SQL" ] || fail "Script ausente: validate-databases.sql"

rendered="$(<"$BOOTSTRAP_TEMPLATE")"

t_cadastro_app='$(CADASTRO_APP_PASSWORD_SQL)'
t_cadastro_migrator='$(CADASTRO_MIGRATOR_PASSWORD_SQL)'
t_estoque_app='$(ESTOQUE_APP_PASSWORD_SQL)'
t_estoque_migrator='$(ESTOQUE_MIGRATOR_PASSWORD_SQL)'
t_ordens_app='$(ORDENS_APP_PASSWORD_SQL)'
t_ordens_migrator='$(ORDENS_MIGRATOR_PASSWORD_SQL)'
t_auth_read='$(AUTH_READ_PASSWORD_SQL)'

rendered="${rendered//"$t_cadastro_app"/$CADASTRO_APP_SQL}"
rendered="${rendered//"$t_cadastro_migrator"/$CADASTRO_MIGRATOR_SQL}"
rendered="${rendered//"$t_estoque_app"/$ESTOQUE_APP_SQL}"
rendered="${rendered//"$t_estoque_migrator"/$ESTOQUE_MIGRATOR_SQL}"
rendered="${rendered//"$t_ordens_app"/$ORDENS_APP_SQL}"
rendered="${rendered//"$t_ordens_migrator"/$ORDENS_MIGRATOR_SQL}"
rendered="${rendered//"$t_auth_read"/$AUTH_READ_SQL}"

# Nenhum marcador pode restar apos a renderizacao.
for token in \
    "$t_cadastro_app" "$t_cadastro_migrator" "$t_estoque_app" "$t_estoque_migrator" \
    "$t_ordens_app" "$t_ordens_migrator" "$t_auth_read"; do
    case "$rendered" in
        *"$token"*) fail "Marcador de senha nao substituido no SQL renderizado." ;;
    esac
done

# Libera os literais escapados apos a renderizacao.
unset CADASTRO_APP_SQL CADASTRO_MIGRATOR_SQL ESTOQUE_APP_SQL ESTOQUE_MIGRATOR_SQL \
      ORDENS_APP_SQL ORDENS_MIGRATOR_SQL AUTH_READ_SQL

mkdir -p "$WORK_DIR"
( umask 077; printf '%s' "$rendered" > "$RENDERED_SQL" )
chmod 600 "$RENDERED_SQL" 2>/dev/null || true
unset rendered
log "SQL de bootstrap renderizado em arquivo temporario (RAM)."

# -----------------------------------------------------------------------------
# 5. Argumentos de conexao. Conexao sempre criptografada (-N).
# -----------------------------------------------------------------------------
conn_args=(-S "tcp:${RDS_HOST},${RDS_PORT}" -U "$MASTER_USER" -d master -l "$LOGIN_TIMEOUT" -b -x -N)
if [ "$SQL_ENCRYPT_TRUST_SERVER_CERT" = "true" ]; then
    conn_args+=(-C)
    log "Aviso: validacao do certificado do servidor desabilitada (-C). Conexao permanece criptografada."
fi

export SQLCMDPASSWORD="$MASTER_PASSWORD"
unset MASTER_PASSWORD

log "Conectando ao RDS em ${RDS_HOST}:${RDS_PORT} como usuario master (senha via SQLCMDPASSWORD)."

# -----------------------------------------------------------------------------
# 6. Execucao do bootstrap idempotente.
# -----------------------------------------------------------------------------
log "Executando bootstrap-databases (rendered)..."
if ! "$SQLCMD" "${conn_args[@]}" -i "$RENDERED_SQL"; then
    fail "Falha na execucao de bootstrap-databases."
fi
log "Bootstrap concluido."

# -----------------------------------------------------------------------------
# 7. Execucao da validacao read-only.
# -----------------------------------------------------------------------------
log "Executando validate-databases..."
if ! "$SQLCMD" "${conn_args[@]}" -i "$VALIDATE_SQL"; then
    fail "Falha na validacao de bancos, logins, usuarios ou isolamento."
fi
log "Validacao concluida com sucesso."

log "Bootstrap estrutural finalizado. Bancos, logins, usuarios e permissoes conferidos."
