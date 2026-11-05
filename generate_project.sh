#!/usr/bin/env bash
# =============================================================================
# generate_project.sh — генератор проекта мониторинга диска «myservis».
# Создаёт Python-сервис, Dockerfile, docker-compose.yml, README и 5 bash-скриптов.
# Сам ничего не устанавливает и не запускает.
# Запуск:  sudo bash generate_project.sh
# Каталог установки по умолчанию /opt/myservis (переопределяется MYSERVIS_DIR).
# =============================================================================
set -euo pipefail

PROJECT_DIR="${MYSERVIS_DIR:-/opt/myservis}"

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "Скрипт рассчитан на Linux (Ubuntu 22.04 в WSL2 или VM)."
  exit 1
fi

info "Создание проекта в $PROJECT_DIR"
if ! mkdir -p "$PROJECT_DIR"/{app,data,logs,scripts} 2>/dev/null; then
  err "Нет прав на создание $PROJECT_DIR. Запустите: sudo bash $0"
  exit 1
fi

# write_file <путь> <режим> <содержимое> [keep]
# keep — не перезаписывать файл, если он уже существует (чтобы не терять правки).
write_file() {
  local path="$1" mode="$2" content="$3" keep="${4:-}"
  if [[ "$keep" == "keep" && -s "$path" ]]; then
    warn "Оставлен без изменений (уже существует): ${path#"$PROJECT_DIR"/}"
    return 0
  fi
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

# -----------------------------------------------------------------------------
# Содержимое конфигурационных файлов (используется и здесь, и в 02_create_structure.sh)
# -----------------------------------------------------------------------------
CONFIG_YAML=$(cat <<'EOF_CFG'
# Настройки сервиса myservis
interval_sec: 5            # период сбора метрик, секунд
threshold_percent: 90      # при превышении в лог пишется WARNING
db_path: data/metrics.db   # относительные пути считаются от каталога приложения (/app)
log_path: logs/myservis.log
port: 8080
EOF_CFG
)

REQUIREMENTS_TXT=$(cat <<'EOF_REQ'
Flask==3.0.3
PyYAML==6.0.2
EOF_REQ
)

DOCKERFILE=$(cat <<'EOF_DOCKER'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py config.yaml ./
RUN mkdir -p /app/data /app/logs

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/current', timeout=2).status == 200 else 1)"

CMD ["python", "main.py"]
EOF_DOCKER
)

COMPOSE_YML=$(cat <<'EOF_COMPOSE'
services:
  myservis:
    build: ./app
    image: myservis:latest
    container_name: myservis
    ports:
      - "8080:8080"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
EOF_COMPOSE
)

# -----------------------------------------------------------------------------
# Python-приложение
# -----------------------------------------------------------------------------
info "Файлы приложения (app/)"
write_file "$PROJECT_DIR/app/config.yaml"      644 "$CONFIG_YAML" keep
write_file "$PROJECT_DIR/app/requirements.txt" 644 "$REQUIREMENTS_TXT"
write_file "$PROJECT_DIR/app/Dockerfile"       644 "$DOCKERFILE"
write_file "$PROJECT_DIR/docker-compose.yml"   644 "$COMPOSE_YML"

MAIN_PY=$(cat <<'EOF_PY'
#!/usr/bin/env python3
"""myservis — веб-сервис мониторинга свободного места на диске.

* фоновый поток раз в interval_sec секунд снимает метрики корневой ФС;
* метрики пишутся в SQLite (таблица disk_stats);
* события пишутся в лог-файл; при превышении порога — WARNING;
* HTML-страница (/) и JSON API (/api/current, /api/history);
* корректное завершение по SIGTERM / SIGINT.
"""
import logging
import os
import shutil
import signal
import sqlite3
import sys
import threading
from contextlib import closing
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

import yaml
from flask import Flask, jsonify, render_template_string, request
from werkzeug.serving import make_server

BASE_DIR = Path(__file__).resolve().parent

DEFAULT_CONFIG = {
    "interval_sec": 5,
    "threshold_percent": 90,
    "db_path": "data/metrics.db",
    "log_path": "logs/myservis.log",
    "port": 8080,
}

PAGE = """<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="{{ refresh }}">
  <title>Мониторинг диска — myservis</title>
  <style>
    body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
           background: #f3f5f9; color: #1c2430; margin: 0; }
    main { max-width: 900px; margin: 0 auto; padding: 32px 20px 48px; }
    h1 { font-size: 1.5rem; color: #1a4fa0; margin: 0 0 20px; }
    h2 { font-size: 1.05rem; margin: 28px 0 10px; }
    .card { background: #fff; border-radius: 12px; padding: 18px 22px;
            box-shadow: 0 1px 4px rgba(0,0,0,.12); }
    .card h2 { margin-top: 0; }
    .percent { font-size: 2.4rem; font-weight: 700; margin: 6px 0; }
    .percent.ok { color: #1b8a4b; }
    .percent.bad { color: #c62828; }
    .muted { color: #5b6674; font-size: .85rem; }
    .alert { background: #fdecea; color: #b71c1c; border-radius: 8px;
             padding: 8px 12px; margin-top: 10px; font-weight: 600; }
    table { width: 100%; border-collapse: collapse; background: #fff;
            border-radius: 12px; overflow: hidden; font-size: .85rem;
            box-shadow: 0 1px 4px rgba(0,0,0,.12); }
    th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #e6eaf0; }
    th { background: #e9eef8; }
    td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; }
  </style>
</head>
<body>
<main>
  <h1>myservis — мониторинг свободного места</h1>
  <section class="card">
    <h2>Текущие показатели корневой файловой системы</h2>
    <div class="percent {{ 'bad' if alert else 'ok' }}">{{ '%.2f'|format(cur.percent) }}%</div>
    <div>Занято: {{ cur.used|num }} байт &nbsp; Свободно: {{ cur.free|num }} байт &nbsp; Всего: {{ cur.total|num }} байт</div>
    <div class="muted">Обновлено: {{ cur.ts }} &nbsp;|&nbsp; порог предупреждения: {{ threshold }}%</div>
    {% if alert %}<div class="alert">Внимание: занято больше {{ threshold }}% диска</div>{% endif %}
  </section>
  <h2>Последние измерения (до 20)</h2>
  <table>
    <thead><tr><th>Время</th><th class="n">Всего, байт</th><th class="n">Занято, байт</th><th class="n">Свободно, байт</th><th class="n">%</th></tr></thead>
    <tbody>
    {% for r in rows %}
      <tr><td>{{ r.ts }}</td><td class="n">{{ r.total }}</td><td class="n">{{ r.used }}</td><td class="n">{{ r.free }}</td><td class="n">{{ '%.2f'|format(r.percent) }}</td></tr>
    {% else %}
      <tr><td colspan="5">Данных пока нет</td></tr>
    {% endfor %}
    </tbody>
  </table>
</main>
</body>
</html>
"""


def load_config():
    """Читает config.yaml (путь можно задать через MYSERVIS_CONFIG)."""
    path = Path(os.environ.get("MYSERVIS_CONFIG", BASE_DIR / "config.yaml"))
    cfg = dict(DEFAULT_CONFIG)
    if path.is_file():
        with path.open(encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        if not isinstance(data, dict):
            raise ValueError(f"{path}: ожидался словарь параметров")
        cfg.update({k: v for k, v in data.items() if k in DEFAULT_CONFIG})
    cfg["interval_sec"] = max(1, int(cfg["interval_sec"]))
    cfg["threshold_percent"] = float(cfg["threshold_percent"])
    cfg["port"] = int(cfg["port"])
    for key in ("db_path", "log_path"):
        p = Path(str(cfg[key]))
        cfg[key] = str(p if p.is_absolute() else BASE_DIR / p)
    return cfg


def setup_logging(log_path):
    """Лог в файл (с ротацией) и в stdout: [YYYY-MM-DD HH:MM:SS] [LEVEL] message."""
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    logger = logging.getLogger("myservis")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    logger.propagate = False
    file_handler = RotatingFileHandler(log_path, maxBytes=5 * 1024 * 1024,
                                       backupCount=3, encoding="utf-8")
    stream_handler = logging.StreamHandler(sys.stdout)
    for handler in (file_handler, stream_handler):
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
    return logger


def collect_metrics():
    """Метрики корневой файловой системы."""
    usage = shutil.disk_usage("/")
    percent = round(usage.used / usage.total * 100, 2) if usage.total else 0.0
    return {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "total": usage.total,
        "used": usage.used,
        "free": usage.free,
        "percent": percent,
    }


class Storage:
    """Хранилище метрик в SQLite."""

    def __init__(self, db_path):
        self.db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        with closing(self._connect()) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS disk_stats ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "ts TEXT NOT NULL, total INTEGER NOT NULL, used INTEGER NOT NULL, "
                "free INTEGER NOT NULL, percent REAL NOT NULL)"
            )
            conn.commit()

    def _connect(self):
        return sqlite3.connect(self.db_path, timeout=10)

    def add(self, rec):
        with self._lock, closing(self._connect()) as conn:
            conn.execute(
                "INSERT INTO disk_stats (ts, total, used, free, percent) VALUES (?, ?, ?, ?, ?)",
                (rec["ts"], rec["total"], rec["used"], rec["free"], rec["percent"]),
            )
            conn.commit()

    def latest(self, limit):
        with closing(self._connect()) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT id, ts, total, used, free, percent FROM disk_stats "
                "ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(r) for r in rows]


class Collector(threading.Thread):
    """Фоновый поток: измерение -> БД -> лог."""

    def __init__(self, storage, interval, threshold, stop_event, logger):
        super().__init__(name="collector", daemon=True)
        self.storage = storage
        self.interval = interval
        self.threshold = threshold
        self.stop_event = stop_event
        self.log = logger

    def run(self):
        while not self.stop_event.is_set():
            try:
                rec = collect_metrics()
                self.storage.add(rec)
                self.log.info("Метрики собраны: %.2f%%", rec["percent"])
                if rec["percent"] > self.threshold:
                    self.log.warning("Занято %.2f%% диска, порог %g%%",
                                     rec["percent"], self.threshold)
            except Exception:  # поток не должен умирать из-за разовой ошибки
                self.log.exception("Ошибка сбора метрик")
            self.stop_event.wait(self.interval)


def create_app(cfg, storage):
    app = Flask(__name__)
    app.json.ensure_ascii = False
    app.json.sort_keys = False
    threshold = cfg["threshold_percent"]

    app.add_template_filter(lambda n: f"{int(n):,}".replace(",", " "), "num")

    def current():
        rows = storage.latest(1)
        return rows[0] if rows else {"id": None, **collect_metrics()}

    @app.get("/")
    def index():
        cur = current()
        return render_template_string(
            PAGE, cur=cur, rows=storage.latest(20), threshold=threshold,
            alert=cur["percent"] > threshold, refresh=cfg["interval_sec"],
        )

    @app.get("/api/current")
    def api_current():
        cur = current()
        return jsonify({**cur, "threshold_percent": threshold,
                        "alert": cur["percent"] > threshold})

    @app.get("/api/history")
    def api_history():
        try:
            limit = int(request.args.get("limit", 100))
        except ValueError:
            return jsonify({"error": "limit должен быть целым числом"}), 400
        limit = max(1, min(limit, 1000))
        items = storage.latest(limit)
        return jsonify({"count": len(items), "items": items})

    return app


def main():
    try:
        cfg = load_config()
    except Exception as exc:
        print(f"[x] Ошибка конфигурации: {exc}", file=sys.stderr)
        return 1

    log = setup_logging(cfg["log_path"])
    storage = Storage(cfg["db_path"])
    stop = threading.Event()

    def on_signal(signum, _frame):
        stop.set()  # в обработчике только ставим флаг; остальное делает main()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    try:
        server = make_server("0.0.0.0", cfg["port"], create_app(cfg, storage), threaded=True)
    except OSError as exc:
        log.error("Не удалось занять порт %d: %s", cfg["port"], exc)
        return 1

    collector = Collector(storage, cfg["interval_sec"], cfg["threshold_percent"], stop, log)
    http_thread = threading.Thread(target=server.serve_forever, name="http", daemon=True)
    collector.start()
    http_thread.start()
    log.info("Сервис запущен: http://0.0.0.0:%d (интервал %d с, порог %g%%)",
             cfg["port"], cfg["interval_sec"], cfg["threshold_percent"])

    while not stop.wait(1.0):
        pass

    log.info("Получен сигнал завершения, останавливаю сервис")
    server.shutdown()
    http_thread.join(timeout=5)
    collector.join(timeout=5)
    log.info("Сервис остановлен")
    logging.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_PY
)
write_file "$PROJECT_DIR/app/main.py" 644 "$MAIN_PY"

# -----------------------------------------------------------------------------
# Скрипт 01_prepare.sh
# -----------------------------------------------------------------------------
info "Скрипты развёртывания (scripts/)"
S01=$(cat <<'EOF_S01'
#!/usr/bin/env bash
# 01_prepare.sh — проверка окружения и установка Docker Engine + Compose v2.
# Запуск: sudo bash scripts/01_prepare.sh
set -euo pipefail

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "Нужен Linux (Ubuntu 22.04 в WSL2 или VM)"; exit 1
fi
if [[ $EUID -ne 0 ]]; then
  err "Запустите от root: sudo bash $0"; exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  err "Не найден apt-get: поддерживаются только Ubuntu/Debian"; exit 1
fi
info "Система: $(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"

export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
apt_install() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    apt-get update -y
    APT_UPDATED=1
  fi
  apt-get install -y --no-install-recommends "$@"
}

# --- базовые утилиты ---------------------------------------------------------
need=()
command -v curl    >/dev/null 2>&1 || need+=(curl)
command -v sqlite3 >/dev/null 2>&1 || need+=(sqlite3)
command -v gpg     >/dev/null 2>&1 || need+=(gnupg)
[[ -f /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
if (( ${#need[@]} > 0 )); then
  info "Устанавливаю: ${need[*]}"
  apt_install "${need[@]}"
else
  info "curl, sqlite3, gnupg уже установлены"
fi

# --- репозиторий Docker ------------------------------------------------------
setup_docker_repo() {
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    return 0
  fi
  local distro codename
  distro="$(. /etc/os-release && echo "${ID:-}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ "$distro" != "ubuntu" && "$distro" != "debian" ]] || [[ -z "$codename" ]]; then
    err "Неподдерживаемый дистрибутив: ${distro:-?}"; exit 1
  fi
  info "Подключаю официальный репозиторий Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  APT_UPDATED=0
}

if ! command -v docker >/dev/null 2>&1; then
  info "Docker не найден — устанавливаю Docker Engine"
  setup_docker_repo
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  info "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
  info "Docker Compose v2 не найден — устанавливаю docker-compose-plugin"
  setup_docker_repo
  apt_install docker-compose-plugin
fi
info "Compose: $(docker compose version)"

# --- группа docker -----------------------------------------------------------
TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  getent group docker >/dev/null 2>&1 || groupadd docker
  user_groups="$(id -nG "$TARGET_USER")"
  if [[ " $user_groups " == *" docker "* ]]; then
    info "Пользователь $TARGET_USER уже в группе docker"
  else
    usermod -aG docker "$TARGET_USER"
    warn "Пользователь $TARGET_USER добавлен в группу docker: перезайдите в сессию или выполните newgrp docker"
  fi
else
  warn "SUDO_USER не определён — пользователя в группу docker не добавляю"
fi

# --- демон Docker ------------------------------------------------------------
if docker info >/dev/null 2>&1; then
  info "Демон Docker уже работает"
else
  if [[ -d /run/systemd/system ]]; then
    info "Запускаю Docker через systemd"
    systemctl enable --now docker
  else
    warn "systemd не обнаружен (WSL2 без systemd) — запускаю: service docker start"
    service docker start
  fi
  for _ in $(seq 1 20); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker info >/dev/null 2>&1; then
    err "Демон Docker не запустился"; exit 1
  fi
  info "Демон Docker запущен"
fi

info "Подготовка завершена. Следующий шаг: sudo bash scripts/02_create_structure.sh"
EOF_S01
)
write_file "$PROJECT_DIR/scripts/01_prepare.sh" 755 "$S01"

# -----------------------------------------------------------------------------
# Скрипт 02_create_structure.sh (файлы-заготовки встраиваются из переменных выше)
# -----------------------------------------------------------------------------
emit_block() {  # emit_block <относительный путь> <содержимое>
  printf "write_if_missing %s <<'__MYSERVIS_EOF__'\n%s\n__MYSERVIS_EOF__\n\n" "$1" "$2"
}

{
  cat <<'EOF_S02_HEAD'
#!/usr/bin/env bash
# 02_create_structure.sh — создаёт каталоги и недостающие файлы проекта.
# Существующие файлы не перезаписываются. Запуск: sudo bash scripts/02_create_structure.sh
set -euo pipefail

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

write_if_missing() {  # содержимое файла читается из stdin
  local rel="$1"
  if [[ -s "$rel" ]]; then
    info "Уже на месте: $rel"
    cat > /dev/null
  else
    cat > "$rel"
    info "Создан: $rel"
  fi
}

info "Проверка структуры проекта в $PROJECT_DIR"
mkdir -p app data logs scripts

EOF_S02_HEAD
  emit_block "docker-compose.yml"   "$COMPOSE_YML"
  emit_block "app/config.yaml"      "$CONFIG_YAML"
  emit_block "app/requirements.txt" "$REQUIREMENTS_TXT"
  emit_block "app/Dockerfile"       "$DOCKERFILE"
  cat <<'EOF_S02_TAIL'
if [[ ! -s app/main.py ]]; then
  err "Нет app/main.py — заново запустите generate_project.sh"
  exit 1
fi
info "Найден: app/main.py"

chmod 755 data logs
chmod +x scripts/*.sh
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$PROJECT_DIR"
fi

info "Структура и файлы на месте. Следующий шаг: sudo bash scripts/03_build_and_up.sh"
EOF_S02_TAIL
} > "$PROJECT_DIR/scripts/02_create_structure.sh"
chmod 755 "$PROJECT_DIR/scripts/02_create_structure.sh"

# -----------------------------------------------------------------------------
# Скрипт 03_build_and_up.sh
# -----------------------------------------------------------------------------
S03=$(cat <<'EOF_S03'
#!/usr/bin/env bash
# 03_build_and_up.sh — сборка образа и запуск контейнера в фоне.
# Запуск: sudo bash scripts/03_build_and_up.sh
set -euo pipefail

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ ! -f docker-compose.yml || ! -f app/main.py ]]; then
  err "Проект не готов. Сначала: sudo bash scripts/02_create_structure.sh"; exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  err "Docker не установлен. Сначала: sudo bash scripts/01_prepare.sh"; exit 1
fi

# Нужен ли sudo: группа docker применяется только в новой сессии.
DOCKER=(docker)
SUDO=()
if [[ $EUID -ne 0 ]]; then
  SUDO=(sudo)
fi
if ! docker info >/dev/null 2>&1; then
  DOCKER=("${SUDO[@]}" docker)
  if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
    warn "Демон Docker не отвечает — пробую запустить"
    if [[ -d /run/systemd/system ]]; then
      "${SUDO[@]}" systemctl start docker
    else
      "${SUDO[@]}" service docker start
    fi
    for _ in $(seq 1 20); do
      "${DOCKER[@]}" info >/dev/null 2>&1 && break
      sleep 1
    done
    if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
      err "Демон Docker недоступен"; exit 1
    fi
  fi
  warn "Использую: ${DOCKER[*]}"
fi

mkdir -p data logs

info "Сборка образа"
"${DOCKER[@]}" compose build
info "Запуск контейнера"
"${DOCKER[@]}" compose up -d

info "myservis запущен"
info "Дальше: bash scripts/04_info.sh и bash scripts/05_check.sh"
EOF_S03
)
write_file "$PROJECT_DIR/scripts/03_build_and_up.sh" 755 "$S03"

# -----------------------------------------------------------------------------
# Скрипт 04_info.sh
# -----------------------------------------------------------------------------
S04=$(cat <<'EOF_S04'
#!/usr/bin/env bash
# 04_info.sh — сводная информация о проекте и сервисе.
# Запуск: bash scripts/04_info.sh
set -euo pipefail

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
DB_FILE="$PROJECT_DIR/data/metrics.db"
LOG_FILE="$PROJECT_DIR/logs/myservis.log"
PORT="${MYSERVIS_PORT:-8080}"

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

count_rows() {
  local n=""
  if [[ -f "$DB_FILE" ]] && command -v sqlite3 >/dev/null 2>&1; then
    n="$(sqlite3 -readonly "$DB_FILE" 'SELECT COUNT(*) FROM disk_stats;' 2>/dev/null || true)"
  elif "${DOCKER[@]}" inspect myservis >/dev/null 2>&1; then
    n="$("${DOCKER[@]}" exec myservis python -c \
      "import sqlite3; print(sqlite3.connect('/app/data/metrics.db').execute('SELECT COUNT(*) FROM disk_stats').fetchone()[0])" \
      2>/dev/null || true)"
  fi
  echo "${n:-0}"
}

info "Проект: $PROJECT_DIR"
info "БД: $DB_FILE"
info "Лог: $LOG_FILE"

info "Статус контейнера:"
if ! "${DOCKER[@]}" compose ps; then
  warn "Не удалось получить статус (docker недоступен?)"
fi

info "Последние 10 строк лога:"
if [[ -s "$LOG_FILE" ]]; then
  tail -n 10 "$LOG_FILE"
else
  warn "Лог пока пуст или отсутствует"
fi

info "Записей в disk_stats: $(count_rows)"
info "URL: http://localhost:${PORT}"
EOF_S04
)
write_file "$PROJECT_DIR/scripts/04_info.sh" 755 "$S04"

# -----------------------------------------------------------------------------
# Скрипт 05_check.sh
# -----------------------------------------------------------------------------
S05=$(cat <<'EOF_S05'
#!/usr/bin/env bash
# 05_check.sh — итоговая проверка. При успехе печатает OK и возвращает 0, иначе 1.
# Запуск: bash scripts/05_check.sh
set -euo pipefail

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
DB_FILE="$PROJECT_DIR/data/metrics.db"
LOG_FILE="$PROJECT_DIR/logs/myservis.log"
PORT="${MYSERVIS_PORT:-8080}"
URL="http://localhost:${PORT}/"

if ! command -v curl >/dev/null 2>&1; then
  err "Не найден curl. Сначала: sudo bash scripts/01_prepare.sh"; exit 1
fi

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

container_state() {
  "${DOCKER[@]}" inspect -f '{{.State.Status}}' myservis 2>/dev/null || echo "нет"
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true
}

count_rows() {
  local n=""
  if [[ -f "$DB_FILE" ]] && command -v sqlite3 >/dev/null 2>&1; then
    n="$(sqlite3 -readonly "$DB_FILE" 'SELECT COUNT(*) FROM disk_stats;' 2>/dev/null || true)"
  else
    n="$("${DOCKER[@]}" exec myservis python -c \
      "import sqlite3; print(sqlite3.connect('/app/data/metrics.db').execute('SELECT COUNT(*) FROM disk_stats').fetchone()[0])" \
      2>/dev/null || true)"
  fi
  echo "${n:-0}"
}

info "Ожидание запуска сервиса (до 10 с)"
state="нет"; code="000"; rows=0
for _ in $(seq 1 10); do
  state="$(container_state)"
  code="$(http_code)"; code="${code:-000}"
  rows="$(count_rows)"
  if [[ "$state" == "running" && "$code" == "200" && "$rows" -ge 1 ]]; then
    break
  fi
  sleep 1
done

if [[ -s "$LOG_FILE" ]]; then log_state="не пуст"; log_ok=1; else log_state="пуст"; log_ok=0; fi

info "Контейнер: ${state}; HTTP: ${code}; записей БД: ${rows}; лог: ${log_state}"

fail=0
[[ "$state" == "running" ]] || { err "Контейнер myservis не в состоянии running"; fail=1; }
[[ "$code" == "200" ]]      || { err "GET $URL вернул HTTP ${code}, ожидался 200"; fail=1; }
[[ "$rows" -ge 1 ]]         || { err "В таблице disk_stats нет записей"; fail=1; }
[[ "$log_ok" -eq 1 ]]       || { err "Лог $LOG_FILE пуст или отсутствует"; fail=1; }

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "OK"
EOF_S05
)
write_file "$PROJECT_DIR/scripts/05_check.sh" 755 "$S05"

# -----------------------------------------------------------------------------
# README.md
# -----------------------------------------------------------------------------
README_MD=$(cat <<'EOF_README'
# myservis — мониторинг свободного места на диске

Небольшой веб-сервис на Python (Flask) и SQLite, который запускается в Docker Compose.
Раз в несколько секунд он снимает метрики корневой файловой системы (`total`, `used`,
`free`, `percent`), сохраняет их в БД, пишет лог и показывает всё на веб-странице.

## Структура

```
/opt/myservis/
├── app/                  # исходники и образ
│   ├── main.py
│   ├── config.yaml
│   ├── requirements.txt
│   └── Dockerfile
├── data/                 # SQLite: metrics.db (том ./data:/app/data)
├── logs/                 # myservis.log   (том ./logs:/app/logs)
├── docker-compose.yml
├── scripts/              # скрипты развёртывания 01–05
└── README.md
```

## Быстрый старт (Ubuntu 22.04 в WSL2 или VM)

```bash
sudo bash generate_project.sh          # создаёт проект в /opt/myservis
cd /opt/myservis
sudo bash scripts/01_prepare.sh        # Docker Engine + Compose v2, группа docker
sudo bash scripts/02_create_structure.sh
sudo bash scripts/03_build_and_up.sh   # сборка образа и запуск контейнера
bash scripts/04_info.sh                # сводка: пути, статус, лог, число записей, URL
bash scripts/05_check.sh               # должен напечатать OK
```

После этого страница доступна по адресу <http://localhost:8080>.

Если после `01_prepare.sh` команды `docker` без `sudo` не работают — перезайдите в сессию
или выполните `newgrp docker`. Скрипты 03–05 при отсутствии доступа сами используют `sudo docker`.

## Скрипты

| Скрипт | Что делает |
|---|---|
| `01_prepare.sh` | проверяет окружение, ставит Docker Engine и Compose v2 (если их нет), добавляет пользователя в группу `docker`, запускает демон |
| `02_create_structure.sh` | создаёт каталоги и недостающие файлы, проверяет `main.py` |
| `03_build_and_up.sh` | `docker compose build` и `docker compose up -d` |
| `04_info.sh` | пути, статус контейнера, последние 10 строк лога, число записей, URL |
| `05_check.sh` | контейнер `running`, HTTP 200, записи в БД, непустой лог → `OK` / код 1 |

Все скрипты идемпотентны: их можно запускать повторно.

## Эндпоинты

| Маршрут | Ответ |
|---|---|
| `GET /` | HTML-страница: текущие метрики и последние 20 записей |
| `GET /api/current` | JSON с текущими метриками |
| `GET /api/history?limit=N` | JSON с историей (по умолчанию 100, максимум 1000, сначала новые) |

```bash
curl -s http://localhost:8080/api/current
curl -s "http://localhost:8080/api/history?limit=5"
```

## Настройки (`app/config.yaml`)

| Параметр | По умолчанию | Описание |
|---|---|---|
| `interval_sec` | 5 | период сбора метрик, секунд |
| `threshold_percent` | 90 | при превышении в лог пишется `WARNING` |
| `db_path` | `data/metrics.db` | файл SQLite |
| `log_path` | `logs/myservis.log` | файл лога |
| `port` | 8080 | порт веб-сервера |

После изменения конфигурации пересоберите контейнер: `docker compose up -d --build`.

## Полезные команды

```bash
docker compose ps                                  # статус
docker compose logs -f myservis                    # логи контейнера
docker compose down                                # остановить и удалить контейнер
docker compose up -d --build                       # пересобрать и поднять
sqlite3 data/metrics.db "SELECT COUNT(*) FROM disk_stats;"
tail -n 20 logs/myservis.log
ss -tlnp | grep 8080                               # кто слушает порт
```

## Типичные проблемы

| Симптом | Решение |
|---|---|
| `System has not been booted with systemd` | в WSL2 без systemd демон запускается командой `sudo service docker start` (скрипты 01 и 03 делают это сами) |
| `permission denied` при `docker ...` | перезайдите в сессию, `newgrp docker`, либо используйте `sudo docker` |
| `HTTP 000` в `05_check.sh` | сервис ещё стартует; подождите несколько секунд и запустите проверку снова |
| порт 8080 занят | остановите другой процесс (`ss -tlnp \| grep 8080`) |
| на VM не открывается `localhost:8080` | настройте проброс порта 8080 в параметрах сети VM |

Данные (`data/`) и логи (`logs/`) лежат в томах на хосте, поэтому переживают пересборку образа.

---

Автор: Якубко В. Ю., группа 4б-090207.
EOF_README
)
write_file "$PROJECT_DIR/README.md" 644 "$README_MD"

# -----------------------------------------------------------------------------
# Права и владелец
# -----------------------------------------------------------------------------
chmod 755 "$PROJECT_DIR/data" "$PROJECT_DIR/logs"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$PROJECT_DIR"
fi

info "Проект создан: $PROJECT_DIR"
info "Следующий шаг: cd $PROJECT_DIR && sudo bash scripts/01_prepare.sh"
