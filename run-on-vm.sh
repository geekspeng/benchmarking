#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Busbar Inc and contributors
#
# run-on-vm.sh - the measurement half of run-on-ec2.sh, run directly on ONE local Ubuntu VM.
#
#   ./run-on-vm.sh                    # every gateway, sequentially, on this machine
#   ./run-on-vm.sh busbar             # a subset
#   OTB_DIALECTS=openai ./run-on-vm.sh busbar   # one cell instead of the 6x6 grid (seconds, not hours)
#
# WHAT THIS IS. run-on-ec2.sh is two halves: an AWS orchestrator (launch N boxes, ssh, rsync,
# publish) and the script that runs ON each box (provision, fetch the rig, start the mock, run
# `otb`). This script is that second half, inlined onto a machine you already own. No AWS, no ssh,
# no keypairs: you copy the repo to the VM and run it.
#
# WHAT THIS IS NOT. It is NOT the published board's rig, in three ways it cannot fix locally:
#   1. HARDWARE. The board's comparability basis is AWS m7g.4xlarge with the gateway pinned to
#      exactly 4 cores and mock/loadgen on 6 each. Your VM is a different machine; numbers from
#      here are for development and verification, and must not be published beside board rows.
#   2. ISOLATION. EC2 gives every gateway a FRESH box, so no gateway inherits another's page
#      cache, disk state or docker state. This script reuses one box for all gateways and only
#      restarts the mock between them. For a single-gateway run the difference is nil; for a
#      full sequential field it is a real (small) difference from the published methodology.
#   3. PROVENANCE. Box qualification compares this machine against the board's prior
#      observations; with no baseline it seeds one (OTB_QUALIFY_BASELINE unset), which the
#      engine records honestly in the snapshot.
#
# It IS the same engine, the same mock, the same core-pinning scheme (scaled to your core count)
# and the same per-gateway flow: validate the manifest, probe the grid, sweep what serves, write
# results/snapshots/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── what this run measures, resolved once ─────────────────────────────────────────────────────────
DEFAULT_GATEWAYS=()
for d in "$HERE"/gateways/*/definition.json; do DEFAULT_GATEWAYS+=("$(basename "$(dirname "$d")")"); done
if [[ $# -gt 0 ]]; then GATEWAYS=("$@"); else GATEWAYS=("${DEFAULT_GATEWAYS[@]}"); fi

log(){ echo "[$(date +%H:%M:%S)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

# ── platform guard ────────────────────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux) ;;
  *) die "this script runs ON the Linux box doing the measuring (engine binaries are Linux ELF; taskset, /proc RSS sampling and --cpuset-cpus are Linux). Run it inside the Ubuntu VM." ;;
esac
case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x86 ;;
  *) die "unknown arch $(uname -m) - the rig release ships arm64 and x86 only" ;;
esac

# SUDO ON A PERSONAL VM MAY BE INTERACTIVE, unlike an unattended cloud box. Ask for the password
# (or reuse the cached credential) ONCE up front rather than deep inside provisioning, so the run
# never blocks mid-measurement. Everything after this point uses cached sudo.
if ! sudo -n true 2>/dev/null; then
  echo "[vm] sudo needs a password - authenticating once for the whole run"
  sudo -v || die "sudo is required (apt installs, docker daemon config, sysctl, taskset for other users)"
fi

# ── core split: the fairness basis, scaled to what this VM actually has ───────────────────────────
# The published basis is gateway=4, loadgen=6, mock=6 on 16 real cores (Graviton: 1 vCPU = 1 core).
# A VM with fewer cores gets the same SHAPE, proportionally (25% / 37.5% / rest), pinned to
# contiguous logical CPUs. On an x86 VM with hyperthreading, 1 vCPU is half a core - the pinning
# still isolates the three roles from each other, which is what comparability between gateways on
# THIS box needs; it just isn't the board's basis, and the header warning already said so.
NPROC="$(nproc)"
NPROC="${NPROC//[!0-9]/}"; : "${NPROC:=1}"
split_cores() { # <n> -> GW_N LOAD_N MOCK_N on stdout, or fails when the roles cannot be isolated
  local n="$1" gw load mock
  gw=$(( (n + 2) / 4 ))           # ~25%, min meaningful 1
  load=$(( (n * 3 + 4) / 8 ))     # ~37.5%
  mock=$(( n - gw - load ))
  (( gw >= 1 )) && (( load >= 2 )) && (( mock >= 2 )) || return 1
  printf '%s %s %s\n' "$gw" "$load" "$mock"
}
read -r GW_N LOAD_N MOCK_N < <(split_cores "$NPROC" || true)
if [[ -z "${GW_N:-}" ]]; then
  die "this VM has ${NPROC} vCPU, which cannot host the three isolated roles (gateway + load generator + mock each need their own cores). Give the VM at least 5, ideally 16 to match the published 4/6/6 split."
fi
# Range lists from the counts. Contiguous blocks: gateway first (it gets the low cores), then the
# load generator, then the mock. CORES/LOADCORES/MOCKCORES may be set explicitly to override.
fmt_range() { local a="$1" b="$2"; (( a == b )) && echo "$a" || echo "$a-$b"; }
CORES="${CORES:-$(fmt_range 0 $((GW_N - 1)))}"
LOADCORES="${LOADCORES:-$(fmt_range "$GW_N" $((GW_N + LOAD_N - 1)))}"
MOCKCORES="${MOCKCORES:-$(fmt_range $((GW_N + LOAD_N)) $((NPROC - 1)))}"
log "[vm] ${NPROC} vCPU: gateway=${CORES} loadgen=${LOADCORES} mock=${MOCKCORES}"
if (( NPROC != 16 )); then
  log "[vm] NOTE: the published board pins 4/6/6 on 16 cores; this split is proportional, so numbers here are NOT comparable to onthebench.ai"
fi

# ── provenance stamps: name what ran ──────────────────────────────────────────────────────────────
# Same idea as run-on-ec2.sh: BENCH_ENGINE_COMMIT is the INSTRUMENT (from ENGINE_PIN when present),
# not necessarily the tree. Without .git (a bare copy of the repo) the ENGINE_PIN file is still
# enough, and the fetched binary's own `engine-commit` stamp is verified against it below.
_engine_pin=""
if [ -r "$HERE/ENGINE_PIN" ]; then
  read -r _engine_pin _ < "$HERE/ENGINE_PIN" || true
  case "$_engine_pin" in *[!0-9a-f]*|"") _engine_pin="" ;; esac
fi
BENCH_ENGINE_COMMIT="${BENCH_ENGINE_COMMIT:-${_engine_pin:-}}"
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  [ -n "$(git -C "$HERE" status --porcelain -- . ':(exclude)results' 2>/dev/null)" ] && BENCH_ENGINE_DIRTY=1 || BENCH_ENGINE_DIRTY=0
else
  BENCH_ENGINE_DIRTY="${BENCH_ENGINE_DIRTY:-1}"   # no history to prove cleanliness - say so
fi
export BENCH_ENGINE_DIRTY
# A human-readable hardware label for the snapshot, since "unknown" hides the one fact a local
# reader most needs: which machine produced this.
_cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"
[ -z "$_cpu_model" ] && _cpu_model="$(grep -m1 'Model' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"
BENCH_HARDWARE="${BENCH_HARDWARE:-local VM: ${_cpu_model:-unknown cpu}, ${NPROC} vCPU. Gateway ${CORES}, loadgen ${LOADCORES}, mock ${MOCKCORES}. NOT the published m7g.4xlarge basis.}"
BENCH_ARCH="$ARCH"
export BENCH_ENGINE_COMMIT BENCH_HARDWARE BENCH_ARCH

# ── provision: bare OS -> a bench box (idempotent) ────────────────────────────────────────────────
# Same package set the EC2 box installs: docker for the image gateways, curl/jq/git for the rig,
# psutil for the memory sampler, build-essential + rustup ONLY when a requested gateway builds
# from source (litellm-rust, helicone) so a docker-only field doesn't pay for a toolchain.
needs_source_build=0
for gw in "${GATEWAYS[@]}"; do
  grep -q '"build"' "$HERE/gateways/$gw/definition.json" 2>/dev/null && needs_source_build=1
done

apt_install() { # retried: apt contends with unattended-upgrades on a desktop-ish VM just as on a box
  local i
  for i in 1 2 3; do
    sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" && return 0
    sleep 10
  done
  return 1
}
if ! command -v docker >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 \
   || ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  log "[vm] installing base deps (docker, curl, jq, python3)"
  for i in 1 2 3; do sudo NEEDRESTART_MODE=a apt-get update -q && break; sleep 10; done
  apt_install docker.io curl ca-certificates jq python3-pip git build-essential \
    || die "base deps did not install - see apt output above"
fi
if ! python3 -c 'import psutil' >/dev/null 2>&1; then
  python3 -m pip install --user -q --break-system-packages psutil 2>/dev/null \
    || pip3 install -q --user psutil 2>/dev/null \
    || log "[vm] WARN: psutil did not install; RSS readings that need it will publish absences"
fi
if (( needs_source_build )) && ! command -v cargo >/dev/null 2>&1; then
  log "[vm] a requested gateway builds from source - installing rustup (one-time)"
  curl -sSf https://sh.rustup.rs | sh -s -- -y -q >/dev/null 2>&1 || die "rustup install failed (needed by source-built gateways)"
fi
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

# FAIRNESS: containers inherit the docker DAEMON's fd limit, not the shell's. Left at ~1024 a
# containerised gateway collapses at exactly c=1024 with EMFILE, which reads as the gateway's
# failure rather than ours (same fix the EC2 box applies).
if command -v docker >/dev/null 2>&1 && [ ! -f /etc/docker/daemon.json ]; then
  echo '{ "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 } } }' \
    | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true
fi
# DOCKER ACCESS WITHOUT A RE-LOGIN: `usermod -aG docker` only takes effect in a NEW session, and
# this script must work in the one it was started in. chmod 666 on the socket is the same
# belt-and-braces the EC2 box uses after usermod.
if command -v docker >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  docker info >/dev/null 2>&1 || sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
  docker info >/dev/null 2>&1 || die "docker is installed but the daemon does not answer for user $USER (try: sudo systemctl enable --now docker, then re-run)"
fi

# ── the rig: engine + mock ────────────────────────────────────────────────────────────────────────
# Default: the prebuilt binaries from the rolling `rig` GitHub release - identical instrument to
# the board, zero build time. VM_ENGINE_FROM_SOURCE=1 builds both from THIS tree instead (needs
# cargo; numbers are then from your tree, honestly stamped dirty/clean by the provenance block).
OTB=""
MOCK_PID=""
# The mock is setsid-detached, so $! may be the short-lived wrapper rather than the mock itself;
# kill by COMMAND LINE the way run-on-ec2.sh does, with the PID as belt-and-braces.
cleanup(){
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  pkill -f "mock-$ARCH" 2>/dev/null
  [[ "${VM_ENGINE_FROM_SOURCE:-0}" == 1 ]] && pkill -f "target/release/mock" 2>/dev/null
  return 0
}
trap cleanup EXIT
# With a handler installed, INT/TERM no longer terminate the shell by default - exit explicitly so
# the EXIT trap (and its mock cleanup) actually runs on Ctrl-C rather than resuming the script.
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${VM_ENGINE_FROM_SOURCE:-0}" == 1 ]]; then
  command -v cargo >/dev/null 2>&1 || die "VM_ENGINE_FROM_SOURCE=1 needs cargo (rustup)"
  log "[vm] building engine + mock from this tree (release)"
  (cd "$HERE" && cargo build --release) || die "cargo build failed"
  OTB="$HERE/target/release/otb"
  export RIG_MOCK_CMD="$HERE/target/release/mock"   # fetch_rig's local-override path
  log "[vm] using SOURCE-BUILD rig - NOT the pinned release binaries"
else
  # mock via lib/rig.sh (caches under bin/, records provenance); engine from the same release.
  # shellcheck source=lib/rig.sh
  source "$HERE/lib/rig.sh"
  fetch_rig "$HERE" || die "could not fetch the rig (offline? copy target/release/{otb,mock} over and set VM_ENGINE_FROM_SOURCE=1)"
  curl -fsSL -o "$HERE/otb" "$RIG_URL/otb-$ARCH" || die "could not fetch $RIG_URL/otb-$ARCH"
  chmod +x "$HERE/otb"
  OTB="$HERE/otb"
fi

# THE STAMP IS THE BINARY'S OWN ANSWER, not the pin's. A run that cannot prove which engine it
# used cannot produce a comparable measurement - the same rule the EC2 flow enforces, and the rig
# tag is MOVING, so a stale local cache or a release rebuilt since the pin is caught here.
_otb_built_from="$("$OTB" engine-commit 2>/dev/null | tr -d '[:space:]')"
[ -n "$_otb_built_from" ] || die "the engine binary reports no build commit - cannot establish provenance"
if [ -n "$BENCH_ENGINE_COMMIT" ] && [ "$_otb_built_from" != "$BENCH_ENGINE_COMMIT" ]; then
  if [[ "${VM_SKIP_ENGINE_CHECK:-0}" == 1 ]]; then
    log "[vm] WARN: engine mismatch (pin $BENCH_ENGINE_COMMIT, binary $_otb_built_from) - measuring anyway per VM_SKIP_ENGINE_CHECK=1"
  else
    die "engine mismatch: ENGINE_PIN says ${BENCH_ENGINE_COMMIT:0:12}, the fetched binary was built from ${_otb_built_from:0:12}. The rig tag has moved past the pin. Use the pinned release artifact, or set VM_SKIP_ENGINE_CHECK=1 to measure anyway (results will carry the binary's true stamp)."
  fi
fi
BENCH_ENGINE_COMMIT="$_otb_built_from"   # publish what actually measured, as on EC2
export BENCH_ENGINE_COMMIT
log "[vm] engine verified: otb built from ${_otb_built_from:0:12}"

# ── rig env prep, once (same knobs the EC2 box sets before any window) ────────────────────────────
# fd limit for the load generator (one connection per concurrency unit; a sweep to c=4096 needs
# 4096 descriptors in THIS process - the default 1024 turns every rung past c=1020 into EMFILE
# failures attributed to the gateway).
ulimit -n 1048576 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
log "[vm] fd limit: $(ulimit -Sn) (hard $(ulimit -Hn))"
# Ephemeral ports are the real concurrency ceiling: stock Linux gives ~28k source ports, and a
# fast gateway driven past that turns EADDRNOTAVAIL into "the gateway refusing". 16384 floor
# keeps the ephemeral range clear of every port the rig itself binds (mock 8000, gateways 3xxx-12xxx).
sudo sysctl -wq net.ipv4.ip_local_port_range="16384 65535" 2>/dev/null || true
sudo sysctl -wq net.ipv4.tcp_tw_reuse=1 2>/dev/null || true
log "[vm] ephemeral ports: $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo unknown) (tw_reuse=$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || echo unknown))"
mkdir -p "$HERE/results/snapshots"

# rig provenance for the snapshot (mock sha/origin), when the release path was used.
if [[ "${VM_ENGINE_FROM_SOURCE:-0}" != 1 ]]; then
  export OTB_RIG_MOCK_ORIGIN="${RIG_MOCK_ORIGIN:-}"
  export OTB_RIG_MOCK_SHA256="$(_rig_sha256 "${MOCK:-}")"
  export OTB_RIG_MOCK_UPDATED_AT="$(_rig_asset_updated_at "mock-$ARCH")"
  export OTB_RIG_URL="$RIG_URL"
fi

# ── per gateway: fresh mock, validate, run ────────────────────────────────────────────────────────
# Mock listen port. The health check and the address handed to `otb run` follow it, so overriding
# this one variable moves the whole rig off 8000 (the EC2 flow's default) - e.g. when something
# else already owns 8000 on this VM. Keep it above the ephemeral-port floor set earlier.
MOCK_PORT="${MOCK_PORT:-8000}"
start_mock() { # fresh mock per gateway, pinned to its cores - the closest one VM gets to a fresh box
  [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""; }
  pkill -f "mock-$ARCH" 2>/dev/null; pkill -f "target/release/mock" 2>/dev/null; sleep 1
  local mock_bin="./bin/mock-$ARCH"
  [[ "${VM_ENGINE_FROM_SOURCE:-0}" == 1 ]] && mock_bin="./target/release/mock"
  setsid taskset -c "$MOCKCORES" "$HERE/$mock_bin" --port "$MOCK_PORT" </dev/null >"$HERE/mock.log" 2>&1 &
  MOCK_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -s -m2 -o /dev/null -X POST "127.0.0.1:${MOCK_PORT}/v1/chat/completions" \
      -H "content-type: application/json" -d "{}" && return 0
    sleep 1
  done
  echo "the mock never came up on 127.0.0.1:$MOCK_PORT (see mock.log) - every not-served verdict would be a rig fault" >&2
  return 1
}

declare -a RUN_RC=() FAILED=()
OTB_RUN_ID="vm-$(date +%Y%m%d-%H%M%S)-$$"   # scope every container this run creates (see otb run)
export OTB_RUN_ID
log "[vm] gateways: ${GATEWAYS[*]}  (container scope $OTB_RUN_ID)"
log "[vm] tip: OTB_DIALECTS=openai narrows the 6x6 grid to one cell; OTB_MIN_CONC/OTB_MAX_CONC narrow the sweep"

for gw in "${GATEWAYS[@]}"; do
  log "=== $gw ==="
  if [ ! -d "$HERE/gateways/$gw" ]; then
    log "[vm] no gateways/$gw directory - skipping"; FAILED+=("$gw(nogw)"); continue
  fi
  start_mock || { FAILED+=("$gw(mock)"); continue; }
  # validate BEFORE measuring: a manifest that cannot launch should cost seconds, not a sweep.
  if ! (cd "$HERE" && "$OTB" validate "gateways/$gw"); then
    log "[vm] $gw failed manifest validation - skipping"; FAILED+=("$gw(validate)"); continue
  fi
  (cd "$HERE" && OTB_GW_CORES="$CORES" LOADCORES="$LOADCORES" \
     "$OTB" run "gateways/$gw" "127.0.0.1:$MOCK_PORT" results/snapshots)
  rc=$?
  RUN_RC+=("$gw=$rc")
  (( rc == 0 )) || FAILED+=("$gw(rc=$rc)")
  log "[vm] $gw finished (rc=$rc)"
done

cleanup
log "[vm] done. snapshots in results/snapshots/"
if (( ${#FAILED[@]} )); then
  log "[vm] failures: ${FAILED[*]}"
  exit 1
fi
