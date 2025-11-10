#!/bin/bash
#
# WireGuard Obfuscator Easy - Installation Script (refactored)
#
# This script installs and configures WireGuard Obfuscator Easy on a VPS.

# stricter error handling
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="${SCRIPT_DIR}/installer"
LANG_CHOICE="${LANG_CHOICE:-en}"

# Default helper source: upstream ClusterM repo (override via REPO_RAW_BASE if needed)
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ClusterM/wg-obfuscator-easy/master/installer}"

WG_CONTAINER_STARTED=false
CADDY_PREVIOUSLY_ACTIVE=false
ACME_EMAIL="${ACME_EMAIL:-}"
DOMAIN="${DOMAIN:-}"
HTTP_PORT="${HTTP_PORT:-}"
WIREGUARD_PORT="${WIREGUARD_PORT:-}"
WEB_PREFIX="${WEB_PREFIX:-}"
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

cleanup() {
    local exit_code=$?
    trap - EXIT

    local container_name="${CONTAINER_NAME:-}"

    if [[ $exit_code -ne 0 ]]; then
        if [[ "$WG_CONTAINER_STARTED" == true && -n "$container_name" ]] && command_exists docker; then
            docker stop "$container_name" >/dev/null 2>&1 || true
            docker rm "$container_name" >/dev/null 2>&1 || true
        fi

        if [[ "$CADDY_PREVIOUSLY_ACTIVE" == true ]] && command_exists systemctl; then
            systemctl start caddy >/dev/null 2>&1 || true
        fi
    fi
}

handle_error() {
    local status=$?
    local line=${1:-0}
    if declare -F msg >/dev/null 2>&1; then
        print_error "$(msg INSTALL_FAILED "$line")"
    else
        print_error "Installation failed at line $line."
    fi
    exit $status
}

handle_interrupt() {
    if declare -F msg >/dev/null 2>&1; then
        print_error "$(msg INSTALL_FAILED "$LINENO")"
    else
        print_error "Installation interrupted at line $LINENO."
    fi
    exit 1
}

trap cleanup EXIT
trap 'handle_error ${LINENO}' ERR
trap handle_interrupt INT TERM

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} ${WHITE}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} ${WHITE}$1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} ${WHITE}$1${NC}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

download_helper() {
    local relative_path="$1"
    local destination="${HELPER_DIR}/${relative_path}"
    local url="${REPO_RAW_BASE}/${relative_path}"

    mkdir -p "$(dirname "$destination")"

    if [[ -f "$destination" ]]; then
        return 0
    fi

    if command_exists curl; then
        curl -fsSL "$url" -o "$destination"
    elif command_exists wget; then
        wget -q -O "$destination" "$url"
    else
        echo "Unable to download helper file: $relative_path (curl or wget required)" >&2
        return 1
    fi

    if [[ "$relative_path" == *.sh ]]; then
        chmod +x "$destination"
    fi
}

ensure_helpers() {
    local helper_files=(
        "i18n.sh"
        "os_install.sh"
        "firewall.sh"
        "reverse_proxy.sh"
        "container.sh"
        "config_generate.sh"
    )

    mkdir -p "${HELPER_DIR}/i18n"

    for helper in "${helper_files[@]}"; do
        if [[ ! -f "${HELPER_DIR}/${helper}" ]]; then
            echo "Downloading ${helper}..."
            download_helper "$helper" || exit 1
        fi
    done

    for lang_file in i18n/en.txt i18n/ru.txt; do
        if [[ ! -f "${HELPER_DIR}/${lang_file}" ]]; then
            echo "Downloading ${lang_file}..."
            download_helper "$lang_file" || exit 1
        fi
    done
}

ensure_helpers

# shellcheck disable=SC1091
source "${HELPER_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${HELPER_DIR}/os_install.sh"
# shellcheck disable=SC1091
source "${HELPER_DIR}/firewall.sh"
# shellcheck disable=SC1091
source "${HELPER_DIR}/reverse_proxy.sh"
# shellcheck disable=SC1091
source "${HELPER_DIR}/container.sh"
# shellcheck disable=SC1091
source "${HELPER_DIR}/config_generate.sh"

if ! load_lang_strings "$LANG_CHOICE"; then
    echo "Falling back to English language pack" >&2
    LANG_CHOICE="en"
    load_lang_strings "en"
fi

