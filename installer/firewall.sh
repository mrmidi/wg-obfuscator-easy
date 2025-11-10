#!/bin/bash

# Firewall detection and rule management helpers.

FIREWALL_BACKEND="none"
FIREWALL_BACKEND_STATE="unknown"
FIREWALL_RELOAD_REQUIRED=false
IPTABLES_PERSISTENCE_CONFIGURED=false
declare -a FIREWALL_PORTS_OPENED=()
declare -a FIREWALL_PORTS_SKIPPED=()

firewall_init_state() {
    FIREWALL_BACKEND="none"
    FIREWALL_BACKEND_STATE="unknown"
    FIREWALL_RELOAD_REQUIRED=false
    IPTABLES_PERSISTENCE_CONFIGURED=false
    FIREWALL_PORTS_OPENED=()
    FIREWALL_PORTS_SKIPPED=()
}

detect_firewall_backend() {
    FIREWALL_BACKEND="none"
    FIREWALL_BACKEND_STATE="unknown"

    if command_exists firewall-cmd; then
        FIREWALL_BACKEND="firewalld"
        if firewall-cmd --state >/dev/null 2>&1; then
            FIREWALL_BACKEND_STATE="active"
        else
            FIREWALL_BACKEND_STATE="inactive"
        fi
        return
    fi

    if command_exists ufw; then
        FIREWALL_BACKEND="ufw"
        if ufw status 2>/dev/null | head -n1 | grep -qi "active"; then
            FIREWALL_BACKEND_STATE="active"
        else
            FIREWALL_BACKEND_STATE="inactive"
        fi
        return
    fi

    if command_exists iptables; then
        FIREWALL_BACKEND="iptables"
        FIREWALL_BACKEND_STATE="active"
    fi
}

record_firewall_result() {
    local spec="$1"
    local outcome="$2"
    local -n target_array="$3"

    for existing in "${target_array[@]}"; do
        [[ "$existing" == "$spec" ]] && return
    done

    target_array+=("$spec")
    if [[ "$outcome" == "opened" ]]; then
        print_info "$(msg FIREWALL_PORT_OPENED "$spec")"
    fi
}

ensure_iptables_persistence() {
    if [[ "$FIREWALL_BACKEND" != "iptables" ]]; then
        return
    fi

    local install_performed=false

    if [[ "$IPTABLES_PERSISTENCE_CONFIGURED" != "true" ]]; then
        case "$OS" in
            debian|ubuntu)
                print_info "$(msg IPTABLES_PERSISTENCE_NETFILTER)"
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -y netfilter-persistent iptables-persistent
                install_performed=true
                ;;
            rhel|centos|fedora)
                print_info "$(msg IPTABLES_PERSISTENCE_SERVICES)"
                if command_exists dnf; then
                    dnf install -y iptables-services
                else
                    yum install -y iptables-services
                fi
                systemctl enable iptables >/dev/null 2>&1 || true
                systemctl start iptables >/dev/null 2>&1 || true
                install_performed=true
                ;;
            alpine)
                print_info "$(msg IPTABLES_PERSISTENCE_OPENRC)"
                apk add --no-cache iptables ip6tables iptables-openrc
                rc-update add iptables default >/dev/null 2>&1 || true
                rc-update add ip6tables default >/dev/null 2>&1 || true
                install_performed=true
                ;;
            *)
                print_warning "$(msg IPTABLES_PERSISTENCE_UNSUPPORTED "$OS")"
                IPTABLES_PERSISTENCE_CONFIGURED=true
                return
                ;;
        esac
        IPTABLES_PERSISTENCE_CONFIGURED=true
    fi

    local save_success=false

    case "$OS" in
        debian|ubuntu)
            if command_exists netfilter-persistent; then
                netfilter-persistent save >/dev/null 2>&1 && save_success=true
            fi
            if [[ "$save_success" == false ]]; then
                mkdir -p /etc/iptables
                if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
                    save_success=true
                fi
                if command_exists ip6tables-save; then
                    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
                fi
            fi
            ;;
        rhel|centos|fedora)
            mkdir -p /etc/sysconfig
            if iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
                save_success=true
            fi
            if command_exists ip6tables-save; then
                ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
            fi
            ;;
        alpine)
            if command_exists rc-service; then
                rc-service iptables save >/dev/null 2>&1 && save_success=true
                rc-service ip6tables save >/dev/null 2>&1 || true
            fi
            if [[ "$save_success" == false ]]; then
                mkdir -p /etc/iptables
                if iptables-save > /etc/iptables/rules-save 2>/dev/null; then
                    save_success=true
                fi
                if command_exists ip6tables-save; then
                    ip6tables-save > /etc/iptables/rules6-save 2>/dev/null || true
                fi
            fi
            ;;
        *)
            return
            ;;
    esac

    if [[ "$save_success" == true ]]; then
        if [[ "$install_performed" == true ]]; then
            print_info "$(msg IPTABLES_PERSISTENCE_CONFIGURED)"
        else
            print_info "$(msg IPTABLES_RULES_SAVED)"
        fi
    else
        print_warning "$(msg IPTABLES_PERSISTENCE_FAILED)"
    fi
}

