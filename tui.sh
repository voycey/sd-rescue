# ---------------------------------------------------------------------------
# Self-contained terminal UI. No dependencies beyond bash and ANSI escapes.
# Sourced by sdrescue.
# ---------------------------------------------------------------------------

UI_W=58                                   # inner width of the boxes

ui_supports_unicode() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) return 0;; esac
    return 1
}
if ui_supports_unicode; then
    B_TL='┌'; B_TR='┐'; B_BL='└'; B_BR='┘'; B_H='─'; B_V='│'
    G_OK='✓'; G_BAD='✗'; G_WARN='!'; G_CUR='❯'; G_DOT='●'
else
    B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'
    G_OK='+'; G_BAD='x'; G_WARN='!'; G_CUR='>'; G_DOT='*'
fi

# Visible length, ignoring ANSI colour codes.
ui_len() { local s="$1"; s=$(sed $'s/\033\\[[0-9;]*m//g' <<<"$s"); printf '%s' "${#s}"; }

ui_rep() { local n="$1" c="$2" o=""; while [ "$n" -gt 0 ]; do o="$o$c"; n=$((n-1)); done; printf '%s' "$o"; }

ui_box_top() {
    local title="$1" bar
    bar=$(ui_rep $((UI_W - ${#title} - 3)) "$B_H")
    printf '%s%s%s %s %s%s\n' "$c_blu" "$B_TL$B_H" "$c_off" "$c_bld$title$c_off" "$c_blu$bar" "$B_TR$c_off"
}
ui_box_line() {
    local text="$1" pad
    pad=$(( UI_W - 2 - $(ui_len "$text") ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%s%s %s%s %s%s%s\n' "$c_blu" "$B_V" "$c_off" "$text" "$(ui_rep "$pad" ' ')" "$c_blu" "$B_V" "$c_off"
}
ui_box_bot() { printf '%s%s%s%s\n' "$c_blu" "$B_BL" "$(ui_rep "$UI_W" "$B_H")" "$B_BR$c_off"; }

ui_rule() { printf '  %s%s%s\n' "$c_dim" "$(ui_rep "$UI_W" "$B_H")" "$c_off"; }

# Human-readable byte counts.
ui_bytes() {
    local b="${1:-}"
    [ -z "$b" ] && { printf -- '-'; return; }
    awk -v b="$b" 'BEGIN{
        split("B K M G T",u," ");
        i=1; while (b>=1024 && i<5){b/=1024;i++}
        printf (i==1 ? "%d%s" : "%.1f%s"), b, u[i]
    }'
}

ui_state_glyph() {
    case "$1" in
        clean)      printf '%s%s clean%s'            "$c_grn" "$G_OK"  "$c_off" ;;
        dirty)      printf '%s%s needs repair%s'     "$c_yel" "$G_BAD" "$c_off" ;;
        errors)     printf '%s%s errors%s'           "$c_red" "$G_BAD" "$c_off" ;;
        damaged)    printf '%s%s superblock damaged%s' "$c_red" "$G_BAD" "$c_off" ;;
        unreadable) printf '%s%s unreadable%s'       "$c_red" "$G_BAD" "$c_off" ;;
        *)          printf '%s%s unknown%s'          "$c_dim" "$G_WARN" "$c_off" ;;
    esac
}

# --------------------------------------------------------------- the menu ----
# ui_menu "prompt" "key|label|hint" ... -> echoes the chosen key
# Arrow keys or j/k to move, Enter to pick, q to quit, or press 1..n directly.
ui_menu() {
    local prompt="$1"; shift
    local items=("$@") n=${#items[@]} cur=0 i key rest
    local first=1 label hint

    # Everything the user sees goes to stderr: stdout carries only the chosen
    # key, because the caller reads this through $( ).
    while :; do
        if [ "$first" = 1 ]; then first=0; else printf '\033[%dA' $((n + 2)) >&2; fi
        printf '  %s%s%s\n\n' "$c_bld" "$prompt" "$c_off" >&2
        for i in $(seq 0 $((n-1))); do
            label="${items[$i]#*|}"; hint="${label#*|}"; label="${label%%|*}"
            printf '\033[2K' >&2
            if [ "$i" = "$cur" ]; then
                printf '  %s%s %-16s%s %s%s%s\n' "$c_grn" "$G_CUR" "$label" "$c_off" "$c_dim" "$hint" "$c_off" >&2
            else
                printf '    %-16s %s%s%s\n' "$label" "$c_dim" "$hint" "$c_off" >&2
            fi
        done

        IFS= read -rsn1 key || { printf '\n' >&2; return 1; }
        case "$key" in
            $'\033')
                read -rsn2 -t 0.05 rest || rest=""
                case "$rest" in
                    '[A') cur=$(( (cur - 1 + n) % n )) ;;
                    '[B') cur=$(( (cur + 1) % n )) ;;
                esac ;;
            k) cur=$(( (cur - 1 + n) % n )) ;;
            j) cur=$(( (cur + 1) % n )) ;;
            [1-9]) [ "$key" -le "$n" ] && cur=$((key - 1)) ;;
            q|Q) printf '\n' >&2; printf '%s\n' "${items[$((n-1))]%%|*}"; return 0 ;;
            ''|$'\n'|$'\r')
                printf '\n' >&2
                printf '%s\n' "${items[$cur]%%|*}"
                return 0 ;;
        esac
    done
}
