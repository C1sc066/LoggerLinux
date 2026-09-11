#!/bin/sh
# ==============================================================================
# Script: isc_monitor.sh
# Finalidade: Monitoramento visual direto de instâncias de banco de dados
#             com leitura de backup Full e Incremental.
# Shell: POSIX sh 100% compatível
# ==============================================================================

# Cores e Estilos ANSI (Degradê Suave de 6 Estágios)
# Cores e Estilos ANSI (Compatível com curl ... | bash)
# Se stdout for terminal OU se $TERM estiver definido e não for "dumb", ativa cores
if [ -t 1 ] || [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
    CLR_RESET="\033[0m"
    CLR_BOLD="\033[1m"
    CLR_DIM="\033[2m"
    
    # Tons do Gradiente Horizontal
    G1="\033[38;5;51m"   # Ciano Claro
    G2="\033[38;5;45m"   # Ciano Médio
    G3="\033[38;5;39m"   # Azul Céu
    G4="\033[38;5;69m"   # Azul Real
    G5="\033[38;5;99m"   # Violeta
    G6="\033[38;5;135m"  # Roxo/Magenta
    
    CLR_BLUE="\033[38;5;39m"
    CLR_PURPLE="\033[38;5;141m"
    CLR_GREEN="\033[38;5;77m"
    CLR_RED="\033[38;5;203m"
    CLR_YELLOW="\033[38;5;221m"
    CLR_GRAY="\033[38;5;242m"
    CLR_LIGHT_GRAY="\033[38;5;250m"
    CLR_WHITE="\033[38;5;255m"
else
    CLR_RESET=""
    CLR_BOLD=""
    CLR_DIM=""
    G1=""
    G2=""
    G3=""
    G4=""
    G5=""
    G6=""
    CLR_BLUE=""
    CLR_PURPLE=""
    CLR_GREEN=""
    CLR_RED=""
    CLR_YELLOW=""
    CLR_GRAY=""
    CLR_LIGHT_GRAY=""
    CLR_WHITE=""
fi

TMP_DIR=$(mktemp -d /tmp/db_mon.XXXXXX 2>/dev/null || echo "/tmp/db_mon_$$")
[ -d "$TMP_DIR" ] || mkdir -p "$TMP_DIR"
INSTANCES_FILE="$TMP_DIR/instances.tsv"
touch "$INSTANCES_FILE"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

get_uptime_formatted() {
    up_p=$(uptime -p 2>/dev/null)
    if [ -n "$up_p" ]; then
        echo "$up_p"
        return
    fi

    if [ -f /proc/uptime ]; then
        uptime_sec=$(cut -d. -f1 /proc/uptime)
        weeks=$((uptime_sec / 604800))
        days=$(( (uptime_sec % 604800) / 86400 ))
        hours=$(( (uptime_sec % 86400) / 3600 ))
        mins=$(( (uptime_sec % 3600) / 60 ))

        res="up "
        [ "$weeks" -gt 0 ] && res="${res}${weeks} weeks, "
        [ "$days" -gt 0 ] || [ "$weeks" -gt 0 ] && res="${res}${days} days, "
        [ "$hours" -gt 0 ] || [ "$days" -gt 0 ] || [ "$weeks" -gt 0 ] && res="${res}${hours} hours, "
        res="${res}${mins} minutes"
        echo "$res"
    else
        uptime | sed -e 's/^[ \t]*//' -e 's/,  / /g' | awk -F',' '{print $1}'
    fi
}

run_command() {
    cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    elif [ -x "/usr/local/bin/$cmd" ]; then
        return 0
    elif [ -x "/bin/$cmd" ]; then
        return 0
    fi
    return 1
}

parse_raw_instances() {
    raw_file="$1"
    default_type="$2"

    awk -v def_type="$default_type" '
    function trim(s) {
        sub(/^[ \t\r\n]+/, "", s);
        sub(/[ \t\r\n]+$/, "", s);
        return s;
    }
    function flush_record() {
        if (conf != "") {
            print (type ? type : def_type) "\t" \
                  conf "\t" \
                  dir "\t" \
                  status_full "\t" \
                  state;
        }
        type = def_type;
        conf = ""; dir = ""; status_full = ""; state = "";
    }
    BEGIN {
        FS = ":";
    }
    /^[ \t]*Configuration[ \t]+[\x27\x22]/ {
        flush_record();
        match($0, /[\x27\x22][^\x27\x22]+[\x27\x22]/);
        if (RSTART > 0) {
            conf = substr($0, RSTART + 1, RLENGTH - 2);
        }
        next;
    }
    {
        line = $0;
        sub(/^[ \t]+/, "", line);
        idx = index(line, ":");
        if (idx > 0) {
            key = tolower(trim(substr(line, 1, idx - 1)));
            val = trim(substr(line, idx + 1));

            if (key == "directory") {
                dir = val;
            } else if (key == "status") {
                status_full = val;
            } else if (key == "state") {
                state = val;
            }
        }
    }
    END {
        flush_record();
    }
    ' "$raw_file"
}

find_latest_file_by_pattern() {
    bck_dir="$1"
    pattern="$2"
    [ -d "$bck_dir" ] || return 1

    latest_file=$(
        for f in "$bck_dir"/${pattern}*.log; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            date_part=$(echo "$fname" | grep -oE '[12][0-9]{3}[01][0-9][0-3][0-9]' | head -n 1)

            if [ -n "$date_part" ]; then
                mod_time=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
                printf "%s_%s|%s\n" "$date_part" "$mod_time" "$f"
            else
                mod_time=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
                printf "00000000_%s|%s\n" "$mod_time" "$f"
            fi
        done | sort -r | head -n 1 | cut -d'|' -f2
    )

    [ -n "$latest_file" ] && [ -f "$latest_file" ] && echo "$latest_file"
}

analyze_backup_file() {
    log_file="$1"

    if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
        echo "NOT_FOUND"
        return
    fi

    tail_content=$(tail -n 120 "$log_file" 2>/dev/null)

    has_failed=$(printf "%s\n" "$tail_content" | grep -Ei '\[Backup failed\.\]|Backup failed|Device Full|Terminating backup|Copy of .* aborted|\*\*\* BACKUP ABORTED \*\*\*|Write error')
    has_success=$(printf "%s\n" "$tail_content" | grep -Ei 'Backup complete\.|\[Backup completed successfully\]|\*\*\*FINISHED BACKUP\*\*\*')

    if [ -n "$has_failed" ]; then
        echo "FAILED"
    elif [ -n "$has_success" ]; then
        echo "SUCCESS"
    else
        echo "UNKNOWN"
    fi
}

format_backup_status() {
    status="$1"
    case "$status" in
        SUCCESS)
            printf "%b✓ concluído com sucesso%b" "$CLR_GREEN" "$CLR_RESET"
            ;;
        FAILED)
            printf "%b✗ falhou%b" "$CLR_RED" "$CLR_RESET"
            ;;
        UNKNOWN)
            printf "%b? inconclusivo / erro na passada%b" "$CLR_YELLOW" "$CLR_RESET"
            ;;
        *)
            printf "%b? não identificado%b" "$CLR_YELLOW" "$CLR_RESET"
            ;;
    esac
}

