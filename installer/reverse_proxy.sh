#!/bin/bash

# Reverse proxy detection and configuration helpers.

reverse_proxy_detect() {
    if command_exists nginx; then
        echo "nginx"
    elif command_exists caddy; then
        echo "caddy"
    else
        echo "none"
    fi
}

install_caddy() {
    if command_exists caddy; then
        print_info "$(msg CADDY_INSTALLED)"
        return 0
    fi

    print_info "$(msg INSTALLING_CADDY)"

    case "$OS" in
        debian|ubuntu)
            apt-get update -qq
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
            apt-get update -qq
            apt-get install -y caddy
            ;;
        rhel|centos|fedora)
            if command_exists dnf; then
                dnf install -y 'dnf-command(copr)'
                dnf copr enable -y @caddy/caddy
                dnf install -y caddy
            else
                yum install -y yum-plugin-copr
                yum copr enable -y @caddy/caddy
                yum install -y caddy
            fi
            ;;
        *)
            print_info "$(msg INSTALLING_CADDY_SCRIPT)"
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh' | bash
            if command_exists dnf; then
                dnf install -y caddy
            else
                yum install -y caddy
            fi
            ;;
    esac

    if ! command_exists caddy; then
        print_error "$(msg CADDY_INSTALL_FAILED)"
        return 1
    fi

    print_info "$(msg CADDY_INSTALLED_SUCCESS)"
}

setup_caddy_https() {
    local domain="$1"
    local http_port="$2"
    local web_prefix="$3"
    configure_caddy "$domain" "$http_port" "$web_prefix" "https"
}

setup_caddy_http() {
    local host="$1"
    local http_port="$2"
    local web_prefix="$3"
    configure_caddy "$host" "$http_port" "$web_prefix" "http"
}

write_nginx_proxy_conf() {
    local domain="$1"
    local app_port="$2"
    local web_prefix="$3"
    local nginx_conf="/etc/nginx/conf.d/wg-obf-easy.conf"
    local server_name_block

    if [[ -n "$domain" ]]; then
        server_name_block="$domain"
    else
        server_name_block="_"
    fi

    print_info "$(msg NGINX_SETUP "$server_name_block")"
    print_info "$(msg NGINX_CONFIG_PATH "$nginx_conf")"

    cat >"$nginx_conf" <<EOF
server {
    listen 80;
    server_name $server_name_block;

    location $web_prefix {
        proxy_pass http://127.0.0.1:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    if ! nginx -t >/dev/null 2>&1; then
        print_error "$(msg NGINX_TEST_FAILED)"
        return 1
    fi

    if command_exists systemctl; then
        if ! systemctl reload nginx >/dev/null 2>&1; then
            print_error "$(msg NGINX_RELOAD_FAILED)"
            return 1
        fi
    else
        if ! nginx -s reload >/dev/null 2>&1; then
            print_error "$(msg NGINX_RELOAD_FAILED)"
            return 1
        fi
    fi

    print_info "$(msg NGINX_RELOADED)"
    return 0
}

setup_nginx_http() {
    local host="$1"
    local app_port="$2"
    local web_prefix="$3"
    write_nginx_proxy_conf "$host" "$app_port" "$web_prefix"
}

setup_nginx_https() {
    local domain="$1"
    local app_port="$2"
    local web_prefix="$3"

    write_nginx_proxy_conf "$domain" "$app_port" "$web_prefix" || return 1

    if ! command_exists certbot; then
        print_warning "$(msg NGINX_CERTBOT_MISSING)"
        return 0
    fi

    print_info "$(msg NGINX_CERTBOT_START)"
    if [[ -n "$ACME_EMAIL" ]]; then
        if certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$ACME_EMAIL" >/dev/null 2>&1; then
            print_info "$(msg NGINX_CERTBOT_SUCCESS)"
        else
            print_warning "$(msg NGINX_CERTBOT_FAILED)"
        fi
    else
        if certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email >/dev/null 2>&1; then
            print_info "$(msg NGINX_CERTBOT_SUCCESS)"
        else
            print_warning "$(msg NGINX_CERTBOT_FAILED)"
        fi
    fi
}

suggest_caddy_install() {
    local os="$1"
    print_warning "$(msg PROXY_SUGGEST_CADDY)"
    case "$os" in
        debian|ubuntu)
            print_info "$(msg PROXY_SUGGEST_CADDY_DEBIAN)"
            ;;
        rhel|centos|fedora)
            print_info "$(msg PROXY_SUGGEST_CADDY_RHEL)"
            ;;
        alpine)
            print_info "$(msg PROXY_SUGGEST_CADDY_ALPINE)"
            ;;
        *)
            print_info "$(msg PROXY_SUGGEST_CADDY_GENERIC)"
            ;;
    esac
}

