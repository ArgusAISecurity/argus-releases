#!/usr/bin/env bash
set -euo pipefail
umask 077

ROLE="${1:-}"
case "$ROLE" in node|compact|vulnerability-worker) ;; *) echo "Usage: install.sh {node|compact|vulnerability-worker}" >&2; exit 2;; esac

as_root=()
if (( EUID != 0 )); then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "This verified installer needs root privileges. Re-run the generated Argus command on a host with sudo, or run it as root." >&2
    exit 5
  fi
  as_root=(sudo)
fi

PLATFORM_URL="${ARGUS_PLATFORM_URL:-__ARGUS_PLATFORM_URL__}"
RELEASE_BASE="${ARGUS_RELEASE_BASE_URL:-__ARGUS_RELEASE_BASE_URL__}"
INSTALL_ROOT="${ARGUS_INSTALL_ROOT:-/opt/argus-customer}"
if [[ "$PLATFORM_URL" == __* || "$RELEASE_BASE" == __* ]]; then
  echo "This installer has not been configured for an Argus platform release." >&2; exit 2
fi

need_cpu=2; need_mem=4; need_disk=20
if [[ "$ROLE" == compact ]]; then need_cpu=4; need_mem=16; need_disk=60; fi
if [[ "$ROLE" == vulnerability-worker ]]; then need_cpu=4; need_mem=6; need_disk=60; fi
cpu="$(nproc)"; mem="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"; disk="$(df -BG --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9')"
if (( cpu < need_cpu || mem < need_mem || disk < need_disk )); then
  echo "Host does not meet the ${ROLE} baseline: need ${need_cpu} vCPU, ${need_mem} GiB usable RAM, ${need_disk} GiB free disk; found ${cpu}/${mem}/${disk}." >&2; exit 3
fi

if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Docker is not installed.
Install Docker Engine and the Docker Compose plugin using your distribution's signed package repository, then rerun this verified Argus installer.
Ubuntu/Kali operators can begin with: sudo apt-get update
Do not pipe a remote Docker installation script into sudo.
EOF
  exit 5
fi
docker_cli=(docker)
docker_compose=(docker compose)
docker_error=""
if ! docker_error="$(docker info 2>&1)"; then
  if grep -Eqi 'permission denied|access denied|connect: permission' <<<"$docker_error"; then
    if (( EUID != 0 )) && sudo -n docker info >/dev/null 2>&1; then
      docker_cli=(sudo -n docker)
      docker_compose=(sudo -n docker compose)
      echo "Docker is available through sudo; Argus will use that protected path for this installation." >&2
    else
      cat >&2 <<'EOF'
Docker is installed and running, but this operator cannot access its socket.
Use the portal-generated verified command, which executes the installer under sudo.
Adding an account to the docker group is an alternative only when locally approved; docker-group membership grants effectively root-equivalent privilege on this host.
EOF
      exit 5
    fi
  elif grep -Eqi 'cannot connect to the docker daemon|is the docker daemon running|connection refused|no such file or directory' <<<"$docker_error"; then
    cat >&2 <<'EOF'
Docker is installed, but the Docker service is unavailable.
Start it with: sudo systemctl enable --now docker
Then verify it with: sudo docker info
EOF
    exit 5
  else
    echo "Docker could not be inspected: $docker_error" >&2
    echo "Verify the service with: sudo docker info" >&2
    exit 5
  fi
fi
if ! "${docker_compose[@]}" version >/dev/null 2>&1; then
  echo "Docker is running, but the Docker Compose plugin is unavailable. Install docker-compose-plugin from your distribution's signed package repository, then rerun this installer." >&2
  exit 5
fi
"${as_root[@]}" install -d -m 0700 "$INSTALL_ROOT" "$INSTALL_ROOT/secrets" "$INSTALL_ROOT/data/node" "$INSTALL_ROOT/data/worker" "$INSTALL_ROOT/gvm"
"${as_root[@]}" chown -R "$(id -u):$(id -g)" "$INSTALL_ROOT"
"${as_root[@]}" chown -R 10001:10001 "$INSTALL_ROOT/secrets" "$INSTALL_ROOT/data"

curl -fsSLo "$INSTALL_ROOT/release.env" "$RELEASE_BASE/release.env"
curl -fsSLo "$INSTALL_ROOT/release.env.bundle.json" "$RELEASE_BASE/release.env.bundle.json"
if ! command -v cosign >/dev/null; then
  COSIGN_VERSION="v3.1.3"
  curl -fsSLo "$INSTALL_ROOT/cosign" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
  chmod 0755 "$INSTALL_ROOT/cosign"
  COSIGN="$INSTALL_ROOT/cosign"
