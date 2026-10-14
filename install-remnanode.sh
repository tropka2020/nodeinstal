#!/usr/bin/env bash

set -Eeuo pipefail

NODE_DIR="/opt/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"

LOG_DIR="/var/log/remnanode"
LOGROTATE_FILE="/etc/logrotate.d/remnanode"

SELFSTEAL_SCRIPT="/tmp/selfsteal.sh"

trap 'echo; echo "[ERROR] Ошибка в строке ${LINENO}"; exit 1' ERR

log() {
    echo
    echo "[INFO] $*"
}

warn() {
    echo
    echo "[WARN] $*"
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
            die "Поддерживаются только Ubuntu и Debian."
            ;;
    esac
}

check_ipv4() {
    local ip="$1"

    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r octet1 octet2 octet3 octet4 <<< "${ip}"

    for octet in "${octet1}" "${octet2}" "${octet3}" "${octet4}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done

    return 0
}

check_domain() {
    local domain="$1"

    [[ "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

collect_settings() {
    echo
    echo "=============================================="
    echo "Настройка Remnawave Node"
    echo "=============================================="
    echo

    while true; do
        read -r -p "Введите IP-адрес панели Remnawave: " PANEL_IP

        if check_ipv4 "${PANEL_IP}"; then
            break
        fi

        echo "Ошибка: указан некорректный IPv4-адрес."
    done

    while true; do
        read -r -s -p "Введите SECRET_KEY ноды: " NODE_SECRET_KEY
        echo

        if [[ -z "${NODE_SECRET_KEY}" ]]; then
            echo "Ошибка: SECRET_KEY не может быть пустым."
            continue
        fi

        if [[ "${NODE_SECRET_KEY}" =~ [[:space:]] ]]; then
            echo "Ошибка: SECRET_KEY не должен содержать пробелы."
            continue
        fi

        break
    done

    echo
    echo "=============================================="
    echo "Настройка Selfsteal Caddy"
    echo "=============================================="
    echo

    while true; do
        read -r -p "Введите домен Selfsteal: " SELFSTEAL_DOMAIN

        if check_domain "${SELFSTEAL_DOMAIN}"; then
            break
        fi

        echo "Ошибка: указан некорректный домен."
    done

    echo
    echo "Проверьте параметры:"
    echo
    echo "  IP панели:          ${PANEL_IP}"
    echo "  Node API port:      2222"
    echo "  Selfsteal:          Caddy"
    echo "  Домен Selfsteal:    ${SELFSTEAL_DOMAIN}"
    echo "  Каталог логов:      ${LOG_DIR}"
    echo

    read -r -p "Начать установку? [y/N]: " confirmation

    if [[ "${confirmation,,}" != "y" ]]; then
        echo "Установка отменена."
        exit 0
    fi
}

install_required_packages() {
    log "Обновление списка пакетов"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    log "Установка необходимых пакетов"

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

    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose Plugin не установлен или недоступен."
    fi
}

prepare_directories() {
    log "Создание каталогов"

    mkdir -p "${NODE_DIR}"
    mkdir -p "${LOG_DIR}"

    chmod 755 "${NODE_DIR}"
    chmod 755 "${LOG_DIR}"
}

create_node_compose() {
    log "Создание Docker Compose для Remnawave Node"

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

    log "Создан файл:"
    echo "${COMPOSE_FILE}"
}

configure_ufw() {
    log "Настройка UFW"

    # Сначала разрешаем SSH, чтобы не потерять доступ к серверу.
    ufw allow 22/tcp comment "SSH"

    # Порты Caddy и получения SSL-сертификата.
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Удаляем возможное общее разрешение 2222, если оно было добавлено ранее.
    ufw delete allow 2222/tcp >/dev/null 2>&1 || true
    ufw delete allow 2222 >/dev/null 2>&1 || true

    # Node API доступен только с IP панели.
    ufw allow from "${PANEL_IP}" \
        to any port 2222 \
        proto tcp \
        comment "Remnawave Panel to Node"

    ufw default deny incoming
    ufw default allow outgoing

    ufw --force enable
    ufw reload

    echo
    echo "Текущие правила UFW:"
    ufw status numbered
}

configure_logrotate() {
    log "Создание конфигурации logrotate"

    mkdir -p "${LOG_DIR}"

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

    log "Проверка конфигурации logrotate"

    logrotate -d "${LOGROTATE_FILE}" >/dev/null

    log "Принудительный тестовый запуск logrotate"

    logrotate -vf "${LOGROTATE_FILE}"
}

start_remnanode() {
    log "Загрузка образа Remnawave Node"

    cd "${NODE_DIR}"

    docker compose pull

    log "Запуск Remnawave Node"

    docker compose up -d --force-recreate

    sleep 5

    docker compose ps
}

install_selfsteal_caddy() {
    log "Загрузка Selfsteal"

    curl -fL \
        "https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh" \
        -o "${SELFSTEAL_SCRIPT}"

    chmod 700 "${SELFSTEAL_SCRIPT}"

    log "Установка Selfsteal в режиме Caddy"

    bash "${SELFSTEAL_SCRIPT}" @ \
        --force \
        --domain "${SELFSTEAL_DOMAIN}" \
        install
}

restart_remnanode() {
    log "Повторный запуск Remnawave Node"

    cd "${NODE_DIR}"

    docker compose up -d --force-recreate
}

show_result() {
    echo
    echo "=============================================="
    echo "Установка завершена"
    echo "=============================================="
    echo

    echo "Docker Compose ноды:"
    echo "  ${COMPOSE_FILE}"
    echo

    echo "Каталог логов:"
    echo "  ${LOG_DIR}"
    echo

    echo "Конфигурация logrotate:"
    echo "  ${LOGROTATE_FILE}"
    echo

    echo "Проверка контейнера:"
    echo "  docker ps"
    echo

    echo "Логи Remnawave Node:"
    echo "  docker logs remnanode --tail 100"
    echo

    echo "Статус Selfsteal:"
    echo "  selfsteal status"
    echo

    echo "Логи Selfsteal:"
    echo "  selfsteal logs"
    echo

    echo "Проверка портов:"
    echo "  ss -lntp | grep -E ':80|:443|:2222|:9443'"
    echo

    echo "Проверка логов внутри контейнера:"
    echo "  docker exec remnanode ls -la /var/log/remnanode"
    echo

    echo "Проверка UFW:"
    echo "  ufw status numbered"
    echo

    echo "Теперь добавьте Node в панели Remnawave:"
    echo "  Node Address: IP или домен этого сервера"
    echo "  Node Port:    2222"
    echo
}

main() {
    require_root
    check_os
    collect_settings
    install_required_packages
    install_docker
    prepare_directories
    create_node_compose
    configure_ufw
    configure_logrotate
    start_remnanode
    install_selfsteal_caddy
    restart_remnanode
    show_result
}

main "$@"
