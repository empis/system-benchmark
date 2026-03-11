# system-benchmark

Minimal VPS benchmark script with optional Docker app build + API tests.

## What it does
- CPU (single + multi), RAM, disk IO benchmarks
- Docker image build timing from a git repo
- Optional app test flow:
  - copy .env into repo
  - start MySQL first (optional)
  - import SQL dump
  - start all services
  - login to API, run `/api/orders` load test with `hey`
  - save `hey` output + one sample API response
  - `docker compose down` at the end

## Requirements
- Debian-based system (uses `apt`)
- Root or sudo access (installs packages, manages Docker)

## Basic usage
```bash
GIT_REPO="https://gitlab.com/xy" \
DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
./benchmark.sh
```

## Full app test flow
```bash
RUN_APP_TESTS=1 \
MYSQL_ONLY_FIRST=1 \
ENV_FILE="/path/to/.env" \
SQL_FILE="/path/to/sql.sql" \
LOGIN_EMAIL="user@example.com" \
LOGIN_PASSWORD="secret" \
API_BASE_URL="http://127.0.0.1:8081" \
GIT_REPO="BENCH REPO" \
DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
./benchmark.sh
```

## Outputs
- JSON results: `/root/bench_out/results_<host>_<timestamp>.json`
- `hey` output: `/root/bench_out/hey_<host>_<timestamp>.txt`

## Ansible runner
Run everything on a remote host and fetch results to `results/<hostname>`.

Example:
```bash
./run-local.sh benchmark ip=1.2.3.4 \\
  RUN_APP_TESTS=1 \\
  ENV_FILE=\".env\" \\
  SQL_FILE=\"app.sql\" \\
  LOGIN_EMAIL=\"test\" \\
  LOGIN_PASSWORD=\"test\" \\
  GIT_REPO=\"repo_url\" \\
  SSH_KEY_FILE=\"~/.ssh/id_ed25519\" \\
  DOCKER_BUILD_ARGS=\"--no-cache --pull --progress=plain\"
```

## Environment variables
- `GIT_REPO`, `GIT_BRANCH`
- `DOCKER_BUILD_CONTEXT`, `DOCKERFILE`, `DOCKER_BUILD_ARGS`
- `OUTDIR`, `WORKDIR`, `FIO_DIR`
- `RUN_APP_TESTS` (0/1)
- `MYSQL_ONLY_FIRST` (0/1) — start only `mysql` before import
- `ENV_FILE`, `SQL_FILE`
- `API_BASE_URL`, `LOGIN_EMAIL`, `LOGIN_PASSWORD`
- `HEY_REQUESTS`, `HEY_CONCURRENCY`, `HEY_TIMEOUT`, `HEY_VERBOSE`

## Notes
- The script removes `'throttle:60,1',` from `laravel/app/Http/Kernel.php` in the cloned repo before building.
- Compose file detection supports `compose.yml`, `docker-compose.yml`, and `.yaml` variants.
- `mysql` service name is assumed to be `mysql`.

## Odoo benchmark (Ansible)
This uses `odoo-playbook.yml` via `run-local.sh` and runs:
- Docker install + Odoo deploy
- `hey` load test on `/shop` (raw output only)
- Locust load test with CSV + HTML report
- `docker compose down`

### Required archives and names
Place these files **under `odoo/`** in this repo:
- `odoo/odoo_bundle.tar.gz` — the Odoo project **root** (docker-compose, configs, scripts, locustfile, etc.)
- `odoo/data.tar.gz` — **backup data**, must contain `filestore/` and `postgres/`

### How to build the archives
1. **Odoo bundle** (project root):
```bash
# from repo root
tar -czf odoo/odoo_bundle.tar.gz -C odoo .
```
If you want to exclude an existing `data/` folder from the bundle:
```bash
tar -czf odoo/odoo_bundle.tar.gz -C odoo . --exclude=./data --exclude=./data.tar.gz
```

2. **Data backup** (filestore + postgres):
```bash
# adjust the source path to where your Odoo data lives
tar -czf odoo/data.tar.gz -C /path/to/odoo/data filestore postgres
```

The playbook expects these **exact names**: `odoo_bundle.tar.gz` and `data.tar.gz`.

### Run
```bash
./run-local.sh odoo ip=1.2.3.4
```

### Outputs
Stored locally under `results/<hostname>/`:
- `odoo_hey_raw_<timestamp>.txt`
- `odoo_locust_stats_<timestamp>.csv`
- `odoo_locust_failures_<timestamp>.csv`
- `odoo_locust_report_<timestamp>.html` and `odoo_locust_report.html`
