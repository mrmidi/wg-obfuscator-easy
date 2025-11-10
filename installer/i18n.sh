#!/bin/bash

# Internationalization loader. Exposes load_lang_strings and msg helpers.

: "${HELPER_DIR:=installer}"
: "${LANG_CHOICE:=en}"
LANG_DIR="${HELPER_DIR}/i18n"
declare -A MSG

load_lang_strings() {
    local lang_choice="${1:-$LANG_CHOICE}"
    local lang_file="${LANG_DIR}/${lang_choice}.txt"
    if [[ ! -f "$lang_file" ]]; then
        echo "Language file not found: $lang_file" >&2
        return 1
    fi

    MSG=()
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        MSG["$key"]="$value"
    done < "$lang_file"
    LANG_CHOICE="$lang_choice"
}

msg() {
    local key="$1"
    shift || true
    local template="${MSG[$key]}"
    if [[ -z "$template" ]]; then
        template="$key"
    fi

    if [[ $# -gt 0 ]]; then
        printf "$template" "$@"
    else
        echo "$template"
    fi
}