get_external_ip() {
    local ip
    for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "api.ipify.org"; do
        ip=$( { curl -s --max-time 5 "https://$service" 2>/dev/null || curl -s --max-time 5 "http://$service" 2>/dev/null || true; } )
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

resolve_domain_ipv4() {
    local domain="$1"
    local ip

    if command_exists dig; then
        ip=$( { dig +short A "$domain" 2>/dev/null || true; } | awk '/^[0-9.]+$/ { print $1; exit }' )
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    if command_exists getent; then
        ip=$( { getent ahostsv4 "$domain" 2>/dev/null || true; } | awk '/^[0-9.]+/ { print $1; exit }' )
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        ip=$( { getent hosts "$domain" 2>/dev/null || true; } | awk '/^[0-9.]+/ { print $1; exit }' )
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    if command_exists nslookup; then
        ip=$( { nslookup "$domain" 2>/dev/null || true; } | awk '/^Address:[[:space:]]+[0-9.]+$/ { print $2; exit }' )
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    if command_exists host; then
        ip=$( { host "$domain" 2>/dev/null || true; } | awk '/ has address / { print $4; exit }' )
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    return 1
}

main() {
    if ! [ -t 0 ]; then
        print_error "$(msg SCRIPT_REQUIRES_INTERACTIVE)"
        print_error "$(msg SCRIPT_REQUIRES_INTERACTIVE2)"
        print_error "$(msg SCRIPT_REQUIRES_INTERACTIVE)"
        echo ""
        print_error "$(msg SCRIPT_REQUIRES_INTERACTIVE3)"
        echo ""
        print_info "$(msg SCRIPT_DOWNLOAD_DIRECT)"
        echo ""
        print_info "  curl -Ls https://raw.githubusercontent.com/ClusterM/wg-obfuscator-easy/master/install.sh -o install.sh"
        print_info "  bash install.sh"
        echo ""
        print_info "$(msg SCRIPT_OR_WGET)"
        print_info "  wget https://raw.githubusercontent.com/ClusterM/wg-obfuscator-easy/master/install.sh -O install.sh"
        print_info "  bash install.sh"
        echo ""
        exit 1
    fi

    if [[ -n "${WG_OBF_LANG:-}" ]]; then
        LANG_CHOICE="$WG_OBF_LANG"
        load_lang_strings "$LANG_CHOICE"
    fi

    echo ""
    echo "$(msg SELECT_LANG_TITLE)"
    echo "  1) $(msg LANG_EN) (default)"
    echo "  2) $(msg LANG_RU)"
    echo ""
    read -p "$(msg SELECT_LANG): " -r lang_choice
    if [[ -z "$lang_choice" ]]; then
        lang_choice=1
    fi
    case "$lang_choice" in
        2)
            LANG_CHOICE="ru"
            ;;
        *)
            LANG_CHOICE="en"
            ;;
    esac
    load_lang_strings "$LANG_CHOICE"
    echo ""

    print_info "$(msg SCRIPT_TITLE)"
    print_info "$(msg SCRIPT_TITLE2)"
    print_info "$(msg SCRIPT_TITLE)"
    echo ""
    print_info "$(msg SCRIPT_GUIDE)"
    print_info "$(msg SCRIPT_QUESTIONS)"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        if command_exists sudo; then
            print_warning "$(msg SCRIPT_REQUIRES_ROOT)"
            exec sudo WG_OBF_LANG="$LANG_CHOICE" bash "$0" "$@"
        else
            print_error "$(msg SCRIPT_REQUIRES_ROOT2)"
            echo ""
            print_info "$(msg SCRIPT_RUN_AS_ROOT)"
            print_info "  sudo bash install.sh"
            echo ""
            exit 1
        fi
    fi

    TAG="latest"
    if [[ -n "${1-}" ]]; then
        TAG="$1"
    fi
    IMAGE_NAME="docker.io/clustermeerkat/wg-obf-easy:$TAG"
    CONTAINER_NAME="wg-obf-easy"
    CONFIG_DIR="/root/.wg-obf-easy"
    CONFIG_FILE="${CONFIG_DIR}/install_config.json"

    firewall_init_state

    CONFIG_EXISTS=false
    KEEP_OLD_HOST_CONFIG=false
    OLD_APP_VERSION=""
    NEW_PASSWORD=false
    ADMIN_PASSWORD="$(generate_password)"

    if [[ -f "$CONFIG_FILE" ]]; then
        OLD_APP_VERSION="$(get_app_version "$CONTAINER_NAME" 2>/dev/null || echo "")"
        CONFIG_EXISTS=true
        while true; do
            read -p "$(msg OLD_CONFIG_FOUND)" -r
            if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
                # shellcheck disable=SC1090
                source "$CONFIG_FILE"
                KEEP_OLD_HOST_CONFIG=true
                break
            elif [[ "$REPLY" =~ ^[Nn]$ ]]; then
                break
            fi
        done

        while true; do
            read -p "$(msg RESET_PASSWORD_PROMPT)" -r
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                echo ""
                if reset_admin_credentials "$CONTAINER_NAME" "$ADMIN_PASSWORD"; then
                    NEW_PASSWORD=true
                    print_info "$(msg ADMIN_RESET_SUCCESS)"
                    print_info "$(msg TOKENS_DELETED)"
                    break
                else
                    print_error "$(msg ADMIN_RESET_FAILED)"
                    read -p "$(msg PRESS_ENTER)" || true
                fi
            elif [[ -z "$REPLY" || "$REPLY" =~ ^[Nn]$ ]]; then
                echo ""
                ADMIN_PASSWORD=""
                break
            fi
        done
    fi

    if [[ "$KEEP_OLD_HOST_CONFIG" == false ]]; then
        WEB_PREFIX="/$(generate_prefix)/"
    fi

    detect_os
    print_info "$(msg DETECTED_OS "$OS")"

    detect_firewall_backend
    if [[ "$FIREWALL_BACKEND" != "none" ]]; then
        if [[ "$FIREWALL_BACKEND_STATE" == "active" ]]; then
            print_info "$(msg DETECTED_FIREWALL "$FIREWALL_BACKEND")"
        else
            print_warning "$(msg FIREWALL_INACTIVE "$FIREWALL_BACKEND")"
        fi
    else
        print_info "$(msg NO_FIREWALL)"
    fi

    print_info "$(msg INSTALLING_PACKAGES)"

    if ! command_exists systemctl; then
        install_systemd
        if ! command_exists systemctl; then
            print_error "$(msg SYSTEMCTL_NOT_INSTALLED)"
            exit 1
        fi
    fi

    if ! command_exists curl; then
        install_curl
    fi

    install_docker

    if ! docker info >/dev/null 2>&1; then
        print_error "$(msg DOCKER_NOT_RUNNING)"
        if command_exists systemctl; then
            print_info "$(msg SYSTEMCTL_TRY)"
        fi
        exit 1
    fi

    print_info "$(msg DETECTING_IP)"
    EXTERNAL_IP="$(get_external_ip || true)"
    if [[ -z "$EXTERNAL_IP" ]]; then
        print_error "$(msg IP_DETECT_FAILED)"
        exit 1
    fi
    print_info "$(msg EXTERNAL_IP "$EXTERNAL_IP")"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if command_exists systemctl; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            CADDY_PREVIOUSLY_ACTIVE=true
            systemctl stop caddy >/dev/null 2>&1 || true
        else
            CADDY_PREVIOUSLY_ACTIVE=false
        fi
    fi

    if [[ "$KEEP_OLD_HOST_CONFIG" == false ]]; then
        HTTP_PORT="$(generate_port)"
        local max_port_attempts=10
        local port_attempt=0
        while check_port "$HTTP_PORT"; do
            if (( port_attempt >= max_port_attempts )); then
                print_error "Failed to find available HTTP port after $max_port_attempts attempts"
                exit 1
            fi
            HTTP_PORT="$(generate_port)"
            port_attempt=$((port_attempt + 1))
        done

        WIREGUARD_PORT="$(generate_port)"
        port_attempt=0
        while check_port "$WIREGUARD_PORT"; do
            if (( port_attempt >= max_port_attempts )); then
                print_error "Failed to find available WireGuard port after $max_port_attempts attempts"
                exit 1
            fi
            WIREGUARD_PORT="$(generate_port)"
            port_attempt=$((port_attempt + 1))
        done
    fi

    mkdir -p "$CONFIG_DIR"
    print_info "$(msg CONFIG_DIR "$CONFIG_DIR")"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    pull_container_image "$IMAGE_NAME"

    start_wg_container "$IMAGE_NAME" "$CONTAINER_NAME" "$CONFIG_DIR" "$WEB_PREFIX" "$EXTERNAL_IP" "$WIREGUARD_PORT" "$ADMIN_PASSWORD" "$HTTP_PORT"
    WG_CONTAINER_STARTED=true

    wait_for_container "$CONTAINER_NAME"
    wait_for_app "$HTTP_PORT" "$WEB_PREFIX" || true

    print_info "$(msg GETTING_VERSION)"
    APP_VERSION="$(get_app_version "$CONTAINER_NAME")"
    if [[ "$APP_VERSION" != "unknown" && -n "$OLD_APP_VERSION" ]]; then
        print_info "$(msg INSTALLED_VERSION_OLD "$OLD_APP_VERSION")"
    fi
    if [[ "$APP_VERSION" != "unknown" ]]; then
        print_info "$(msg APP_VERSION "$APP_VERSION")"
    else
        print_warning "$(msg VERSION_UNKNOWN)"
        APP_VERSION=""
    fi

    if [[ "$KEEP_OLD_HOST_CONFIG" == false ]]; then
        echo ""
        while true; do
            read -p "$(msg ENABLE_HTTPS_PROMPT)" -r
            if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
                ENABLE_HTTPS=true
                break
            elif [[ "$REPLY" =~ ^[Nn]$ ]]; then
                ENABLE_HTTPS=false
                break
            fi
        done

        if [[ "$ENABLE_HTTPS" == true ]]; then
            while true; do
                read -p "$(msg NEED_GUIDE_DYNU)" -r
                if [[ "$REPLY" =~ ^[Qq]$ ]]; then
                    ENABLE_HTTPS=false
                    break
                elif [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
                    echo ""
                    print_info "$(msg DYNU_GUIDE_INTRO)"
                    print_info "$(msg DYNU_YOUR_IP "$EXTERNAL_IP")"
                    echo ""
                    print_info "$(msg DYNU_STEPS)"
                    echo ""
                    print_info "$(msg DYNU_STEP0)"
                    print_info "$(msg DYNU_STEP1)"
                    print_info "$(msg DYNU_STEP2)"
                    print_info "$(msg DYNU_STEP3)"
                    print_info "$(msg DYNU_STEP4)"
                    print_info "$(msg DYNU_STEP5)"
                    print_info "$(msg DYNU_STEP6)"
                    print_info "$(msg DYNU_STEP7)"
                    print_info "$(msg DYNU_STEP8 "$EXTERNAL_IP")"
                    print_info "$(msg DYNU_STEP9)"
                    print_info "$(msg DYNU_STEP10)"
                    echo ""
                    break
                elif [[ "$REPLY" =~ ^[Nn]$ ]]; then
                    break
                fi
            done
        fi

        DOMAIN=""
        if [[ "$ENABLE_HTTPS" == true ]]; then
            while true; do
                read -p "$(msg ENTER_DOMAIN)" -r
                if [[ "$REPLY" =~ ^[Qq]$ ]]; then
                    ENABLE_HTTPS=false
                    break
                fi
                DOMAIN="$REPLY"
                if [[ -z "$DOMAIN" ]]; then
                    print_error "$(msg DOMAIN_EMPTY)"
                    echo ""
                    continue
                fi
                if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9\.-]+\.[a-zA-Z]{2,}$'; then
                    print_error "$(msg DOMAIN_INVALID)"
                    echo ""
                    continue
                fi
                break
            done
        fi
        echo ""
    fi

    DNS_RESOLVED=false
    if [[ "$ENABLE_HTTPS" == true ]]; then
        print_info "$(msg CHECKING_DNS "$DOMAIN" "$EXTERNAL_IP")"
        sleep 5
        local max_dns_checks=12
        local dns_check=0
        while (( dns_check < max_dns_checks )); do
            local resolved_ip="$(resolve_domain_ipv4 "$DOMAIN")"

            if [[ "$resolved_ip" == "$EXTERNAL_IP" ]]; then
                DNS_RESOLVED=true
                print_info "$(msg DNS_CONFIGURED "$DOMAIN" "$EXTERNAL_IP")"
                break
            fi

            print_info "$(msg DNS_WAITING "$((dns_check + 1))" "$max_dns_checks")"
            sleep 10
            dns_check=$((dns_check + 1))
        done

        if [[ "$DNS_RESOLVED" == false ]]; then
            print_warning "$(msg DNS_VERIFY_FAILED)"
            print_warning "$(msg DNS_DYNU_NOTE)"
            print_warning "$(msg DNS_PROPAGATION_NOTE)"
            print_info "$(msg CONTINUE_WITHOUT_HTTPS)"
            ENABLE_HTTPS=false
        elif [[ "$KEEP_OLD_HOST_CONFIG" == false ]]; then
            print_info "$(msg SSL_SETUP)"
            print_info "$(msg SSL_LETSENCRYPT)"
            print_info "$(msg SSL_EMAIL_INFO)"
            print_info "$(msg SSL_EMAIL_INFO2)"
            print_info "$(msg SSL_EMAIL_OPTIONAL)"
            echo ""
            while true; do
                read -p "$(msg EMAIL_PROMPT)" -r
                if [[ -z "$REPLY" ]]; then
                    echo ""
                    ACME_EMAIL=""
                    print_info "$(msg EMAIL_SKIPPED)"
                    break
                elif echo "$REPLY" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                    echo ""
                    ACME_EMAIL="$REPLY"
                    print_info "$(msg EMAIL_SET "$ACME_EMAIL")"
                    print_info "$(msg EMAIL_NOTIFICATIONS)"
                    break
                else
                    echo ""
                    print_error "$(msg EMAIL_INVALID)"
                    print_error "$(msg EMAIL_INVALID_FORMAT)"
                    print_error "$(msg EMAIL_SKIP_NOTE)"
                fi
            done
        fi
    fi

    open_firewall_port "$WIREGUARD_PORT" "udp"
    open_firewall_port "80" "tcp"
    open_firewall_port "443" "tcp"

    HTTP_PORT_REAL="$HTTP_PORT"
    local proxy_detected="none"
    local selected_proxy="none"

    if [[ "$ENABLE_HTTPS" == true ]]; then
        proxy_detected="$(reverse_proxy_detect)"
        case "$proxy_detected" in
            nginx)
                print_info "$(msg PROXY_DETECTED_NGINX)"
                read -p "$(msg PROXY_USE_NGINX_PROMPT)" -r
                if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
                    if setup_nginx_https "$DOMAIN" "$HTTP_PORT_REAL" "$WEB_PREFIX"; then
                        selected_proxy="nginx"
                        HTTP_PORT=80
                    else
                        print_warning "$(msg PROXY_NGINX_FAILED)"
                    fi
                fi
                ;;
            caddy)
                print_info "$(msg PROXY_DETECTED_CADDY)"
                if setup_caddy_https "$DOMAIN" "$HTTP_PORT_REAL" "$WEB_PREFIX"; then
                    selected_proxy="caddy"
                else
                    print_warning "$(msg HTTPS_FAILED)"
                    ENABLE_HTTPS=false
                fi
                ;;
            *)
                print_warning "$(msg PROXY_NONE_FOUND)"
                suggest_caddy_install "$OS"
                print_warning "$(msg CONTINUE_WITHOUT_HTTPS)"
                ENABLE_HTTPS=false
                ;;
        esac

        if [[ "$ENABLE_HTTPS" == true && "$selected_proxy" == "none" ]]; then
            install_caddy
            if setup_caddy_https "$DOMAIN" "$HTTP_PORT_REAL" "$WEB_PREFIX"; then
                selected_proxy="caddy"
            else
                print_warning "$(msg HTTPS_FAILED)"
                systemctl stop caddy 2>/dev/null || true
                systemctl disable caddy 2>/dev/null || true
                ENABLE_HTTPS=false
            fi
        fi
    fi

    if [[ "$ENABLE_HTTPS" == false ]]; then
        proxy_detected="$(reverse_proxy_detect)"
        if [[ "$proxy_detected" == "nginx" ]]; then
            if setup_nginx_http "$DOMAIN" "$HTTP_PORT_REAL" "$WEB_PREFIX"; then
                print_info "$(msg PROXY_HTTP_NGINX)"
                selected_proxy="nginx"
                HTTP_PORT=80
            else
                print_warning "$(msg PROXY_NGINX_HTTP_FAILED)"
            fi
        else
            install_caddy
            if ! check_port "80"; then
                print_info "$(msg HTTP_PROXY_SETUP)"
                local http_proxy_host="$DOMAIN"
                if [[ -z "$http_proxy_host" ]]; then
                    http_proxy_host=":80"
                fi
                if setup_caddy_http "$http_proxy_host" "$HTTP_PORT_REAL" "$WEB_PREFIX"; then
                    print_info "$(msg HTTP_PROXY_SUCCESS)"
                    selected_proxy="caddy"
                    HTTP_PORT=80
                else
                    print_warning "$(msg HTTP_PROXY_FAILED "$HTTP_PORT_REAL")"
                    open_firewall_port "$HTTP_PORT_REAL" "tcp"
                    systemctl stop caddy 2>/dev/null || true
                    systemctl disable caddy 2>/dev/null || true
                fi
            else
                open_firewall_port "$HTTP_PORT_REAL" "tcp"
            fi
        fi
    fi

    finalize_firewall_changes

    echo ""
    print_info "$(msg INSTALL_COMPLETE)"
    print_info "$(msg INSTALL_COMPLETE2)"
    if [[ -n "$APP_VERSION" ]]; then
        print_info "$(msg INSTALLED_VERSION "$APP_VERSION")"
    fi
    print_info "$(msg INSTALL_COMPLETE)"
    echo ""

    if [[ "$FIREWALL_BACKEND" != "none" ]]; then
        local opened_ports=""
        local skipped_ports=""
        if (( ${#FIREWALL_PORTS_OPENED[@]} > 0 )); then
            opened_ports="$(printf "%s\n" "${FIREWALL_PORTS_OPENED[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
        fi
        if (( ${#FIREWALL_PORTS_SKIPPED[@]} > 0 )); then
            skipped_ports="$(printf "%s\n" "${FIREWALL_PORTS_SKIPPED[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
        fi

        if [[ -n "$opened_ports" ]]; then
            print_info "$(msg FIREWALL_OPENED_PORTS "$FIREWALL_BACKEND" "$opened_ports")"
        fi
        if [[ -n "$skipped_ports" ]]; then
            print_warning "$(msg FIREWALL_MANUAL_PORTS "$skipped_ports")"
        fi

        if [[ "$FIREWALL_BACKEND" == "ufw" && "$FIREWALL_BACKEND_STATE" != "active" ]]; then
            print_warning "$(msg UFW_NOT_APPLIED)"
        fi
        if [[ "$FIREWALL_BACKEND" == "firewalld" && "$FIREWALL_BACKEND_STATE" != "active" ]]; then
            print_warning "$(msg FIREWALLD_NOT_APPLIED)"
        fi
        echo ""
    fi

    print_info "$(msg CONFIGURATION)"
    print_info "$(msg CONTAINER_NAME "$CONTAINER_NAME")"
    print_info "$(msg WIREGUARD_PORT "$WIREGUARD_PORT")"
    print_info "$(msg WEB_PREFIX "$WEB_PREFIX")"
    if [[ "$ENABLE_HTTPS" == true ]]; then
        print_info "$(msg HTTPS_ENABLED "true")"
    else
        print_info "$(msg HTTPS_ENABLED "false")"
    fi
    echo ""

    if [[ "$ENABLE_HTTPS" == true ]]; then
        print_info "$(msg HTTP_URL "http://$DOMAIN$WEB_PREFIX")"
        print_info "$(msg HTTPS_URL "https://$DOMAIN$WEB_PREFIX")"
    else
        if [[ "$HTTP_PORT" == 80 ]]; then
            print_info "$(msg HTTP_URL_SIMPLE "http://$EXTERNAL_IP$WEB_PREFIX")"
        else
            print_info "$(msg HTTP_URL_SIMPLE "http://$EXTERNAL_IP:$HTTP_PORT$WEB_PREFIX")"
        fi
    fi
    echo ""

    if [[ "$CONFIG_EXISTS" == false || "$NEW_PASSWORD" == true ]]; then
        print_info "$(msg LOGIN_CREDENTIALS)"
        print_info "$(msg USERNAME)"
        if [[ -n "$ADMIN_PASSWORD" ]]; then
            print_info "$(msg PASSWORD "$ADMIN_PASSWORD")"
        fi
    else
        print_info "$(msg LOGIN_SAME)"
    fi
    echo ""

    if [[ "$ENABLE_HTTPS" == true ]]; then
        print_warning "$(msg CERT_WAIT)"
    fi
    print_warning "$(msg SAVE_CREDENTIALS)"
    if [[ "$ENABLE_HTTPS" == false ]]; then
        print_warning "$(msg HTTPS_NOT_ENABLED)"
    fi

    save_install_config "$CONFIG_FILE" "$DOMAIN" "$ENABLE_HTTPS" "$HTTP_PORT_REAL" "$WEB_PREFIX" "$WIREGUARD_PORT" "$ACME_EMAIL"
}

main "$@"

