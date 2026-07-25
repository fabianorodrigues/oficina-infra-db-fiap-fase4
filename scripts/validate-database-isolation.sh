#!/usr/bin/env bash
# Prova negativa do isolamento entre os bancos dos tres microsservicos.
#
# Executado como Job Kubernetes com a mesma imagem do bootstrap, que ja reune
# bash e sqlcmd. O ciclo de vida dos Secrets temporarios e do proprio Job
# pertence ao host: um Job que se autolimpa perde a limpeza justamente quando
# falha ou estoura timeout. Este script apenas executa os testes de acesso.
#
# Regras de seguranca:
#   * nunca imprime senhas nem connection strings;
#   * nunca usa 'set -x';
#   * as senhas vao por SQLCMDPASSWORD, nunca por -P na linha de comando.

set -euo pipefail
umask 077

RDS_HOST="${RDS_HOST:-}"
RDS_PORT="${RDS_PORT:-1433}"
LOGIN_TIMEOUT="${SQL_LOGIN_TIMEOUT:-30}"
SQL_ENCRYPT_TRUST_SERVER_CERT="${SQL_ENCRYPT_TRUST_SERVER_CERT:-true}"

DB_CADASTRO="OficinaCadastroDb"
DB_ESTOQUE="OficinaEstoqueDb"
DB_ORDENS="OficinaOrdensServicoDb"

log() { printf '%s %s\n' "[db-isolation]" "$*"; }
fail() { printf '%s %s\n' "[db-isolation][ERRO]" "$*" >&2; exit 1; }

[ -n "$RDS_HOST" ] || fail "RDS_HOST ausente."
case "$RDS_PORT" in
    ''|*[!0-9]*) fail "RDS_PORT invalido." ;;
esac

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

BASE_ARGS=(-S "tcp:${RDS_HOST},${RDS_PORT}" -l "$LOGIN_TIMEOUT" -b -x -N)
if [ "$SQL_ENCRYPT_TRUST_SERVER_CERT" = "true" ]; then
    BASE_ARGS+=(-C)
fi

# login|variavel de ambiente com a senha|banco proprietario|papel
LOGINS=(
    "cadastro_app|CADASTRO_APP_PASSWORD|$DB_CADASTRO|app"
    "cadastro_migrator|CADASTRO_MIGRATOR_PASSWORD|$DB_CADASTRO|migrator"
    "estoque_app|ESTOQUE_APP_PASSWORD|$DB_ESTOQUE|app"
    "estoque_migrator|ESTOQUE_MIGRATOR_PASSWORD|$DB_ESTOQUE|migrator"
    "ordens_app|ORDENS_APP_PASSWORD|$DB_ORDENS|app"
    "ordens_migrator|ORDENS_MIGRATOR_PASSWORD|$DB_ORDENS|migrator"
)
DATABASES=("$DB_CADASTRO" "$DB_ESTOQUE" "$DB_ORDENS")

failures=0
matrix_lines=()

# Conexao explicita por database, sem USE: assim a negacao aparece ja no login,
# e nao apenas na primeira consulta.
try_connect() {
    local user="$1" database="$2"
    "$SQLCMD" "${BASE_ARGS[@]}" -U "$user" -d "$database" -Q "SET NOCOUNT ON; SELECT DB_NAME();" >/dev/null 2>&1
}

run_ddl_probe() {
    local user="$1" database="$2" object="$3"
    local created=0

    if "$SQLCMD" "${BASE_ARGS[@]}" -U "$user" -d "$database" \
        -Q "SET NOCOUNT ON; CREATE TABLE dbo.${object} (Id INT NOT NULL);" >/dev/null 2>&1; then
        created=1
    fi

    # Bloco de limpeza: o objeto sai do schema mesmo quando a criacao nao devia
    # ter sido permitida. Reprovar sem remover deixaria residuo de teste.
    if [ "$created" -eq 1 ]; then
        if ! "$SQLCMD" "${BASE_ARGS[@]}" -U "$user" -d "$database" \
            -Q "SET NOCOUNT ON; DROP TABLE IF EXISTS dbo.${object};" >/dev/null 2>&1; then
            log "AVISO: nao foi possivel remover dbo.${object} em ${database} com ${user}."
            return 2
        fi
    fi

    return "$((1 - created))"
}

log "Matriz de isolamento: 6 logins x 3 bancos."
for entry in "${LOGINS[@]}"; do
    IFS='|' read -r login password_var owner role <<< "$entry"

    password="${!password_var:-}"
    [ -n "$password" ] || fail "Senha ausente para o login ${login}."
    export SQLCMDPASSWORD="$password"
    unset password

    row="$login"
    for database in "${DATABASES[@]}"; do
        if try_connect "$login" "$database"; then
            connected=1
        else
            connected=0
        fi

        if [ "$database" = "$owner" ]; then
            if [ "$connected" -eq 1 ]; then
                row="$row | $database=OK"
            else
                row="$row | $database=FALHA(sem acesso ao proprio banco)"
                failures=$((failures + 1))
            fi
        else
            if [ "$connected" -eq 1 ]; then
                row="$row | $database=FALHA(acesso indevido)"
                failures=$((failures + 1))
            else
                row="$row | $database=NEGADO"
            fi
        fi
    done

    # Teste de DDL somente no banco proprietario.
    object="zz_isolation_$(date +%s)_${$}_${RANDOM}"
    set +e
    run_ddl_probe "$login" "$owner" "$object"
    ddl_status=$?
    set -e

    case "$ddl_status" in
        0)
            # DDL executado com sucesso.
            if [ "$role" = "migrator" ]; then
                row="$row | DDL=OK"
            else
                row="$row | DDL=FALHA(app criou objeto)"
                failures=$((failures + 1))
            fi
            ;;
        1)
            # DDL negado.
            if [ "$role" = "app" ]; then
                row="$row | DDL=NEGADO"
            else
                row="$row | DDL=FALHA(migrator sem DDL)"
                failures=$((failures + 1))
            fi
            ;;
        *)
            row="$row | DDL=FALHA(residuo nao removido)"
            failures=$((failures + 1))
            ;;
    esac

    matrix_lines+=("$row")
    unset SQLCMDPASSWORD
done

log "Resultado:"
for line in "${matrix_lines[@]}"; do
    printf '%s %s\n' "[db-isolation]" "$line"
done

if [ "$failures" -ne 0 ]; then
    fail "Isolamento reprovado em ${failures} verificacao(oes)."
fi

log "Isolamento aprovado: nenhum login acessa banco de outro microsservico, nenhum usuario de aplicacao altera schema."
