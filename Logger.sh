#!/usr/bin/env bash
# =========================================================
# Sessão bash customizada com logging automático + prompt estilizado
# Uso: source bash_session_logger.sh   (ou coloque no .bashrc)
# =========================================================

# 0. Se o ambiente atual for zsh, força a troca para bash antes de
#    continuar. O resto do script depende de recursos exclusivos do
#    bash (PROMPT_COMMAND, escapes \[ \] no PS1, arrays, EUID, etc.)
#    e não se comporta direito rodando em zsh.
if [ -n "$ZSH_VERSION" ]; then
    _THIS_SCRIPT="${(%):-%x}"

    if [ -f "$_THIS_SCRIPT" ]; then
        # Caminho normal: o script está salvo em um arquivo de verdade,
        # então dá pra reabri-lo quantas vezes for preciso sem risco.
        echo -e "\033[1;33m⚠\033[0m Detectado zsh — trocando para bash nesta sessão..."
        if [ -f "$HOME/.bashrc" ]; then
            exec bash --rcfile <(cat "$HOME/.bashrc"; echo "source '${_THIS_SCRIPT}'") -i
        else
            exec bash --rcfile <(echo "source '${_THIS_SCRIPT}'") -i
        fi
    else
        # Caso "source <(curl ...)": o "arquivo" é na verdade um pipe de
        # leitura única (ex: /proc/self/fd/17), que o zsh já começou a
        # consumir pra chegar até aqui. Reabrir e re-executar esse mesmo
        # descritor dentro do bash não é confiável — ou não sobra nada
        # nele, ou o bash acaba lendo um pedaço do meio do script fora
        # de contexto (é exatamente esse tipo de erro que aparece:
        # "local: can only be used in a function", syntax error etc).
        # Por segurança, aborta em vez de tentar uma troca que pode falhar
        # de forma imprevisível, e orienta a chamar direto com bash.
        echo -e "\033[1;31m✗\033[0m Você está em zsh e rodou isso via pipe (ex: source <(curl ...))."
        echo -e "   Trocar de shell automaticamente nesse caso não é seguro (o pipe já foi parcialmente consumido)."
        echo -e "   Rode assim em vez disso:\n"
        echo -e "   \033[1;37mbash <(curl -fsSL <url-do-script>)\033[0m\n"
        return 1 2>/dev/null || exit 1
    fi
fi

# ---------------------------------------------------------
# EDITE AQUI: comandos executados automaticamente assim que
# você der "source" neste arquivo. Pode ser qualquer comando
# normal, ou usar _run_github_script pra baixar e rodar um
# script de um repositório do GitHub.
#
# Atenção: _run_github_script executa código de terceiros na
# sua máquina. Só use com URLs "raw" (https) de repositórios
# em que você confia.
# ---------------------------------------------------------
STARTUP_COMMANDS=(
    '_run_github_script "https://raw.githubusercontent.com/C1sc066/LoggerLinux/refs/heads/main/dash.sh"'
)

# ---------------------------------------------------------
# EDITE AQUI: atalhos pra rodar seus scripts. A chave é o que você vai
# digitar no terminal, o valor é o comando disparado. Já vem pronto
# pra baixar e rodar um script hospedado no GitHub via _run_github_script.
#
# Atenção: "shift" também é um comando interno do bash (usado dentro
# de scripts/funções pra deslocar parâmetros posicionais). Como alias
# interativo funciona normalmente, mas evite usar esse nome dentro de
# funções que você mesmo escrever neste arquivo.
# ---------------------------------------------------------
declare -A CUSTOM_ALIASES=(
    [shift]='_run_github_script "https://raw.githubusercontent.com/C1sc066/ferramenta_de_automacao/refs/heads/main/LimpezaBinarioAlocacaoEspaco.sh"'
    [dashboard]='_run_github_script "https://raw.githubusercontent.com/C1sc066/LoggerLinux/refs/heads/main/dash.sh"'
)

# Evita reinicialização caso o script seja sourced mais de uma vez
# na mesma sessão (impede PROMPT_COMMAND e redirecionamentos duplicados)
if [ -n "$_BASH_SESSION_LOGGER_ACTIVE" ]; then
    echo -e "\033[1;33m⚠\033[0m Sessão já está sendo registrada em: $BASH_LOG_FILE"
    return 0 2>/dev/null || exit 0
fi
export _BASH_SESSION_LOGGER_ACTIVE=1

# 1. Define o arquivo de log (PID incluso para evitar colisão entre sessões)
export BASH_LOG_FILE="/tmp/bash_session_$(date +%Y%m%d_%H%M%S)_$$.log"
: > "$BASH_LOG_FILE"
chmod 600 "$BASH_LOG_FILE"   # log pode conter dados sensíveis (senhas em comandos, etc)

# Garante histórico atualizado a cada comando
shopt -s histappend

# 2. Define privilégio (root / não-root)
if [ "$EUID" -eq 0 ]; then
    PRIV_STATUS="root"
    PROMPT_PRIV="\[\e[1;41m\]\[\e[1;37m\] ROOT \[\e[0m\]"
    PROMPT_USER="\[\e[1;31m\]\u\[\e[0m\]"
else
    PRIV_STATUS="não-root"
    PROMPT_PRIV="\[\e[1;42m\]\[\e[1;30m\] USER \[\e[0m\]"
    PROMPT_USER="\[\e[1;36m\]\u\[\e[0m\]"