extract_date_br() {
    file="$1"
    fname=$(basename "$file")
    raw_date=$(echo "$fname" | grep -oE '[12][0-9]{3}[01][0-9][0-3][0-9]' | head -n 1)
    if [ -n "$raw_date" ]; then
        y=$(echo "$raw_date" | cut -c1-4)
        m=$(echo "$raw_date" | cut -c5-6)
        d=$(echo "$raw_date" | cut -c7-8)
        echo "$d/$m/$y"
    else
        date '+%d/%m/%Y'
    fi
}

collect_instances() {
    tmp_raw="$TMP_DIR/raw_cmd.out"

    if run_command "ccontrol"; then
        ccontrol list > "$tmp_raw" 2>/dev/null
        parse_raw_instances "$tmp_raw" "Caché" >> "$INSTANCES_FILE"
    fi

    if run_command "iris"; then
        iris list > "$tmp_raw" 2>/dev/null
        parse_raw_instances "$tmp_raw" "IRIS" >> "$INSTANCES_FILE"
    fi
}

render_compact() {
    # Renderizador da logo com Gradiente de 6 passos (B -> E -> M -> V/I -> N/D -> O)
    printf "\n"
    _grad() {
        printf "%b%s%b%s%b%s%b%s%b%s%b%s%b\n" \
            "$G1" "$1" "$G2" "$2" "$G3" "$3" "$G4" "$4" "$G5" "$5" "$G6" "$6" "$CLR_RESET"
    }

    _grad '   /$$$$$$$ ' '  /$$$$$$$$' '  /$$      /$$' '     /$$    /$$  /$$$$$$' '  /$$   /$$  /$$$$$$$ ' '   /$$$$$$ '
    _grad '  | $$__  $$' ' | $$_____/' ' | $$$    /$$$' '    | $$   | $$ |_  $$_/' ' | $$$ | $$ | $$__  $$' '  /$$__  $$'
    _grad '  | $$  \ $$' ' | $$      ' ' | $$$$  /$$$$' '    | $$   | $$   | $$  ' ' | $$$$| $$ | $$  \ $$' ' | $$  \ $$'
    _grad '  | $$$$$$$ ' ' | $$$$$   ' ' | $$ $$/$$ $$' '    |  $$ / $$/   | $$  ' ' | $$ $$ $$ | $$  | $$' ' | $$  | $$'
    _grad '  | $$__  $$' ' | $$__/   ' ' | $$  $$$| $$' '     \  $$ $$/    | $$  ' ' | $$  $$$$ | $$  | $$' ' | $$  | $$'
    _grad '  | $$  \ $$' ' | $$      ' ' | $$\  $ | $$' '      \  $$$/     | $$  ' ' | $$\  $$$ | $$  | $$' ' | $$  | $$'
    _grad '  | $$$$$$$/' ' | $$$$$$$$' ' | $$ \/  | $$' '       \  $/     /$$$$$$' ' | $$ \  $$ | $$$$$$$/' ' |  $$$$$$/'
    _grad '  |_______/ ' ' |________/' ' |__/     |__/' '        \_/     |______/' ' |__/  \__/ |_______/ ' '  \______/ '
    printf "\n"

    uptime_val=$(get_uptime_formatted)
    today_ymd=$(date '+%Y%m%d')

    # Cartão de Informações Gerais do Host
    printf "  ${CLR_GRAY}╭──────────────────────────────────────────────────────────────────────────╮${CLR_RESET}\n"
    printf "  ${CLR_GRAY}│${CLR_RESET}  ${CLR_BOLD}Uptime do servidor :${CLR_RESET}  %-50s ${CLR_GRAY}│${CLR_RESET}\n" "$uptime_val"
    
    total_instances=$(wc -l < "$INSTANCES_FILE" | tr -d ' ')
    printf "  ${CLR_GRAY}│${CLR_RESET}  ${CLR_BOLD}Instâncias ativas  :${CLR_RESET}  ${G2}%-50s${CLR_RESET} ${CLR_GRAY}│${CLR_RESET}\n" "$total_instances"
    printf "  ${CLR_GRAY}╰──────────────────────────────────────────────────────────────────────────╯${CLR_RESET}\n\n"

    printf "${CLR_GRAY}──────────────────────────────────────────────────────────────────────────────${CLR_RESET}\n"

    if [ "$total_instances" -eq 0 ]; then
        printf "\n  ${CLR_YELLOW}[!] Nenhuma instância detectada no servidor.${CLR_RESET}\n\n"
        printf "${CLR_GRAY}──────────────────────────────────────────────────────────────────────────────${CLR_RESET}\n"
        return
    fi

    while IFS="$(printf '\t')" read -r itype iconf idir istatus istate; do
        [ -z "$iconf" ] && continue

        tag="DB"
        tag_color="$G3"
        case "$iconf" in
            *IRIS*|*iris*)         tag="IRIS"; tag_color="$G3" ;;
            *ENSEMBLE*|*ensemble*) tag="ENSEMBLE"; tag_color="$G5" ;;
            *CACHE*|*cache*)       tag="CACHÉ"; tag_color="$G5" ;;
            *)                     tag="DB"; tag_color="$G4" ;;
        esac

        u_status=$(echo "$istatus" | tr '[:lower:]' '[:upper:]')
        u_state=$(echo "$istate" | tr '[:lower:]' '[:upper:]')
        
        case "$u_status" in
            *RUNNING*) status_c="$CLR_GREEN" ;;
            *HUNG*|*STOPPED*) status_c="$CLR_RED" ;;
            *) status_c="$CLR_YELLOW" ;;
        esac

        case "$u_state" in
            *OK*) state_c="$CLR_GREEN" ;;
            *) state_c="$CLR_RED" ;;
        esac

        backup_dir="${idir}/mgr/Backup"

        printf "\n  ${tag_color}◆ [%s]${CLR_RESET} ${CLR_BOLD}${CLR_WHITE}%s${CLR_RESET}\n\n" "$tag" "$iconf"
        printf "    ${CLR_GRAY}•${CLR_RESET} ${CLR_LIGHT_GRAY}%-15s:${CLR_RESET} %s\n" "Diretório" "${idir:-N/A}"
        printf "    ${CLR_GRAY}•${CLR_RESET} ${CLR_LIGHT_GRAY}%-15s:${CLR_RESET} %b%s%b\n" "Status" "$status_c" "${istatus:-N/A}" "$CLR_RESET"
        printf "    ${CLR_GRAY}•${CLR_RESET} ${CLR_LIGHT_GRAY}%-15s:${CLR_RESET} %b%s%b\n\n" "State" "$state_c" "${istate:-N/A}" "$CLR_RESET"

        # 1. Análise do Backup Full
        latest_full=$(find_latest_file_by_pattern "$backup_dir" "FullDBList")
        if [ -n "$latest_full" ]; then
            full_date_str=$(extract_date_br "$latest_full")
            full_status=$(analyze_backup_file "$latest_full")
            formatted_status=$(format_backup_status "$full_status")
            printf "    ${G3}▪${CLR_RESET} %-23s: %b\n" "backup Full ($full_date_str)" "$formatted_status"

            full_fname=$(basename "$latest_full")
            case "$full_fname" in
                *${today_ymd}*)
                    printf "    ${G3}▪${CLR_RESET} %-23s: %b\n" "backup Full de hoje" "$formatted_status"
                    ;;
                *)
                    printf "    ${G3}▪${CLR_RESET} %-23s: ${CLR_YELLOW}Ainda não rodou${CLR_RESET}\n" "backup Full de hoje"
                    ;;
            esac
        else
            printf "    ${G3}▪${CLR_RESET} %-23s: ${CLR_YELLOW}Nenhum arquivo encontrado${CLR_RESET}\n" "backup Full"
            printf "    ${G3}▪${CLR_RESET} %-23s: ${CLR_YELLOW}Ainda não rodou${CLR_RESET}\n" "backup Full de hoje"
        fi

        # 2. Análise do Backup Incremental de hoje (diretamente colado)
        latest_inc=$(find_latest_file_by_pattern "$backup_dir" "IncrementalDBList")

        if [ -n "$latest_inc" ]; then
            inc_fname=$(basename "$latest_inc")
            case "$inc_fname" in
                *${today_ymd}*)
                    inc_status=$(analyze_backup_file "$latest_inc")
                    formatted_inc_status=$(format_backup_status "$inc_status")
                    printf "    ${G5}▪${CLR_RESET} %-23s: %b\n" "Backup Incremental hoje" "$formatted_inc_status"
                    ;;
                *)
                    printf "    ${G5}▪${CLR_RESET} %-23s: ${CLR_YELLOW}Ainda não rodou hoje${CLR_RESET}\n" "Backup Incremental hoje"
                    ;;
            esac
        else
            printf "    ${G5}▪${CLR_RESET} %-23s: ${CLR_YELLOW}Nenhum log incremental encontrado${CLR_RESET}\n" "Backup Incremental hoje"
        fi

        printf "\n"
    done < "$INSTANCES_FILE"

    printf "${CLR_GRAY}──────────────────────────────────────────────────────────────────────────────${CLR_RESET}\n\n"
}

main() {
    collect_instances
    render_compact
}

main "$@"
