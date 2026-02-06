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
GIT_REPO="https://gitlab.com/ermaan/is" \
DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
./benchmark.sh
```

## Full app test flow
```bash
RUN_APP_TESTS=1 \
MYSQL_ONLY_FIRST=1 \
ENV_FILE="/path/to/.env" \
SQL_FILE="/path/to/is_sql.sql" \
LOGIN_EMAIL="user@example.com" \
LOGIN_PASSWORD="secret" \
API_BASE_URL="http://127.0.0.1:8081" \
GIT_REPO="IS REPO" \
DOCKER_BUILD_ARGS="--no-cache --pull --progress=plain" \
./benchmark.sh
```

## Outputs
- JSON results: `/root/bench_out/results_<host>_<timestamp>.json`
- `hey` output: `/root/bench_out/hey_<host>_<timestamp>.txt`
- Sample `/api/orders` response: `/root/bench_out/endp_sample_<host>_<timestamp>.json`

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
  DOCKER_BUILD_ARGS=\"--no-cache --pull --progress=plain\"\n+```

## Environment variables
- `GIT_REPO`, `GIT_BRANCH`
- `DOCKER_BUILD_CONTEXT`, `DOCKERFILE`, `DOCKER_BUILD_ARGS`
- `OUTDIR`, `WORKDIR`, `FIO_DIR`
- `RUN_APP_TESTS` (0/1)
- `MYSQL_ONLY_FIRST` (0/1) — start only `mysql` before import
- `ENV_FILE`, `SQL_FILE`
- `API_BASE_URL`, `LOGIN_EMAIL`, `LOGIN_PASSWORD`
- `HEY_REQUESTS`, `HEY_CONCURRENCY`, `HEY_TIMEOUT`, `HEY_VERBOSE`
- `LOG_SAMPLE_RESPONSE` (0/1)

## Notes
- The script removes `'throttle:60,1',` from `laravel/app/Http/Kernel.php` in the cloned repo before building.
- Compose file detection supports `compose.yml`, `docker-compose.yml`, and `.yaml` variants.
- `mysql` service name is assumed to be `mysql`.
