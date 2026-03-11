#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

# Minimal VPS benchmark with progress logs (Debian)
# Usage:
#   sudo bash bench-min.sh
#   sudo GIT_REPO="https://github.com/user/repo.git" \
#        DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
#        bash bench-min.sh
#
# Optional app test flow (after docker build):
#   RUN_APP_TESTS=1 ENV_FILE=/path/.env SQL_FILE=/path/db.sql \
#   LOGIN_EMAIL="user@example.com" LOGIN_PASSWORD="secret" \
#   API_BASE_URL="http://127.0.0.1:8081" \
#   GIT_REPO="https://gitlab.com/xy" \
#   DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
#   bash bench-min.sh

GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-}"
DOCKER_BUILD_CONTEXT="${DOCKER_BUILD_CONTEXT:-.}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
DOCKER_BUILD_ARGS="${DOCKER_BUILD_ARGS:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
REPO_DIR_OVERRIDE="${REPO_DIR_OVERRIDE:-}"

# App test inputs (optional)
RUN_APP_TESTS="${RUN_APP_TESTS:-0}"
MYSQL_ONLY_FIRST="${MYSQL_ONLY_FIRST:-1}"
HEY_REQUESTS="${HEY_REQUESTS:-2000}"
HEY_CONCURRENCY="${HEY_CONCURRENCY:-10}"
HEY_TIMEOUT="${HEY_TIMEOUT:-20}"
HEY_VERBOSE="${HEY_VERBOSE:-0}"
LOG_SAMPLE_RESPONSE="${LOG_SAMPLE_RESPONSE:-0}"
ENV_FILE="${ENV_FILE:-}"
SQL_FILE="${SQL_FILE:-}"
API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:8081}"
LOGIN_EMAIL="${LOGIN_EMAIL:-}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-}"

OUTDIR="${OUTDIR:-/root/bench_out}"
WORKDIR="${WORKDIR:-/root/bench_work}"
FIO_DIR="${FIO_DIR:-/root/bench_io}"

FIO_RUNTIME="${FIO_RUNTIME:-30}"
FIO_SIZE="${FIO_SIZE:-2G}"
SYSBENCH_PRIME="${SYSBENCH_PRIME:-20000}"

mkdir -p "$OUTDIR" "$WORKDIR" "$FIO_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname)"
JSON="$OUTDIR/results_${HOST}_${TS}.json"
HEY_OUT_FILE="$OUTDIR/hey_${HOST}_${TS}.txt"
ENDP_SAMPLE_FILE="$OUTDIR/endp_sample_${HOST}_${TS}.json"
BENCH_LOG_FILE="${BENCH_LOG_FILE:-$OUTDIR/bench_${HOST}_${TS}.log}"

# Log all output to file while keeping console output
exec > >(tee -a "$BENCH_LOG_FILE") 2>&1

REPO_DIR=""
resolve_repo_dir() {
  if [[ -n "$REPO_DIR" ]]; then
    return
  fi
  if [[ -n "$REPO_DIR_OVERRIDE" ]]; then
    REPO_DIR="$REPO_DIR_OVERRIDE"
    return
  fi
  if [[ -d "$WORKDIR" ]]; then
    local newest
    newest="$(ls -td "$WORKDIR"/repo_* 2>/dev/null | head -n1 || true)"
    if [[ -n "$newest" && -d "$newest" ]]; then
      REPO_DIR="$newest"
    fi
  fi
}

# -----------------------
# helpers
# -----------------------
log()  { echo "[→] $*" >&2; }
ok()   { echo "[✓] $*" >&2; }
warn() { echo "[!] $*" >&2; }

