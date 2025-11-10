#!/bin/bash

# Docker lifecycle helpers for WireGuard Obfuscator Easy.

pull_container_image() {
    local image="$1"
    print_info "$(msg PULLING_IMAGE "$image")"
    if ! docker pull "$image" >/dev/null 2>&1; then
        print_error "$(msg PULL_FAILED)"
        return 1
    fi
}

start_wg_container() {
    local image="$1"
    local container_name="$2"
    local config_dir="$3"
    local web_prefix="$4"
    local external_ip="$5"
    local wireguard_port="$6"
    local admin_password="$7"
    local http_port="$8"

    print_info "$(msg STARTING_CONTAINER)"
    docker run -d \
        --name "$container_name" \
        -v "$config_dir:/config" \
        -e WEB_PREFIX="$web_prefix" \
        -e EXTERNAL_IP="$external_ip" \
        -e EXTERNAL_PORT="$wireguard_port" \
        -e ADMIN_PASSWORD="$admin_password" \
        -e LOG_LEVEL=DEBUG \
        -p "${wireguard_port}:${wireguard_port}/udp" \
        -p "${http_port}:5000/tcp" \
        --cap-add NET_ADMIN \
        --cap-add SYS_MODULE \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        --restart unless-stopped \
        "$image" >/dev/null 2>&1 || {
            print_error "$(msg CONTAINER_START_FAILED)"
            return 1
        }
}

wait_for_container() {
    local container_name="$1"
    local timeout="${2:-30}"

    print_info "$(msg CONTAINER_WAITING)"
    sleep 5

    local elapsed=0
    while (( elapsed < timeout )); do
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            print_info "$(msg CONTAINER_RUNNING)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        print_info "$(msg CONTAINER_RUNNING)"
        return 0
    fi

    print_error "$(msg CONTAINER_FAILED "$container_name")"
    return 1
}

wait_for_app() {
    local http_port="$1"
    local web_prefix="$2"
    local attempts="${3:-10}"

    print_info "$(msg APP_WAITING)"
    sleep 5

    local count=0
    while (( count < attempts )); do
        if curl -s -f -o /dev/null "http://localhost:${http_port}${web_prefix}" 2>/dev/null || \
           curl -s -f -o /dev/null "http://127.0.0.1:${http_port}${web_prefix}" 2>/dev/null; then
            print_info "$(msg APP_RESPONDING)"
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done

    print_warning "$(msg APP_NOT_READY)"
    return 1
}

get_app_version() {
    local container_name="$1"
    local version="unknown"

    local python_version
    python_version=$(docker exec "$container_name" python3 -c "import sys; sys.path.insert(0, '/app'); from version import VERSION; print(VERSION)" 2>/dev/null)
    if [[ -n "$python_version" ]]; then
        version="$python_version"
    fi

    echo "$version"
}

reset_admin_credentials() {
    local container_name="$1"
    local password="$2"

    print_info "$(msg RESETTING_ADMIN_CREDENTIALS)"

    if [[ -z "$password" ]]; then
        print_error "$(msg ADMIN_RESET_FAILED)" >&2
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "$(msg DOCKER_NOT_RUNNING)"
        return 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        print_error "$(msg CONTAINER_NOT_RUNNING "$container_name")"
        return 1
    fi

    local python_output
    if ! python_output=$(docker exec "$container_name" python3 reset-creds.py "$password" 2>&1); then
        print_error "$(msg ADMIN_RESET_FAILED)" >&2
        [[ -n "$python_output" ]] && echo "$python_output" >&2
        return 1
    fi

    return 0
}