fi

# 3. Alias para o clear não sujar nem limpar o log
alias clear='printf "\033[2J\033[H" > /dev/tty'

# 4. Remove sequências ANSI (cores, cursor, títulos de janela, \r de progress bar)
#    antes de gravar no log
_clean_ansi() {
    sed -u -r \
        -e 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[a-zA-Z]//g' \
        -e 's/\x1B\][^\x07]*\x07//g' \
        -e 's/\r//g'
}

# 5. Função única de prompt: registra o comando anterior no log e
#    monta o PS1 de duas linhas, já refletindo sucesso/erro e git branch.
#    Precisa capturar $? como primeiríssima instrução, antes de qualquer
#    outro comando "consumir" o exit code do que o usuário rodou.
_LAST_LOGGED_CMD=""
_prompt_command() {
    local EXIT_CODE=$?

    # --- logging ---
    local LAST_CMD
    LAST_CMD=$(HISTTIMEFORMAT='' history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    if [ -n "$LAST_CMD" ] && [ "$LAST_CMD" != "$_LAST_LOGGED_CMD" ]; then
        local TIMESTAMP
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        {
            echo ""
            echo "=== ${TIMESTAMP} | ${USER}@${HOSTNAME} (${PRIV_STATUS}) | exit=${EXIT_CODE} ==="
            echo "\$ ${LAST_CMD}"
        } >> "$BASH_LOG_FILE"
        _LAST_LOGGED_CMD="$LAST_CMD"
    fi

    # --- símbolo do prompt conforme o último comando ---
    local SYMBOL_COLOR SYMBOL
    if [ "$EXIT_CODE" -eq 0 ]; then
        SYMBOL_COLOR="\[\e[1;32m\]"
        SYMBOL="❯"
    else
        SYMBOL_COLOR="\[\e[1;31m\]"
        SYMBOL="✗ ${EXIT_CODE}"
    fi

    # --- branch git, se estiver dentro de um repositório ---
    local GIT_INFO=""
    if command -v git >/dev/null 2>&1; then
        local BRANCH
        BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        [ -n "$BRANCH" ] && GIT_INFO=" \[\e[0;35m\] ${BRANCH}\[\e[0m\]"
    fi

    # --- monta o PS1 (duas linhas) ---
    PS1="\[\e[1;30m\]╭─\[\e[0m\][\[\e[2;37m\]\t\[\e[0m\]] ${PROMPT_PRIV} ${PROMPT_USER}@\[\e[1;34m\]\h\[\e[0m\] \[\e[1;33m\]\w\[\e[0m\]${GIT_INFO}\n\[\e[1;30m\]╰─\[\e[0m\]${SYMBOL_COLOR}${SYMBOL}\[\e[0m\] "
}

# 6. Baixa e executa um script de uma URL (ex: raw.githubusercontent.com).
#    Uso dentro de STARTUP_COMMANDS:
#      '_run_github_script "https://raw.githubusercontent.com/usuario/repo/main/script.sh"'
#    Argumentos extras depois da URL são repassados ao script baixado.
_run_github_script() {
    local url="$1"
    shift
    
    
    local tmpfile
    tmpfile=$(mktemp /tmp/gh_script.XXXXXX.sh)
    if curl -fsSL "$url" -o "$tmpfile"; then
        chmod +x "$tmpfile"
        bash "$tmpfile" "$@"
        local rc=$?
        rm -f "$tmpfile"
        return $rc
    else
        echo -e "\e[1;31m✗\e[0m Falha ao baixar: $url" >&2
        rm -f "$tmpfile"
        return 1
    fi
}

# 7. Registra os atalhos definidos em CUSTOM_ALIASES lá no topo do arquivo.
_register_aliases() {
    local name
    for name in "${!CUSTOM_ALIASES[@]}"; do
        alias "$name"="${CUSTOM_ALIASES[$name]}"
    done
}
_register_aliases

# 8. Executa a lista STARTUP_COMMANDS definida lá no topo do arquivo.
#    Roda depois do exec/tee (passo 9), então essa saída também fica
#    registrada no log da sessão.
_run_startup_commands() {
    local cmd
    for cmd in "${STARTUP_COMMANDS[@]}"; do
        [ -z "$cmd" ] && continue
        echo -e "\n\e[1;34m▶\e[0m Executando: \e[1;37m${cmd}\e[0m"
        eval "$cmd"
    done
}

# 9. Duplica a saída (stdout + stderr): a tela continua colorida e em
#    tempo real; o log recebe uma cópia limpa (sem ANSI).
exec > >(tee /dev/tty | _clean_ansi >> "$BASH_LOG_FILE") 2>&1

# 10. Marca o encerramento da sessão no log
_log_session_end() {
    echo "" >> "$BASH_LOG_FILE"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') - Sessão encerrada ===" >> "$BASH_LOG_FILE"
}
trap _log_session_end EXIT

# 11. Encadeia com PROMPT_COMMAND existente, sem duplicar em re-source
case ";${PROMPT_COMMAND};" in
    *";_prompt_command;"*) ;;
    *) export PROMPT_COMMAND="_prompt_command; ${PROMPT_COMMAND:-:}" ;;
esac

echo -e "\033[1;32m✓\033[0m Sessão customizada ativada."
echo -e "\033[1;34mℹ\033[0m Gravando em: $BASH_LOG_FILE"

# Roda os comandos de inicialização configurados lá no topo
_run_startup_commands