num_or_null() {
  local x="${1:-}"
  x="${x/,/.}"
  [[ "$x" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && echo "$x" || echo "null"
}

# -----------------------
# setup (ALWAYS install docker)
# -----------------------
install_deps() {
  log "Installing dependencies (sysbench, fio, git, docker)"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null

  # Add Docker's official GPG key:
  apt install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  else
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  # Add the repository to Apt sources:
  if [[ "${ID:-}" == "ubuntu" ]]; then
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  else
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi

  apt update  
  apt-get install -y \
  sysbench \
  fio \
  jq \
  git \
  python3 \
  bc \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  >/dev/null

  if ! command -v hey >/dev/null 2>&1; then
    log "Installing hey"
    if ! apt-get install -y hey >/dev/null 2>&1; then
      local hey_ver="0.1.4"
      local hey_url="https://github.com/rakyll/hey/releases/download/v${hey_ver}/hey_linux_amd64"
      curl -fsSL "$hey_url" -o /usr/local/bin/hey
      chmod +x /usr/local/bin/hey
    fi
    ok "hey installed"
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true

  ok "Dependencies installed (docker ready)"
}

# -----------------------
# benchmarks
# -----------------------
cpu_eps() {
  log "CPU benchmark (single-core)"
  local out1 s
  out1="$(sysbench cpu --cpu-max-prime="$SYSBENCH_PRIME" --threads=1 run 2>/dev/null)"
  s="$(echo "$out1" | awk -F: '/events per second/ {gsub(/ /,"",$2); print $2}' | tail -n1)"
  s="$(num_or_null "$s")"
  ok "CPU single done"

  log "CPU benchmark (multi-core)"
  local outN m
  outN="$(sysbench cpu --cpu-max-prime="$SYSBENCH_PRIME" --threads="$(nproc)" run 2>/dev/null)"
  m="$(echo "$outN" | awk -F: '/events per second/ {gsub(/ /,"",$2); print $2}' | tail -n1)"
  m="$(num_or_null "$m")"
  ok "CPU multi done"

  echo "$s|$m"
}

cpu_mem_cycle() {
  local cpu_pair
  cpu_pair="$(cpu_eps)"
  cpu_single="${cpu_pair%%|*}"
  cpu_multi="${cpu_pair##*|}"
  mem="$(mem_mibs)"
}

median_of_three() {
  local a="$1" b="$2" c="$3"
  if (( $(echo "$a <= $b" | bc -l) )); then
    if (( $(echo "$b <= $c" | bc -l) )); then
      echo "$b"
    elif (( $(echo "$a <= $c" | bc -l) )); then
      echo "$c"
    else
      echo "$a"
    fi
  else
    if (( $(echo "$a <= $c" | bc -l) )); then
      echo "$a"
    elif (( $(echo "$b <= $c" | bc -l) )); then
      echo "$c"
    else
      echo "$b"
    fi
  fi
}

mem_mibs() {
  log "Memory benchmark"
  local out v
  out="$(sysbench memory run 2>/dev/null)"
  v="$(echo "$out" | awk -F'[()]' '/MiB transferred/ {print $2}' | awk '{print $1}' | tail -n1)"
  v="$(num_or_null "$v")"
  ok "Memory done"
  echo "$v"
}

disk_iops() {
  log "Disk benchmark (fio ~${FIO_RUNTIME}s)"
  local fio_json read_iops write_iops
  fio_json="$OUTDIR/fio_${HOST}_${TS}.json"

  fio --output-format=json --output="$fio_json" \
      --name=randrw_4k --directory="$FIO_DIR" \
      --ioengine=libaio --direct=1 --invalidate=1 \
      --rw=randrw --rwmixread=70 \
      --bs=4k --iodepth=32 --numjobs=4 \
      --size="$FIO_SIZE" --time_based=1 --runtime="$FIO_RUNTIME" --group_reporting \
      >/dev/null 2>&1

  read_iops="$(jq '[.jobs[].read.iops] | add' "$fio_json" 2>/dev/null || echo null)"
  write_iops="$(jq '[.jobs[].write.iops] | add' "$fio_json" 2>/dev/null || echo null)"
  ok "Disk done"
  echo "$read_iops|$write_iops"
}

docker_build_seconds() {
  [[ -z "$GIT_REPO" ]] && { warn "Docker build skipped (GIT_REPO not set)"; echo "null"; return; }

  local repodir ctx start end dur
  repodir="$WORKDIR/repo_${TS}"
  rm -rf "$repodir" || true

  log "Docker: cloning repo (verbose)"
  git clone --depth=1 "$GIT_REPO" "$repodir" 2>&1 | tee /dev/stderr >/dev/null
  ok "Repo cloned"

  if [[ -n "$GIT_BRANCH" ]]; then
    log "Docker: checkout $GIT_BRANCH"
    (cd "$repodir" && git checkout "$GIT_BRANCH") 2>&1 | tee /dev/stderr >/dev/null || true
    ok "Checkout done"
  fi

  local kernel_file
  kernel_file="$repodir/laravel/app/Http/Kernel.php"
  if [[ -f "$kernel_file" ]]; then
    sed -i "/'throttle:60,1',/d" "$kernel_file"
  fi

  ctx="$repodir/$DOCKER_BUILD_CONTEXT"
  [[ -d "$ctx" ]] || { warn "Build context not found: $ctx"; echo "null"; return; }
  REPO_DIR="$repodir"

  log "Docker: building image (verbose)"
  log "Docker args: $DOCKER_BUILD_ARGS"
  start="$(date +%s)"

  set +e
  docker build $DOCKER_BUILD_ARGS -t benchmark-app:latest -f "$ctx/$DOCKERFILE" "$ctx" 2>&1 | tee /dev/stderr >/dev/null
  local rc=${PIPESTATUS[0]}
  set -e

  end="$(date +%s)"
  dur=$((end - start))

  [[ $rc -ne 0 ]] && warn "Docker build FAILED (rc=$rc)"

  ok "Docker build finished (${dur}s)"
  echo "$dur"
}

# -----------------------
# app tests
# -----------------------
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  echo ""
}

resolve_compose_file() {
  if [[ -f "$REPO_DIR/$COMPOSE_FILE" ]]; then
    return
  fi
  local alt
  for alt in compose.yml docker-compose.yml docker-compose.yaml compose.yaml; do
    if [[ -f "$REPO_DIR/$alt" ]]; then
      COMPOSE_FILE="$alt"
      return
    fi
  done
}

copy_env() {
  [[ -z "$ENV_FILE" ]] && { warn "ENV_FILE not set; skipping .env copy"; return; }
  [[ -f "$ENV_FILE" ]] || { warn "ENV_FILE not found: $ENV_FILE"; return; }
  cp "$ENV_FILE" "$REPO_DIR/.env"
  ok ".env copied to repo"
}

load_env() {
  local env_path="$REPO_DIR/.env"
  [[ -f "$env_path" ]] || { warn "No .env in repo; skipping env load"; return; }
  set -a
  # shellcheck disable=SC1090
  source "$env_path"
  set +a
}

compose_up() {
  local cbin
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || { warn "docker compose not available"; return 1; }
  resolve_compose_file
  [[ -f "$REPO_DIR/$COMPOSE_FILE" ]] || { warn "Compose file not found: $REPO_DIR/$COMPOSE_FILE"; return 1; }

  log "Starting docker compose"
  pushd "$REPO_DIR" >/dev/null
  $cbin -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" up -d --no-build
  popd >/dev/null
  ok "Compose up"
}

compose_up_mysql() {
  local cbin
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || { warn "docker compose not available"; return 1; }
  resolve_compose_file
  [[ -f "$REPO_DIR/$COMPOSE_FILE" ]] || { warn "Compose file not found: $REPO_DIR/$COMPOSE_FILE"; return 1; }

  log "Starting mysql only"
  pushd "$REPO_DIR" >/dev/null
  $cbin -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" up -d mysql
  popd >/dev/null
  ok "MySQL up"
}

compose_down() {
  local cbin
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || { warn "docker compose not available"; return 1; }
  resolve_compose_file
  [[ -f "$REPO_DIR/$COMPOSE_FILE" ]] || { warn "Compose file not found: $REPO_DIR/$COMPOSE_FILE"; return 1; }

  log "Stopping docker compose"
  pushd "$REPO_DIR" >/dev/null
  $cbin -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" down
  popd >/dev/null
  ok "Compose down"
}

wait_for_mysql() {
  local cbin tries=60
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || return 1
  resolve_compose_file

  DB_USER="${DB_USERNAME:-}"
  DB_PASS="${DB_PASSWORD:-}"
  [[ -n "$DB_USER" && -n "$DB_PASS" ]] || { warn "DB creds missing from .env"; return 1; }

  log "Waiting for MySQL to be ready"
  for _ in $(seq 1 "$tries"); do
    if $cbin -f "$REPO_DIR/$COMPOSE_FILE" --project-directory "$REPO_DIR" exec -T mysql \
      mysqladmin ping -u"$DB_USER" -p"$DB_PASS" --silent >/dev/null 2>&1; then
      ok "MySQL ready"
      return 0
    fi
    sleep 2
  done
  warn "MySQL not ready after $((tries * 2))s"
  return 1
}

check_db_access() {
  DB_USER="${DB_USERNAME:-}"
  DB_PASS="${DB_PASSWORD:-}"
  DB_NAME="${DB_DATABASE:-}"
  [[ -n "$DB_USER" && -n "$DB_PASS" && -n "$DB_NAME" ]] || { warn "DB creds missing from .env"; return 1; }

  local cbin
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || return 1
  resolve_compose_file

  if ! $cbin -f "$REPO_DIR/$COMPOSE_FILE" --project-directory "$REPO_DIR" exec -T mysql \
    mysql -u"$DB_USER" -p"$DB_PASS" -e "USE \`$DB_NAME\`; SELECT 1;" >/dev/null 2>&1; then
    warn "DB not accessible (missing DB or insufficient privileges)"
    return 1
  fi
  ok "DB accessible"
  return 0
}

wait_for_db() {
  local tries=60
  log "Waiting for DB to exist and be accessible"
  for _ in $(seq 1 "$tries"); do
    if check_db_access >/dev/null 2>&1; then
      ok "DB ready"
      return 0
    fi
    sleep 2
  done
  warn "DB not accessible after $((tries * 2))s"
  return 1
}

import_sql() {
  [[ -z "$SQL_FILE" ]] && { warn "SQL_FILE not set; skipping import"; return; }
  [[ -f "$SQL_FILE" ]] || { warn "SQL file not found: $SQL_FILE"; return; }
  DB_USER="${DB_USERNAME:-}"
  DB_PASS="${DB_PASSWORD:-}"
  DB_NAME="${DB_DATABASE:-}"
  [[ -n "$DB_NAME" ]] || { warn "DB_DATABASE missing from .env"; return; }

  local cbin
  cbin="$(compose_cmd)"
  [[ -n "$cbin" ]] || return 1
  resolve_compose_file

  wait_for_db || return 1

  log "Importing SQL into MySQL"
  if ! $cbin -f "$REPO_DIR/$COMPOSE_FILE" --project-directory "$REPO_DIR" exec -T mysql \
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"; then
    warn "SQL import failed (check DB creds or existing volume)"
    return 1
  fi
  ok "SQL import done"
}

wait_for_http() {
  local url="$1" tries=60
  echo "[→] Waiting for app to be ready: $url" >&2
  for _ in $(seq 1 "$tries"); do
    if curl -sS -o /dev/null -w "%{http_code}" "$url" | grep -qE '^(200|401|403|404)$'; then
      echo "[✓] App reachable" >&2
      return 0
    fi
    sleep 2
  done
  echo "[!] App not reachable after $((tries * 2))s" >&2
  return 1
}

api_login() {
  [[ -n "$LOGIN_EMAIL" && -n "$LOGIN_PASSWORD" ]] || { echo "[!] LOGIN_EMAIL/LOGIN_PASSWORD not set; skipping login" >&2; return 1; }

  local resp token payload tries=10
  payload="$(jq -n --arg email "$LOGIN_EMAIL" --arg password "$LOGIN_PASSWORD" \
    '{email:$email,password:$password}')"

  wait_for_http "$API_BASE_URL/api/login" >&2 || true

  for _ in $(seq 1 "$tries"); do
    resp="$(curl -sS "$API_BASE_URL/api/login" \
      -H 'Accept: application/json, text/plain, */*' \
      -H 'Content-Type: application/json;charset=UTF-8' \
      --data-raw "$payload")"

    token="$(echo "$resp" | jq -r '.access_token // empty')"
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
    sleep 2
  done

  echo "[!] Login failed or token missing after ${tries} attempts" >&2
  echo "$resp" >&2
  return 1
}

web_tests() {
  local token="$1"
  local tmp_times tmp_codes out code t token_q
  tmp_times="$(mktemp)"
  tmp_codes="$(mktemp)"

  token_q="$(jq -rn --arg t "$token" '$t|@uri')"
  local base_orders="$API_BASE_URL/api/orders"
  local good_url="${base_orders}?status=new&page=1&per_page=100&token=${token_q}"

  echo "[→] Web tests on /api/orders (hey)" >&2

  if [[ "$LOG_SAMPLE_RESPONSE" == "1" ]]; then
    curl -sS -H 'Accept: application/json, text/plain, */*' "$good_url" >"$ENDP_SAMPLE_FILE" || true
    echo "[→] Saved sample response: $ENDP_SAMPLE_FILE" >&2
  fi

  if command -v hey >/dev/null 2>&1; then
    local hey_out avg p95 ok total count fastest slowest total_time
    hey_out="$(mktemp)"
    if [[ "$HEY_VERBOSE" == "1" ]]; then
      hey -n "$HEY_REQUESTS" -c "$HEY_CONCURRENCY" -t "$HEY_TIMEOUT" \
        -H 'Accept: application/json, text/plain, */*' \
        "$good_url" | tee "$hey_out" >&2
    else
      hey -n "$HEY_REQUESTS" -c "$HEY_CONCURRENCY" -t "$HEY_TIMEOUT" \
        -H 'Accept: application/json, text/plain, */*' \
        "$good_url" >"$hey_out" 2>&1
    fi

    avg="$(awk '/Average:/ {print $2; exit}' "$hey_out")"
    fastest="$(awk '/Fastest:/ {print $2; exit}' "$hey_out")"
    slowest="$(awk '/Slowest:/ {print $2; exit}' "$hey_out")"
    total_time="$(awk '/Total:/ {print $2; exit}' "$hey_out")"
    p95="$(awk '/^  95% in/ {print $3; exit}' "$hey_out")"
    ok="$(awk '
      /Status code distribution:/ {flag=1; next}
      flag && $1 ~ /^\\[[0-9]+\\]$/ {
        code=$1; gsub(/\\[|\\]/,"",code);
        cnt=$2+0;
        if (code==200 || code==201 || code==204) ok+=cnt;
        total+=cnt
      }
      END {print ok+0}
    ' "$hey_out")"
    total="$(awk '
      /Status code distribution:/ {flag=1; next}
      flag && $1 ~ /^\\[[0-9]+\\]$/ { total+=$2 }
      END {print total+0}
    ' "$hey_out")"

    count="$HEY_REQUESTS"
    [[ -n "$avg" ]] || avg="0"
    [[ -n "$p95" ]] || p95="0"

    cp "$hey_out" "$HEY_OUT_FILE"

    [[ -n "$fastest" ]] || fastest="0"
    [[ -n "$slowest" ]] || slowest="0"
    [[ -n "$total_time" ]] || total_time="0"

    echo "[✓] Web tests done" >&2
    echo "$count|$avg|$p95|$fastest|$slowest|$total_time"
    rm -f "$hey_out" "$tmp_times" "$tmp_codes"
    return
  fi

  echo "[!] hey not found; falling back to curl tests" >&2
  # Warmup
  for _ in 1 2 3; do
    curl -sS -o /dev/null -w "%{http_code} %{time_total}\n" "$good_url" >>"$tmp_codes"
  done

  # Main sample
  for _ in $(seq 1 20); do
    out="$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" "$good_url")"
    read -r code t <<<"$out"
    echo "$t" >>"$tmp_times"
    echo "$code" >>"$tmp_codes"
  done

  # Negative cases
  curl -sS -o /dev/null -w "%{http_code}\n" "${base_orders}?status=new&page=1&per_page=100" >>"$tmp_codes"
  curl -sS -o /dev/null -w "%{http_code}\n" "${base_orders}?status=new&page=1&per_page=100&token=invalid" >>"$tmp_codes"

  local count avg p95 errors
  count="$(wc -l <"$tmp_times" | tr -d ' ')"
  avg="$(awk '{s+=$1} END{if(NR>0) printf "%.4f", s/NR; else print "0"}' "$tmp_times")"
  p95="$(sort -n "$tmp_times" | awk '{a[NR]=$1} END{n=NR; if(n==0){print "0"; exit} idx=int(n*0.95+0.999); print a[idx]}')"
  errors="$(grep -vE '^(200|201|204)$' "$tmp_codes" | wc -l | tr -d ' ')"

  echo "[✓] Web tests done" >&2
  echo "$count|$avg|$p95|0|0|0"
  rm -f "$tmp_times" "$tmp_codes"
}

