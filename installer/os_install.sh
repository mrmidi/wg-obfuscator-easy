#!/bin/bash

# OS detection and package installer helpers.

OS="unknown"
OS_VERSION=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        OS_VERSION="$(cat /etc/debian_version)"
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        OS_VERSION="$(cat /etc/redhat-release)"
    else
        OS="unknown"
        OS_VERSION=""
    fi
}

install_curl() {
    print_info "$(msg INSTALLING_CURL)"
    case "$OS" in
        debian|ubuntu)
            apt-get update -qq
            apt-get install -y curl
            ;;
        rhel|centos|fedora)
            if command_exists dnf; then
                dnf install -y curl
            else
                yum install -y curl
            fi
            ;;
        alpine)
            apk add --no-cache curl
            ;;
        *)
            print_error "$(msg OS_DETECT_ERROR)"
            return 1
            ;;
    esac
}

install_systemd() {
    print_info "$(msg INSTALLING_SYSTEMD)"
    case "$OS" in
        debian|ubuntu)
            apt-get update -qq
            apt-get install -y systemd
            ;;
        rhel|centos|fedora)
            if command_exists dnf; then
                dnf install -y systemd
            else
                yum install -y systemd
            fi
            ;;
        alpine)
            apk add --no-cache systemd
            ;;
        *)
            print_error "$(msg OS_DETECT_ERROR_SYSTEMD)"
            return 1
            ;;
    esac
}

install_docker() {
    if command_exists docker; then
        print_info "$(msg DOCKER_INSTALLED)"
        return 0
    fi

    print_info "$(msg INSTALLING_DOCKER)"

    case "$OS" in
        debian|ubuntu)
            curl -fsSL https://get.docker.com -o get-docker.sh
            sh get-docker.sh
            rm -f get-docker.sh
            ;;
        rhel|centos|fedora)
            local docker_packages="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
            if command_exists dnf; then
                if rpm -q podman-docker >/dev/null 2>&1; then
                    print_warning "$(msg REMOVING_PODMAN)"
                    dnf remove -y podman-docker >/dev/null
                fi
                dnf install -y dnf-plugins-core
                if ! dnf repolist 2>/dev/null | grep -q "^docker-ce-stable"; then
                    print_info "$(msg ADDING_DOCKER_REPO)"
                    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
                fi
                dnf install -y $docker_packages
            else
                if rpm -q podman-docker >/dev/null 2>&1; then
                    print_warning "$(msg REMOVING_PODMAN)"
                    yum remove -y podman-docker >/dev/null
                fi
                yum install -y yum-utils
                if ! yum repolist 2>/dev/null | grep -q "^docker-ce-stable"; then
                    print_info "$(msg ADDING_DOCKER_REPO)"
                    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
                fi
                yum install -y $docker_packages
            fi
            systemctl enable docker
            systemctl start docker
            ;;
        alpine)
            apk add --no-cache docker
            rc-update add docker boot
            service docker start
            ;;
        *)
            print_error "$(msg OS_DETECT_ERROR_DOCKER)"
            return 1
            ;;
    esac

    if ! command_exists docker; then
        print_error "$(msg DOCKER_INSTALL_FAILED)"
        return 1
    fi

    print_info "$(msg DOCKER_INSTALLED_SUCCESS)"
}