configure_caddy() {
    local domain_or_host="$1"
    local http_port="$2"
    local web_prefix="${3:-/}"
    local mode="${4:-https}"
    local caddyfile="/etc/caddy/Caddyfile"
    local site_label

    if [[ "$mode" == "https" ]]; then
        if [[ -z "$domain_or_host" ]]; then
            print_error "$(msg DOMAIN_REQUIRED)"
            return 1
        fi
        site_label="$domain_or_host"
    else
        if [[ -z "$domain_or_host" ]]; then
            site_label=":80"
        else
            site_label="$domain_or_host"
            if [[ "$site_label" != http://* && "$site_label" != https://* && "$site_label" != :* ]]; then
                site_label="http://${site_label}"
            fi
        fi
        print_info "$(msg CADDY_CONFIGURING "$site_label")"
    fi

    print_info "$(msg CADDY_TARGET_PORT "$http_port" "$web_prefix")"

    if [[ -f "$caddyfile" ]]; then
        print_info "$(msg CADDY_BACKUP "${caddyfile}.backup")"
        cp "$caddyfile" "${caddyfile}.backup"
    fi

    if [[ "$mode" == "https" ]]; then
        print_info "$(msg CADDY_DOMAIN_SETUP)"
        if [[ -n "$ACME_EMAIL" && "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            cat >"$caddyfile" <<EOF
{
    email $ACME_EMAIL
}

$site_label {
    reverse_proxy 127.0.0.1:$http_port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
    }

    log {
        output file /var/log/caddy/access.log
    }
}
EOF
        else
            cat >"$caddyfile" <<EOF
$site_label {
    reverse_proxy 127.0.0.1:$http_port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
    }

    log {
        output file /var/log/caddy/access.log
    }
}
EOF
        fi
    else
        cat >"$caddyfile" <<EOF
$site_label {
    reverse_proxy 127.0.0.1:$http_port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
    }

    log {
        output file /var/log/caddy/access.log
    }
}
EOF
    fi

    mkdir -p /var/log/caddy
    if command_exists chown; then
        if id caddy >/dev/null 2>&1; then
            rm -f /var/log/caddy/access.log 2>/dev/null || true
            chown -R caddy:caddy /var/log/caddy 2>/dev/null || true
            touch /var/log/caddy/access.log
            chown caddy:caddy /var/log/caddy/access.log 2>/dev/null || true
            chmod 644 /var/log/caddy/access.log 2>/dev/null || true
        fi
        chmod 755 /var/log/caddy
    fi

    if caddy validate --config "$caddyfile" >/dev/null 2>&1; then
        print_info "$(msg CADDY_CONFIG_VALID)"
    else
        print_warning "$(msg CADDY_VALIDATION_FAILED)"
    fi

    if command_exists systemctl; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            print_info "$(msg CADDY_RELOADING)"
            if timeout 10 systemctl reload caddy 2>/dev/null; then
                print_info "$(msg CADDY_RELOADED)"
            else
                print_warning "$(msg CADDY_RELOAD_FAILED)"
                systemctl restart caddy
            fi
        else
            print_info "$(msg CADDY_STARTING)"
            systemctl enable caddy 2>/dev/null || true
            systemctl start caddy
        fi
    else
        print_warning "$(msg CADDY_NO_SYSTEMCTL)"
        caddy run --config "$caddyfile" &
    fi

    if [[ "$mode" == "https" ]]; then
        print_info "$(msg CADDY_WAIT_SSL)"
    else
        print_info "$(msg CADDY_WAIT_START)"
    fi
    sleep 5

    local max_attempts=6
    local attempt=0
    while (( attempt < max_attempts )); do
        if command_exists systemctl; then
            if systemctl is-active --quiet caddy 2>/dev/null; then
                print_info "$(msg CADDY_RUNNING)"
                return 0
            fi
        else
            if pgrep -x caddy >/dev/null 2>&1; then
                print_info "$(msg CADDY_RUNNING)"
                return 0
            fi
        fi
        sleep 5
        attempt=$((attempt + 1))
    done

    if command_exists systemctl; then
        print_warning "$(msg CADDY_NOT_RUNNING_SYSTEMCTL)"
    else
        print_warning "$(msg CADDY_NOT_RUNNING)"
    fi
    return 1
}