else COSIGN="$(command -v cosign)"; fi
"$COSIGN" verify-blob --bundle "$INSTALL_ROOT/release.env.bundle.json" --certificate-identity-regexp '^https://github\.com/ArgusAISecurity/argus-releases/\.github/workflows/publish-release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' "$INSTALL_ROOT/release.env"
set -a; source "$INSTALL_ROOT/release.env"; set +a
for image in ARGUS_NODE_IMAGE ARGUS_VULNERABILITY_WORKER_IMAGE; do
  value="${!image:-}"; [[ "$value" == *@sha256:* ]] || { echo "$image must be digest pinned" >&2; exit 4; }
done

read -rsp "One-time deployment code: " bootstrap_code; echo
[[ -n "$bootstrap_code" ]] || { echo "A deployment code is required." >&2; exit 2; }
printf '%s' "$bootstrap_code" | "${as_root[@]}" install -o 10001 -g 10001 -m 0600 /dev/stdin "$INSTALL_ROOT/secrets/bootstrap"
unset bootstrap_code
printf 'ARGUS_PLATFORM_URL=%s\nARGUS_NODE_IMAGE=%s\nARGUS_VULNERABILITY_WORKER_IMAGE=%s\n' "$PLATFORM_URL" "$ARGUS_NODE_IMAGE" "$ARGUS_VULNERABILITY_WORKER_IMAGE" > "$INSTALL_ROOT/runtime.env"

compose_name=core.yml
if [[ "$ROLE" == compact ]]; then compose_name=compact.yml; fi
if [[ "$ROLE" == vulnerability-worker ]]; then compose_name=scanner.yml; fi
curl -fsSLo "$INSTALL_ROOT/compose.yml" "$RELEASE_BASE/$compose_name"

if [[ "$ROLE" != node ]]; then
  read -rsp "GVM admin password configured for this scanner: " gvm_password; echo
  [[ -n "$gvm_password" ]] || { echo "The GVM password is required." >&2; exit 2; }
  printf '%s' "$gvm_password" | "${as_root[@]}" install -o 10001 -g 10001 -m 0600 /dev/stdin "$INSTALL_ROOT/secrets/gvm_password"
  unset gvm_password
  [[ "${GVM_COMPOSE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "signed release lacks a GVM manifest digest" >&2; exit 4; }
  curl -fsSLo "$INSTALL_ROOT/gvm/compose.yml" "$GVM_COMPOSE_URL"
  printf '%s  %s\n' "$GVM_COMPOSE_SHA256" "$INSTALL_ROOT/gvm/compose.yml" | sha256sum -c -
  "${docker_compose[@]}" -p greenbone-community-edition -f "$INSTALL_ROOT/gvm/compose.yml" up -d
  gvmd_container=""
  gvmd_health=""
  for _ in $(seq 1 180); do
    gvmd_container="$("${docker_compose[@]}" -p greenbone-community-edition -f "$INSTALL_ROOT/gvm/compose.yml" ps -q gvmd)"
    if [[ -n "$gvmd_container" ]]; then
      gvmd_health="$("${docker_cli[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$gvmd_container")"
      [[ "$gvmd_health" == healthy ]] && break
    fi
    sleep 5
  done
  [[ "$gvmd_health" == healthy ]] || { echo "The GVM manager did not become healthy." >&2; exit 6; }
  "${docker_cli[@]}" cp "$INSTALL_ROOT/secrets/gvm_password" "$gvmd_container:/tmp/argus-gvm-password"
  "${docker_cli[@]}" exec -u 0 "$gvmd_container" sh -c 'chown gvmd:gvmd /tmp/argus-gvm-password && chmod 600 /tmp/argus-gvm-password'
  "${docker_cli[@]}" exec -u gvmd "$gvmd_container" sh -c 'pw=$(cat /tmp/argus-gvm-password); rm -f /tmp/argus-gvm-password; exec gvmd --user=admin --new-password="$pw"' >/dev/null
fi

"${docker_compose[@]}" --env-file "$INSTALL_ROOT/runtime.env" -f "$INSTALL_ROOT/compose.yml" up -d
echo "Argus ${ROLE} deployment started. The one-time code file is removed automatically after registration."