open_firewall_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local spec="${port}/${protocol}"

    case "$FIREWALL_BACKEND" in
        firewalld)
            if [[ "$FIREWALL_BACKEND_STATE" != "active" ]]; then
                print_warning "$(msg FIREWALL_NOT_ACTIVE "$spec")"
                record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
                return
            fi

            local runtime_added=false
            local permanent_added=false

            if ! firewall-cmd --query-port="$spec" >/dev/null 2>&1; then
                if firewall-cmd --add-port="$spec" >/dev/null 2>&1; then
                    runtime_added=true
                else
                    print_warning "$(msg FIREWALL_FAILED_RUNTIME "$spec")"
                fi
            fi

            if ! firewall-cmd --permanent --query-port="$spec" >/dev/null 2>&1; then
                if firewall-cmd --permanent --add-port="$spec" >/dev/null 2>&1; then
                    permanent_added=true
                    FIREWALL_RELOAD_REQUIRED=true
                else
                    print_warning "$(msg FIREWALL_FAILED_PERMANENT "$spec")"
                fi
            fi

            if [[ "$runtime_added" == true || "$permanent_added" == true ]]; then
                record_firewall_result "$spec" "opened" FIREWALL_PORTS_OPENED
            else
                print_info "$(msg FIREWALL_PORT_ALREADY_OPEN "$spec" "firewalld")"
            fi
            ;;
        ufw)
            local status_line
            status_line=$(ufw status 2>/dev/null | head -n1 || echo "")
            if echo "$status_line" | grep -qi "inactive"; then
                print_warning "$(msg UFW_INACTIVE "$spec")"
                record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
                return
            fi

            if ufw status numbered 2>/dev/null | grep -qw "$spec"; then
                print_info "$(msg FIREWALL_PORT_ALREADY_OPEN "$spec" "UFW")"
                return
            fi

            if ufw allow "$spec" >/dev/null 2>&1; then
                record_firewall_result "$spec" "opened" FIREWALL_PORTS_OPENED
            else
                print_warning "$(msg UFW_FAILED "$spec")"
                record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
            fi
            ;;
        iptables)
            if ! command_exists iptables; then
                record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
                print_warning "$(msg IPTABLES_NOT_AVAILABLE "$spec")"
                return
            fi

            if ! iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                if iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                    record_firewall_result "$spec" "opened" FIREWALL_PORTS_OPENED
                else
                    print_warning "$(msg IPTABLES_FAILED "$spec")"
                    record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
                fi
            else
                print_info "$(msg FIREWALL_PORT_ALREADY_OPEN "$spec" "iptables")"
            fi

            if [[ "$protocol" == "udp" || "$protocol" == "tcp" ]]; then
                if command_exists ip6tables; then
                    if ! ip6tables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                        ip6tables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
                    fi
                fi
            fi

            ensure_iptables_persistence
            ;;
        *)
            record_firewall_result "$spec" "skipped" FIREWALL_PORTS_SKIPPED
            print_warning "$(msg FIREWALL_NO_BACKEND "$spec")"
            ;;
    esac
}

finalize_firewall_changes() {
    if [[ "$FIREWALL_BACKEND" == "firewalld" && "$FIREWALL_BACKEND_STATE" == "active" && "$FIREWALL_RELOAD_REQUIRED" == true ]]; then
        if firewall-cmd --reload >/dev/null 2>&1; then
            print_info "$(msg FIREWALLD_RELOADED)"
            FIREWALL_RELOAD_REQUIRED=false
        else
            print_warning "$(msg FIREWALLD_RELOAD_FAILED)"
        fi
    fi
}
