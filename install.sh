#!/usr/bin/env bash
set -euo pipefail
umask 077

ROLE="${1:-}"
case "$ROLE" in node|compact|vulnerability-worker) ;; *) echo "Usage: install.sh {node|compact|vulnerability-worker}" >&2; exit 2;; esac

PLATFORM_URL="${ARGUS_PLATFORM_URL:-__ARGUS_PLATFORM_URL__}"
RELEASE_BASE="${ARGUS_RELEASE_BASE_URL:-__ARGUS_RELEASE_BASE_URL__}"
INSTALL_ROOT="${ARGUS_INSTALL_ROOT:-/opt/argus-customer}"
if [[ "$PLATFORM_URL" == __* || "$RELEASE_BASE" == __* ]]; then
  echo "This installer has not been configured for an Argus platform release." >&2; exit 2
fi

need_cpu=2; need_mem=4; need_disk=20
if [[ "$ROLE" == compact ]]; then need_cpu=4; need_mem=16; need_disk=60; fi
if [[ "$ROLE" == vulnerability-worker ]]; then need_cpu=4; need_mem=8; need_disk=60; fi
cpu="$(nproc)"; mem="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"; disk="$(df -BG --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9')"
if (( cpu < need_cpu || mem < need_mem || disk < need_disk )); then
  echo "Host does not meet the ${ROLE} baseline: need ${need_cpu} vCPU, ${need_mem} GiB RAM, ${need_disk} GiB free disk; found ${cpu}/${mem}/${disk}." >&2; exit 3
fi

if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | sudo sh; fi
sudo install -d -m 0700 "$INSTALL_ROOT" "$INSTALL_ROOT/secrets" "$INSTALL_ROOT/data/node" "$INSTALL_ROOT/data/worker" "$INSTALL_ROOT/gvm"
sudo chown -R "$(id -u):$(id -g)" "$INSTALL_ROOT"
sudo chown -R 10001:10001 "$INSTALL_ROOT/secrets" "$INSTALL_ROOT/data"

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
printf '%s' "$bootstrap_code" | sudo install -o 10001 -g 10001 -m 0600 /dev/stdin "$INSTALL_ROOT/secrets/bootstrap"
unset bootstrap_code
printf 'ARGUS_PLATFORM_URL=%s\nARGUS_NODE_IMAGE=%s\nARGUS_VULNERABILITY_WORKER_IMAGE=%s\n' "$PLATFORM_URL" "$ARGUS_NODE_IMAGE" "$ARGUS_VULNERABILITY_WORKER_IMAGE" > "$INSTALL_ROOT/runtime.env"

compose_name=core.yml
if [[ "$ROLE" == compact ]]; then compose_name=compact.yml; fi
if [[ "$ROLE" == vulnerability-worker ]]; then compose_name=scanner.yml; fi
curl -fsSLo "$INSTALL_ROOT/compose.yml" "$RELEASE_BASE/$compose_name"

if [[ "$ROLE" != node ]]; then
  read -rsp "GVM admin password configured for this scanner: " gvm_password; echo
  [[ -n "$gvm_password" ]] || { echo "The GVM password is required." >&2; exit 2; }
  printf '%s' "$gvm_password" | sudo install -o 10001 -g 10001 -m 0600 /dev/stdin "$INSTALL_ROOT/secrets/gvm_password"
  unset gvm_password
  [[ "${GVM_COMPOSE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "signed release lacks a GVM manifest digest" >&2; exit 4; }
  curl -fsSLo "$INSTALL_ROOT/gvm/compose.yml" "$GVM_COMPOSE_URL"
  printf '%s  %s\n' "$GVM_COMPOSE_SHA256" "$INSTALL_ROOT/gvm/compose.yml" | sha256sum -c -
  docker compose -p greenbone-community-edition -f "$INSTALL_ROOT/gvm/compose.yml" up -d
fi

docker compose --env-file "$INSTALL_ROOT/runtime.env" -f "$INSTALL_ROOT/compose.yml" up -d
echo "Argus ${ROLE} deployment started. The one-time code file is removed automatically after registration."