# -----------------------
# main
# -----------------------
main() {
  install_deps

  local cpu_pair cpu_single cpu_multi mem disk_pair disk_r disk_w dsecs
  cpu_single="null"
  cpu_multi="null"
  mem="null"
  disk_r="null"
  disk_w="null"
  dsecs="null"

  local cpu_single_1 cpu_multi_1 mem_1
  local cpu_single_2 cpu_multi_2 mem_2
  local cpu_single_3 cpu_multi_3 mem_3

  cpu_mem_cycle
  cpu_single_1="$cpu_single"
  cpu_multi_1="$cpu_multi"
  mem_1="$mem"

  disk_pair="$(disk_iops)"
  disk_r="${disk_pair%%|*}"
  disk_w="${disk_pair##*|}"

  cpu_mem_cycle
  cpu_single_2="$cpu_single"
  cpu_multi_2="$cpu_multi"
  mem_2="$mem"

  dsecs="$(docker_build_seconds)"

  local web_pair web_count web_avg web_p95 web_fastest web_slowest web_total
  web_count="0"
  web_avg="0"
  web_p95="0"
  web_fastest="0"
  web_slowest="0"
  web_total="0"

  if [[ "$RUN_APP_TESTS" == "1" ]]; then
    resolve_repo_dir
    if [[ -z "$REPO_DIR" ]]; then
      warn "Repo dir unknown; app tests skipped"
    else
      copy_env
      load_env
      if [[ "$MYSQL_ONLY_FIRST" == "1" ]]; then
        compose_up_mysql || true
      else
        compose_up || true
      fi
      wait_for_mysql || true
      import_sql || true

      if [[ "$MYSQL_ONLY_FIRST" == "1" ]]; then
        compose_up || true
      fi

      local token
      token="$(api_login 2>/dev/null || true)"
      if [[ -n "$token" ]]; then
        web_pair="$(web_tests "$token" | tail -n1)"
        web_count="${web_pair%%|*}"
        web_avg="$(echo "$web_pair" | cut -d'|' -f2)"
        web_p95="$(echo "$web_pair" | cut -d'|' -f3)"
        web_fastest="$(echo "$web_pair" | cut -d'|' -f4)"
        web_slowest="$(echo "$web_pair" | cut -d'|' -f5)"
        web_total="$(echo "$web_pair" | cut -d'|' -f6)"
      else
        warn "JWT token not obtained; skipping /api/orders tests"
      fi

      compose_down || true
    fi
  fi

  cpu_mem_cycle
  cpu_single_3="$cpu_single"
  cpu_multi_3="$cpu_multi"
  mem_3="$mem"

  cpu_single="$(median_of_three "$cpu_single_1" "$cpu_single_2" "$cpu_single_3")"
  cpu_multi="$(median_of_three "$cpu_multi_1" "$cpu_multi_2" "$cpu_multi_3")"
  mem="$(median_of_three "$mem_1" "$mem_2" "$mem_3")"

  cat >"$JSON" <<EOF
{
  "host": "$HOST",
  "timestamp_utc": "$TS",
  "cpu_single_eps": $cpu_single,
  "cpu_multi_eps": $cpu_multi,
  "ram_mib_s": $mem,
  "disk_read_iops": $disk_r,
  "disk_write_iops": $disk_w,
  "docker_build_seconds": $dsecs,
  "web_test_count": $web_count,
  "web_test_avg_seconds": $web_avg,
  "web_test_p95_seconds": $web_p95,
  "web_test_fastest_seconds": $web_fastest,
  "web_test_slowest_seconds": $web_slowest,
  "web_test_total_seconds": $web_total,
  "web_test_hey_output": "$HEY_OUT_FILE"
}
EOF

  echo
  ok "Benchmark finished"
  echo "Results:"
  echo "  CPU single EPS : $cpu_single"
  echo "  CPU multi  EPS : $cpu_multi"
  echo "  RAM MiB/s      : $mem"
  echo "  Disk IOPS R/W  : $disk_r / $disk_w"
  echo "  Docker build s : $dsecs"
  echo
  echo "Saved to: $JSON"
}

main "$@"
