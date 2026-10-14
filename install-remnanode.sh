#!/usr/bin/env bash

set -Eeuo pipefail

NODE_DIR="/opt/remnanode"
LOG_DIR="/var/log/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
LOGROTATE_FILE="/etc/logrotate.d/remnanode"
SELFSTEAL_SCRIPT="/tmp/selfsteal.sh"

trap 'echo; echo "[ERROR] Ошибка в строке ${LINENO}"; exit 1' ERR

log() {
    echo
    echo "[INFO] $*"
}

die() {
    echo
    echo "[ERROR] $*"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root или через sudo."
    fi
}

check_ip() {
    local ip="$1"

    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r a b c d <<< "${ip}"

    for octet in "$a" "$b" "$c" "$d"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

check_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не удалось определить операционную систему."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            log "Операционная система: ${PRETTY_NAME}"
            ;;
        *)
            die "Поддерживаются Ubuntu и Debian."
            ;;
    esac
}

collect_settings() {
    echo
    echo "===== Настройка Remnawave Node ====="
    echo

    while true; do
        read -r -p "IP-адрес панели Remnawave: " PANEL_IP

        if check_ip "${PANEL_IP}"; then
            break
        fi

        echo "Некорректный IPv4-адрес."
    done

    while true; do
        read -r -s -p "SECRET_KEY ноды: " NODE_SECRET_KEY
        echo

        if [[ -n "${NODE_SECRET_KEY}" ]]; then
            break
        fi

        echo "SECRET_KEY не может быть пустым."
    done

    echo
    echo "===== Настройка Selfsteal Caddy ====="
    echo

    while true; do
        read -r -p "Домен Selfsteal, направленный на этот сервер: " SELFSTEAL_DOMAIN

        if check_domain "${SELFSTEAL_DOMAIN}"; then
            break
        fi

        echo "Некорректное доменное имя."
    done

    echo
    echo "Будет настроено:"
    echo "  Panel IP:          ${PANEL_IP}"
    echo "  Node API port:     2222/tcp"
    echo "  Selfsteal:         Caddy"
    echo "  Selfsteal domain:  ${SELFSTEAL_DOMAIN}"
    echo "  Node logs:         ${LOG_DIR}"
    echo

    read -r -p "Продолжить установку? [y/N]: " answer

    if [[ "${answer,,}" != "y" ]]; then
        echo "Установка отменена."
        exit 0
    fi
}

install_packages() {
    log "Установка необходимых пакетов"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        ufw \
        logrotate \
        iproute2 \
        procps \
        dnsutils
}

install_docker() {
    if command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then
        log "Docker и Docker Compose уже установлены"
        systemctl enable --now docker
        return
    fi

    log "Установка Docker"

    curl -fsSL https://get.docker.com | sh

    systemctl enable --now docker

    docker compose version >/dev/null 2>&1 ||
        die "Docker Compose plugin не установлен."
}

prepare_directories() {
    log "Создание каталогов"

    mkdir -p "${NODE_DIR}"
    mkdir -p "${LOG_DIR}"

    chmod 755 "${NODE_DIR}"
    chmod 755 "${LOG_DIR}"
}

write_node_compose() {
    log "Создание ${COMPOSE_FILE}"

    cat > "${COMPOSE_FILE}" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${NODE_SECRET_KEY}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

    chmod 600 "${COMPOSE_FILE}"
}

configure_ufw() {
    log "Настройка UFW"

    # Сначала разрешаем SSH, чтобы не потерять доступ.
    ufw allow 22/tcp comment "SSH"

    # Порты Caddy и ACME.
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # API ноды доступен только панели.
    ufw allow from "${PANEL_IP}" \
        to any port 2222 \
        proto tcp \
        comment "Remnawave Panel to Node"

    ufw default deny incoming
    ufw default allow outgoing

    ufw --force enable
    ufw reload

    ufw status numbered
}

configure_logrotate() {
    log "Настройка logrotate"

    cat > "${LOGROTATE_FILE}" <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    chmod 644 "${LOGROTATE_FILE}"

    logrotate -d "${LOGROTATE_FILE}" >/dev/null

    log "Конфигурация logrotate проверена"
}

start_node() {
    log "Запуск Remnawave Node"

    cd "${NODE_DIR}"

    docker compose pull
    docker compose up -d

    sleep 5

    docker compose ps
}

install_selfsteal_caddy() {
    log "Загрузка Selfsteal"

    curl -fL \
        "https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh" \
        -o "${SELFSTEAL_SCRIPT}"

    chmod 700 "${SELFSTEAL_SCRIPT}"

    log "Установка Selfsteal на Caddy"

    bash "${SELFSTEAL_SCRIPT}" @ \
        --force \
        --domain "${SELFSTEAL_DOMAIN}" \
        install
}

restart_node_after_selfsteal() {
    log "Перезапуск Remnawave Node"

    cd "${NODE_DIR}"

    docker compose up -d --force-recreate
}

show_result() {
    echo
    echo "=============================================="
    echo "Установка завершена"
    echo "=============================================="
    echo
    echo "Node Compose:"
    echo "  ${COMPOSE_FILE}"
    echo
    echo "Логи Node:"
    echo "  ${LOG_DIR}"
    echo
    echo "Проверка Node:"
    echo "  docker logs remnanode --tail 100"
    echo
    echo "Проверка Selfsteal:"
    echo "  selfsteal status"
    echo
    echo "Логи Selfsteal:"
    echo "  selfsteal logs"
    echo
    echo "Проверка портов:"
    echo "  ss -lntp | grep -E ':80|:443|:2222|:9443'"
    echo
    echo "Проверка logrotate:"
    echo "  logrotate -vf /etc/logrotate.d/remnanode"
    echo
    echo "Проверка UFW:"
    echo "  ufw status numbered"
    echo
    echo "Теперь добавьте Node в панели Remnawave."
    echo "Node Port: 2222"
    echo
}

main() {
    require_root
    check_os
    collect_settings
    install_packages
    install_docker
    prepare_directories
    write_node_compose
    configure_ufw
    configure_logrotate
    start_node
    install_selfsteal_caddy
    restart_node_after_selfsteal
    show_result
}

main "$@"
