#!/bin/bash

# Helpers for generating random configuration pieces and persisting install data.

generate_password() {
    openssl rand -base64 16 | tr -d '=+/' | cut -c1-16
}

generate_prefix() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 8 | head -n 1
}

generate_port() {
    local port
    while true; do
        port=$((RANDOM % 64511 + 1024))
        if [[ "$port" -ne 65535 && "$port" -ge 1024 ]]; then
            echo "$port"
            return
        fi
    done
}

check_port() {
    local port="$1"
    if command_exists ss; then
        ss -tuln 2>/dev/null | grep -q ":$port " && return 0 || return 1
    elif command_exists netstat; then
        netstat -tuln 2>/dev/null | grep -q ":$port " && return 0 || return 1
    elif command_exists timeout && command_exists nc; then
        if timeout 1 nc -l -p "$port" >/dev/null 2>&1; then
            return 1
        else
            return 0
        fi
    else
        return 1
    fi
}

save_install_config() {
    local config_file="$1"
    local domain="$2"
    local enable_https="$3"
    local http_port="$4"
    local web_prefix="$5"
    local wireguard_port="$6"
    local acme_email="$7"

    cat >"$config_file" <<EOF
DOMAIN="$domain"
ENABLE_HTTPS="$enable_https"
HTTP_PORT="$http_port"
WEB_PREFIX="$web_prefix"
WIREGUARD_PORT="$wireguard_port"
ACME_EMAIL="$acme_email"
EOF
}
