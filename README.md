CCC — Create Convex CLI (Dokploy bootstrap)

Overview
- This CLI bootstraps a Dokploy project, creates a Compose app from your docker-compose file, optionally provisions Postgres, wires domains with LetsEncrypt, and pushes environment variables.
- Auth uses Dokploy UI API with `x-api-key`.

Prerequisites (Ubuntu)
- Install required tools:
  - `sudo apt update && sudo apt install -y jq curl`
- You need a Dokploy API token (Settings → API Key in Dokploy UI).

Installation

Option A: Installer (recommended)
1) Make the installer executable
   - `chmod +x install_ccc.sh`
2) Run and choose scope (all users or current user)
   - `./install_ccc.sh`
   - Or force scope:
     - Global: `./install_ccc.sh --global`
     - User:   `./install_ccc.sh --user`
3) Verify
   - `which ccc`
   - `ccc --help`

Option B: Manual
- Global (all users):
  - `sudo install -m 0755 dokploy_bootstrap_script_postgres.sh /usr/local/bin/ccc`
- User-only:
  - `mkdir -p ~/.local/bin && install -m 0755 dokploy_bootstrap_script_postgres.sh ~/.local/bin/ccc`
  - Ensure `~/.local/bin` is in your `PATH`.

Usage
- Minimal (interactive prompts):
  - `ccc`
- Non-interactive example:
  - `TOKEN=... PROJECT_NAME=myproj APP_NAME=myapp ccc`
- With Postgres and dashboard domain:
  - `CREATE_PG=Y DEPLOY_PG_NOW=Y CREATE_DASH_DOMAIN=Y TOKEN=... PROJECT_NAME=myproj APP_NAME=myapp ccc`

Environment variables
- `TOKEN` (required): Dokploy API key (x-api-key header).
- `PROJECT_NAME`: Name for the project (prompted if missing).
- `APP_NAME`: Name for the compose app (prompted if missing).
- `ENV_NAME`: Environment name (default: `dev`).
- `COMPOSE_FILE`: Compose file (default: `docker-compose.yaml`).
- `CREATE_PG`: `y/N` to create Postgres (default `N`).
- `DEPLOY_PG_NOW`: `Y/n` to deploy Postgres now (needed to obtain connection string).
- `CREATE_DASH_DOMAIN`: `y/N` to create a dashboard domain.
- `ENV_FILE`: Extra env to merge into Compose env (default `.env`).
- `DRY_RUN`: `1` to print intended requests without calling the API.
- `NO_COLOR`: `1` to disable colored output.
- `S3_ENDPOINT_URL`, `AWS_S3_FORCE_PATH_STYLE`, `AWS_REGION`: S3 defaults.

What it does
1) Auth check with Dokploy (`x-api-key`).
2) Creates a project and captures the auto-created environment, renaming it to `ENV_NAME`.
3) Creates a Compose service from your compose file, sets `sourceType` to `raw` via `compose.update`.
4) Optionally creates Postgres (deploys immediately if you choose to fetch the connection string).
5) Writes environment variables to the Compose service.
6) Creates domains with correct ports and LetsEncrypt:
   - API (service `backend`) → port 3210
   - Actions (service `backend`) → port 3211
   - Dashboard (service `dashboard`, optional) → port 6791
7) Triggers a compose redeploy.
8) Prints final summary and a Dokploy dashboard URL:
   - `https://dokploy.giltine.com/dashboard/projects/<projectId>`

Notes
- If you answer “no” to “Deploy Postgres now?”, the connection string cannot be retrieved until deployment occurs. The script warns and skips adding it to the env until deployed.
- If you choose not to create a dashboard domain and a `docker-compose-dashless.yaml` exists, the script will use it automatically.

Troubleshooting
- Ensure you run `ccc` from the directory containing your compose file.
- Convert Windows line endings if needed: `sed -i 's/\r$//' dokploy_bootstrap_script_postgres.sh`
- If `ccc` is not found after user install, ensure `~/.local/bin` is in PATH:
  - `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && source ~/.profile`

