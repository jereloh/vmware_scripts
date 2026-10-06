#!/usr/bin/env bash
#
# VKS planned shutdown/startup helper
#
# Automates the Kubernetes-side preparation and recovery steps for planned
# VKS cluster shutdowns in a Supervisor environment.
#
# Shutdown workflow:
#   1. Discover VKS clusters and workers.
#   2. Cordon worker nodes while preserving existing cordons.
#   3. Pause Cluster API Cluster objects after WCP has been stopped.
#
# Startup workflow:
#   1. Verify infrastructure, Supervisor, WCP and VKS health.
#   2. Unpause clusters previously paused by this script.
#   3. Re-discover current workers and uncordon them while preserving
#      pre-existing cordons.
#
# Features:
#   - Records shutdown state for later recovery.
#   - Preserves pre-existing worker cordons.
#   - Preserves pre-existing paused clusters.
#   - Uses live Machine -> nodeRef discovery during startup, allowing for
#     worker replacement or node name changes across power cycles.
#   - Refuses automation when operator intent cannot be safely determined.
#
# Requirements:
#   - kubectl access to the Supervisor Cluster.
#   - Permissions to read Cluster API Cluster and Machine resources.
#   - Access to VKS cluster kubeconfig secrets.
#   - bash, awk, grep, sort, base64, mktemp and standard GNU utilities.
#
# This helper:
#   - DOES NOT stop or start WCP.
#   - DOES NOT power VMs on or off.
#   - DOES NOT shut down or start Supervisor Services.
#   - DOES NOT verify vCenter, NSX, vSAN, Supervisor or VKS health.
#   - DOES NOT replace Broadcom-supported shutdown procedures.
#
# Script is AI-generated.
# USE AT YOUR OWN RISK.
# Review all output carefully before proceeding.
# Always validate the workflow against your environment and applicable
# Broadcom VCF, Supervisor, vSAN and VKS documentation.
#
# Run a local copy:
#   bash vks-power.sh guide
#   bash vks-power.sh discover
#   bash vks-power.sh cordon
#   WCP_STOPPED=YES bash vks-power.sh pause
#   HEALTH_VERIFIED=YES bash vks-power.sh startup
#   bash vks-power.sh status
#
# Optional environment variables:
#   VKS_STATE_DIR=/persistent/path/vks-power-state
#   ASSUME_YES=1
#
# Demo: run directly from a trusted URL without saving a .sh file:
#   curl -fsSL 'https://raw.githubusercontent.com/jereloh/vmware_scripts/main/vks-power.sh' | bash -s -- guide
#
# Additional examples:
#   curl -fsSL 'https://raw.githubusercontent.com/jereloh/vmware_scripts/main/vks-power.sh' | bash -s -- discover
#   curl -fsSL 'https://raw.githubusercontent.com/jereloh/vmware_scripts/main/vks-power.sh' | bash -s -- cordon
#
# Review the remote script before piping it to Bash.
#


set -Eeuo pipefail

MODE="${1:-}"
STATE_DIR="${VKS_STATE_DIR:-$PWD/vks-power-state}"
ASSUME_YES="${ASSUME_YES:-0}"
WCP_STOPPED="${WCP_STOPPED:-NO}"
HEALTH_VERIFIED="${HEALTH_VERIFIED:-NO}"

CLUSTER_RESOURCE="clusters.cluster.x-k8s.io"
MACHINE_RESOURCE="machines.cluster.x-k8s.io"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
umask 077

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  ./vks-power.sh guide
  ./vks-power.sh discover
  ./vks-power.sh cordon
  WCP_STOPPED=YES ./vks-power.sh pause
  HEALTH_VERIFIED=YES ./vks-power.sh startup
  ./vks-power.sh status

Optional environment variables:
  VKS_STATE_DIR=/persistent/path/vks-power-state
  ASSUME_YES=1

What this helper automates:
  Shutdown: cordon current VKS WORKERS, then pause CAPI Cluster objects after the
            operator confirms WCP is stopped.
  Startup:  unpause current paused clusters that were not pre-paused, and
            uncordon CURRENT workers in clusters touched by the shutdown cordon,
            while preserving workers recorded as pre-existing cordons.

Important startup learning:
  Worker/Machine names can change across a shutdown/startup cycle. Startup therefore
  does NOT require old recorded worker names to still exist. It re-discovers the
  current Machine -> nodeRef set from the Supervisor before uncordoning.

Run ./vks-power.sh guide for the operator shutdown/startup runbook and caveats.
USAGE
}

guide() {
  cat <<'GUIDE'
===============================================================================
VCF / Supervisor / VKS planned power runbook used with this helper
===============================================================================

This is an OPERATOR RUNBOOK embedded in a custom helper. It is not a substitute
for the applicable Broadcom VCF/vSAN/VKS shutdown documentation.

SHUTDOWN - dependency-oriented sequence
  1) Quiesce/stop applications and customer workloads as applicable.
  2) VKS: ./vks-power.sh cordon
  3) On vCenter: stop WCP using the applicable Broadcom procedure.
  4) VKS: WCP_STOPPED=YES ./vks-power.sh pause
  5) Power off VKS node VMs in the applicable documented order.
  6) Supervisor Services are NOT managed by this helper. Use supported service
     shutdown/quiesce procedures where available. Do not assume a declarative Pod
     makes a hard CRX/vSphere-Pod power-off application-safe.
  7) Power off the Supervisor control-plane VM(s) after the VKS/Supervisor work is
     complete for the planned shutdown.
  8) Continue the VCF management-domain shutdown: VCF Automation / Operations for
     Networks / proxies / license and management services / Operations / protection
     services as applicable; then NSX Edge and NSX Manager; vCenter + vSAN/ESXi last.
  9) For vSAN, use the supported vSAN Shutdown Cluster workflow/procedure. Maintenance
     Mode -> No Data Migration alone is NOT treated by this helper as vSAN shutdown.

STARTUP - practical dependency sequence from this environment
  1) Restore ESXi/vSAN according to the shutdown method used.
  2) Bring vCenter up and verify it is healthy.
  3) Bring NSX up and verify networking before Supervisor recovery.
  4) Bring Supervisor control-plane VM(s) up and ensure WCP/Supervisor is healthy.
  5) Let/restore Supervisor Services (Harbor, Contour/Envoy, PAIS, CCI, metrics,
     configuration services, etc.) and verify Kubernetes reconciliation/readiness.
  6) Bring VCF management services / VSP and remaining VCF management appliances up
     as applicable (Operations, Automation, VNA/Operations for Networks, collectors,
     license services, and site-specific dependencies).
  7) Power/verify VKS node VMs and cluster health.
  8) Only after health verification:
       HEALTH_VERIFIED=YES ./vks-power.sh startup
  9) Verify VKS workloads/applications after unpause/uncordon.

NOTES FROM THE RECOVERY TEST
  - A VKS worker was replaced/respawned with a different node name while the cluster
    was paused. The old startup implementation failed because it required the exact
    shutdown-time node name.
  - This version re-discovers CURRENT worker nodeRefs on startup.
  - Pre-existing cordons are preserved. If a node that was pre-existing-cordoned is
    itself missing/replaced, the script refuses to guess and asks for manual review.
===============================================================================
GUIDE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
  local prompt="$1" ans
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  read -r -p "$prompt Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || die "Cancelled by operator."
}

supervisor_precheck() {
  need_cmd kubectl
  need_cmd base64
  need_cmd grep
  need_cmd awk
  need_cmd sort
  need_cmd wc
  need_cmd mktemp

  kubectl get "$CLUSTER_RESOURCE" -A --request-timeout=15s >/dev/null 2>&1 \
    || die "Cannot list Cluster API Cluster objects. Ensure kubectl is connected to the Supervisor with sufficient privileges."
  kubectl get "$MACHINE_RESOURCE" -A --request-timeout=15s >/dev/null 2>&1 \
    || die "Cannot list Cluster API Machine objects. Ensure this is the Supervisor context and permissions are sufficient."
}

current_inventory() {
  kubectl get "$CLUSTER_RESOURCE" -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
    | awk 'NF' | sort
}

state_init_for_shutdown() {
  if [[ -f "$STATE_DIR/startup.complete" ]]; then
    die "State directory belongs to a completed prior cycle: $STATE_DIR . Archive/remove it or set VKS_STATE_DIR to a new path."
  fi
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/workers_changed.tsv" \
        "$STATE_DIR/workers_preexisting_cordon.tsv" \
        "$STATE_DIR/clusters_changed.tsv" \
        "$STATE_DIR/clusters_preexisting_pause.tsv"

  if [[ ! -f "$STATE_DIR/inventory.tsv" ]]; then
    current_inventory > "$STATE_DIR/inventory.tsv"
    [[ -s "$STATE_DIR/inventory.tsv" ]] || die "No VKS/CAPI Cluster objects were found."
    {
      printf 'created='; date '+%Y-%m-%dT%H:%M:%S%z'
      printf 'context='; kubectl config current-context 2>/dev/null || printf 'unknown\n'
    } > "$STATE_DIR/session.txt"
  fi
}

state_require() {
  [[ -f "$STATE_DIR/inventory.tsv" ]] || die "State not found at $STATE_DIR . Use the same VKS_STATE_DIR used during shutdown."
}

inventory_must_match() {
  local now="$TMP_DIR/inventory-now.tsv"
  current_inventory > "$now"
  if ! cmp -s "$STATE_DIR/inventory.tsv" "$now"; then
    warn "Supervisor Cluster inventory changed since cordon state was captured."
    warn "Recorded inventory:"
    sed 's/^/  /' "$STATE_DIR/inventory.tsv" >&2
    warn "Current inventory:"
    sed 's/^/  /' "$now" >&2
    die "Refusing to continue because the cluster set changed. Review manually."
  fi
}

record_unique() {
  local file="$1"; shift
  local line
  printf -v line '%s' "$1"; shift
  while (($#)); do
    line+=$'\t'"$1"
    shift
  done
  grep -Fqx -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

make_guest_kubeconfig() {
  local ns="$1" cluster="$2"
  local secret="${cluster}-kubeconfig"
  GUEST_KCFG="$TMP_DIR/${ns}_${cluster}.kubeconfig"

  kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1 \
    || die "Missing kubeconfig Secret $ns/$secret. Refusing to guess how to access cluster $cluster."

  kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.value}' \
    | base64 -d > "$GUEST_KCFG"

  [[ -s "$GUEST_KCFG" ]] || die "Decoded kubeconfig is empty for $ns/$cluster."
  kubectl --kubeconfig="$GUEST_KCFG" get nodes --request-timeout=15s >/dev/null 2>&1 \
    || die "Cannot access VKS cluster $ns/$cluster with its kubeconfig Secret."
}

count_nonempty_lines() {
  awk 'NF{n++} END{print n+0}'
}

get_cluster_node_sets() {
  local ns="$1" cluster="$2"
  local all_machines_file="$TMP_DIR/${ns}_${cluster}.machines"
  local all_refs_file="$TMP_DIR/${ns}_${cluster}.allrefs"
  local cp_refs_file="$TMP_DIR/${ns}_${cluster}.cprefs"
  local worker_refs_file="$TMP_DIR/${ns}_${cluster}.workers"
  local machine_count ref_count cp_count

  kubectl -n "$ns" get "$MACHINE_RESOURCE" \
    -l "cluster.x-k8s.io/cluster-name=$cluster" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | awk 'NF' | sort -u > "$all_machines_file"

  kubectl -n "$ns" get "$MACHINE_RESOURCE" \
    -l "cluster.x-k8s.io/cluster-name=$cluster" \
    -o jsonpath='{range .items[*]}{.status.nodeRef.name}{"\n"}{end}' \
    | awk 'NF' | sort -u > "$all_refs_file"

  kubectl -n "$ns" get "$MACHINE_RESOURCE" \
    -l "cluster.x-k8s.io/cluster-name=$cluster,cluster.x-k8s.io/control-plane" \
    -o jsonpath='{range .items[*]}{.status.nodeRef.name}{"\n"}{end}' \
    | awk 'NF' | sort -u > "$cp_refs_file"

  machine_count="$(count_nonempty_lines < "$all_machines_file")"
  ref_count="$(count_nonempty_lines < "$all_refs_file")"
  cp_count="$(count_nonempty_lines < "$cp_refs_file")"

  [[ "$machine_count" -gt 0 ]] \
    || die "$ns/$cluster has no Machine objects. Refusing automatic worker identification."
  [[ "$machine_count" -eq "$ref_count" ]] \
    || die "$ns/$cluster has Machine objects without nodeRef values ($ref_count nodeRefs / $machine_count Machines). Refusing automatic worker identification."
  [[ "$cp_count" -gt 0 ]] \
    || die "$ns/$cluster has no control-plane Machine nodeRefs. Refusing to classify all nodes as workers."

  : > "$worker_refs_file"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if ! grep -Fqx -- "$node" "$cp_refs_file"; then
      printf '%s\n' "$node" >> "$worker_refs_file"
    fi
  done < "$all_refs_file"

  ALL_REFS_FILE="$all_refs_file"
  CP_REFS_FILE="$cp_refs_file"
  WORKER_REFS_FILE="$worker_refs_file"
}

show_cluster() {
  local ns="$1" cluster="$2" paused worker_count cp_count total_count node sched
  paused="$(kubectl -n "$ns" get "$CLUSTER_RESOURCE" "$cluster" -o jsonpath='{.spec.paused}' 2>/dev/null || true)"
  [[ -n "$paused" ]] || paused="false"

  make_guest_kubeconfig "$ns" "$cluster"
  get_cluster_node_sets "$ns" "$cluster"

  total_count="$(count_nonempty_lines < "$ALL_REFS_FILE")"
  cp_count="$(count_nonempty_lines < "$CP_REFS_FILE")"
  worker_count="$(count_nonempty_lines < "$WORKER_REFS_FILE")"

  printf '\n%s/%s  paused=%s  machines=%s  control-plane=%s  workers=%s\n' \
    "$ns" "$cluster" "$paused" "$total_count" "$cp_count" "$worker_count"

  if [[ "$worker_count" -eq 0 ]]; then
    printf '  No worker Machine nodeRefs found.\n'
  else
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      sched="$(kubectl --kubeconfig="$GUEST_KCFG" get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
      if [[ "$sched" == "true" ]]; then
        printf '  worker %-60s SchedulingDisabled\n' "$node"
      else
        printf '  worker %-60s schedulable\n' "$node"
      fi
    done < "$WORKER_REFS_FILE"
  fi
}

discover() {
  supervisor_precheck
  local inv="$TMP_DIR/discover.tsv" ns cluster
  current_inventory > "$inv"
  [[ -s "$inv" ]] || die "No Cluster API Cluster objects found."

  log "Current Supervisor context: $(kubectl config current-context 2>/dev/null || echo unknown)"
  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    show_cluster "$ns" "$cluster"
  done < "$inv"
}

cordon_all() {
  supervisor_precheck
  state_init_for_shutdown
  inventory_must_match

  [[ ! -f "$STATE_DIR/pause.complete" ]] \
    || die "Pause phase is already complete. Do not run cordon after pause."

  log "The script will cordon VKS WORKER nodes only."
  log "It identifies worker nodes from Supervisor CAPI Machine nodeRefs, excluding Machines carrying cluster.x-k8s.io/control-plane."
  log "Existing cordons are preserved and recorded separately."

  local ns cluster node unsched
  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    show_cluster "$ns" "$cluster"
  done < "$STATE_DIR/inventory.tsv"

  confirm "Cordon the schedulable worker nodes shown above?"

  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    make_guest_kubeconfig "$ns" "$cluster"
    get_cluster_node_sets "$ns" "$cluster"

    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      kubectl --kubeconfig="$GUEST_KCFG" get node "$node" >/dev/null 2>&1 \
        || die "Expected worker node $node is not present in guest cluster $ns/$cluster."

      unsched="$(kubectl --kubeconfig="$GUEST_KCFG" get node "$node" -o jsonpath='{.spec.unschedulable}')"
      if [[ "$unsched" == "true" ]]; then
        log "$ns/$cluster: $node already SchedulingDisabled; preserving that pre-existing state."
        record_unique "$STATE_DIR/workers_preexisting_cordon.tsv" "$ns" "$cluster" "$node"
      else
        log "$ns/$cluster: cordoning $node"
        kubectl --kubeconfig="$GUEST_KCFG" cordon "$node"
        record_unique "$STATE_DIR/workers_changed.tsv" "$ns" "$cluster" "$node"
      fi
    done < "$WORKER_REFS_FILE"
  done < "$STATE_DIR/inventory.tsv"

  touch "$STATE_DIR/cordon.complete"
  log "Cordon phase complete. State saved in: $STATE_DIR"
  log "NEXT HUMAN STEP: stop the vCenter Workload Control Plane (WCP) service as documented by Broadcom."
  log "Then run: WCP_STOPPED=YES ./vks-power.sh pause"
}

pause_all() {
  supervisor_precheck
  state_require
  inventory_must_match

  [[ -f "$STATE_DIR/cordon.complete" ]] \
    || die "Cordon phase is not marked complete. Run ./vks-power.sh cordon first."
  [[ "$WCP_STOPPED" == "YES" ]] \
    || die "Refusing to pause. After YOU stop WCP, rerun with: WCP_STOPPED=YES ./vks-power.sh pause"

  local ns cluster paused
  log "WCP_STOPPED=YES was supplied by the operator. This script does not verify or stop WCP."

  # Preflight every pause admission before changing any Cluster. This prevents a
  # later cluster admission failure from leaving an avoidable partially-paused set.
  log "Preflighting pause admission for every cluster that is not already paused..."
  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    paused="$(kubectl -n "$ns" get "$CLUSTER_RESOURCE" "$cluster" -o jsonpath='{.spec.paused}')"
    if [[ "$paused" != "true" ]]; then
      kubectl -n "$ns" patch "$CLUSTER_RESOURCE" "$cluster" \
        --type merge -p '{"spec":{"paused":true}}' --dry-run=server -o name >/dev/null \
        || die "Pause admission preflight failed for $ns/$cluster. No pause changes were made by this invocation."
    fi
  done < "$STATE_DIR/inventory.tsv"

  confirm "Pause the recorded VKS clusters now?"

  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    paused="$(kubectl -n "$ns" get "$CLUSTER_RESOURCE" "$cluster" -o jsonpath='{.spec.paused}')"
    if [[ "$paused" == "true" ]]; then
      log "$ns/$cluster already paused; preserving that pre-existing state."
      record_unique "$STATE_DIR/clusters_preexisting_pause.tsv" "$ns" "$cluster"
    else
      log "$ns/$cluster: setting spec.paused=true"
      kubectl -n "$ns" patch "$CLUSTER_RESOURCE" "$cluster" \
        --type merge -p '{"spec":{"paused":true}}'
      record_unique "$STATE_DIR/clusters_changed.tsv" "$ns" "$cluster"
    fi
  done < "$STATE_DIR/inventory.tsv"

  touch "$STATE_DIR/pause.complete"
  log "Pause phase complete."
  log "The script is finished with the VKS preparation. Continue the remaining infrastructure shutdown manually."
}

startup_preflight() {
  supervisor_precheck
  state_require
  inventory_must_match

  [[ -f "$STATE_DIR/pause.complete" ]] \
    || die "Recorded shutdown never completed the pause phase. Review state manually before startup automation."
  [[ "$HEALTH_VERIFIED" == "YES" ]] \
    || die "Human health verification is required. Rerun with HEALTH_VERIFIED=YES only after infrastructure, Supervisor, VCF management services, and VKS health have been checked."

  local ns cluster oldnode

  # Every shutdown-time Cluster must still exist. Worker identities may legitimately
  # change, so workers are re-discovered later from current Machine nodeRefs.
  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue
    kubectl -n "$ns" get "$CLUSTER_RESOURCE" "$cluster" >/dev/null 2>&1 \
      || die "Recorded cluster $ns/$cluster no longer exists. Refusing startup automation."
  done < "$STATE_DIR/inventory.tsv"

  # Preserve operator intent for shutdown-time PRE-EXISTING cordons. If one of those
  # specific nodes disappeared, do not guess whether a replacement should inherit
  # the cordon. This is deliberately stricter than the handling of script-cordoned
  # workers, which may be safely re-discovered by current cluster membership.
  if [[ -s "$STATE_DIR/workers_preexisting_cordon.tsv" ]]; then
    while IFS=$'\t' read -r ns cluster oldnode; do
      [[ -n "$ns" && -n "$cluster" && -n "$oldnode" ]] || continue
      make_guest_kubeconfig "$ns" "$cluster"
      kubectl --kubeconfig="$GUEST_KCFG" get node "$oldnode" --request-timeout=15s >/dev/null 2>&1 \
        || die "Pre-existing-cordoned worker $oldnode is no longer present in $ns/$cluster. Refusing to guess whether a replacement should remain cordoned. Review this cluster manually."
    done < <(sort -u "$STATE_DIR/workers_preexisting_cordon.tsv")
  fi
}

resume_live_paused_clusters() {
  local ns cluster paused

  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue

    # A cluster that was already paused before shutdown is outside this helper's
    # ownership and must remain paused.
    if grep -Fqx -- "$ns"$'\t'"$cluster" "$STATE_DIR/clusters_preexisting_pause.tsv" 2>/dev/null; then
      log "$ns/$cluster: preserving pre-existing paused state."
      continue
    fi

    paused="$(kubectl -n "$ns" get "$CLUSTER_RESOURCE" "$cluster" -o jsonpath='{.spec.paused}' 2>/dev/null || true)"
    if [[ "$paused" == "true" ]]; then
      log "$ns/$cluster: setting spec.paused=false"
      kubectl -n "$ns" patch "$CLUSTER_RESOURCE" "$cluster" \
        --type merge -p '{"spec":{"paused":false}}'
    else
      log "$ns/$cluster already has spec.paused != true; no change needed."
    fi
  done < "$STATE_DIR/inventory.tsv"
}

cluster_was_cordoned_by_helper() {
  local ns="$1" cluster="$2"
  awk -F '\t' -v n="$ns" -v c="$cluster" '$1==n && $2==c {found=1} END{exit found?0:1}' \
    "$STATE_DIR/workers_changed.tsv" 2>/dev/null
}

was_preexisting_cordon() {
  local ns="$1" cluster="$2" node="$3"
  grep -Fqx -- "$ns"$'\t'"$cluster"$'\t'"$node" "$STATE_DIR/workers_preexisting_cordon.tsv" 2>/dev/null
}

uncordon_current_workers() {
  local ns cluster node unsched worker_count

  while IFS=$'\t' read -r ns cluster; do
    [[ -n "$ns" && -n "$cluster" ]] || continue

    if ! cluster_was_cordoned_by_helper "$ns" "$cluster"; then
      log "$ns/$cluster: helper did not newly cordon workers in this cycle; leaving current worker scheduling state unchanged."
      continue
    fi

    make_guest_kubeconfig "$ns" "$cluster"
    get_cluster_node_sets "$ns" "$cluster"
    worker_count="$(count_nonempty_lines < "$WORKER_REFS_FILE")"

    if [[ "$worker_count" -eq 0 ]]; then
      log "$ns/$cluster: no current worker nodeRefs; nothing to uncordon."
      continue
    fi

    while IFS= read -r node; do
      [[ -n "$node" ]] || continue

      kubectl --kubeconfig="$GUEST_KCFG" get node "$node" --request-timeout=15s >/dev/null 2>&1 \
        || die "Current worker $node is not reachable in $ns/$cluster. Refusing to continue startup automation."

      if was_preexisting_cordon "$ns" "$cluster" "$node"; then
        log "$ns/$cluster: preserving pre-existing cordon on current worker $node"
        continue
      fi

      unsched="$(kubectl --kubeconfig="$GUEST_KCFG" get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
      if [[ "$unsched" == "true" ]]; then
        log "$ns/$cluster: uncordoning CURRENT worker $node"
        kubectl --kubeconfig="$GUEST_KCFG" uncordon "$node"
      else
        log "$ns/$cluster: current worker $node is already schedulable; no change needed."
      fi
    done < "$WORKER_REFS_FILE"
  done < "$STATE_DIR/inventory.tsv"
}

startup_all() {
  startup_preflight

  log "Startup uses LIVE Cluster/Machine/Node state rather than requiring shutdown-time worker names."
  log "It will:"
  log "  1) unpause currently-paused recorded clusters except clusters that were pre-paused"
  log "  2) re-discover CURRENT workers and uncordon them only in clusters the helper cordoned"
  log "  3) preserve CURRENT workers whose exact node names were recorded as pre-existing cordons"
  log "It will NOT power on VMs, start WCP, or determine health. HEALTH_VERIFIED=YES is your acknowledgement."
  log "Recommended prerequisite order: vSAN/ESXi -> vCenter -> NSX -> Supervisor/WCP -> Supervisor Services -> VCF management/VSP -> VKS health."
  confirm "Proceed with live-state resume + uncordon?"

  resume_live_paused_clusters

  log "Waiting briefly for Cluster API reconciliation before reading current worker nodeRefs..."
  sleep 15

  uncordon_current_workers

  touch "$STATE_DIR/startup.complete"
  log "Startup reversal complete."
  log "Pre-existing paused clusters and pre-existing cordoned workers were intentionally preserved."
}

status_all() {
  supervisor_precheck
  log "State directory: $STATE_DIR"
  if [[ -f "$STATE_DIR/session.txt" ]]; then
    cat "$STATE_DIR/session.txt"
  else
    warn "No saved shutdown state exists at this path. Showing live discovery only."
  fi
  discover

  if [[ -d "$STATE_DIR" ]]; then
    printf '\nSaved changes:\n'
    printf '  workers changed by script: '; [[ -f "$STATE_DIR/workers_changed.tsv" ]] && count_nonempty_lines < "$STATE_DIR/workers_changed.tsv" || echo 0
    printf '  workers already cordoned:  '; [[ -f "$STATE_DIR/workers_preexisting_cordon.tsv" ]] && count_nonempty_lines < "$STATE_DIR/workers_preexisting_cordon.tsv" || echo 0
    printf '  clusters changed by script:'; [[ -f "$STATE_DIR/clusters_changed.tsv" ]] && printf ' '; [[ -f "$STATE_DIR/clusters_changed.tsv" ]] && count_nonempty_lines < "$STATE_DIR/clusters_changed.tsv" || echo ' 0'
    printf '  clusters already paused:   '; [[ -f "$STATE_DIR/clusters_preexisting_pause.tsv" ]] && count_nonempty_lines < "$STATE_DIR/clusters_preexisting_pause.tsv" || echo 0
    [[ -f "$STATE_DIR/cordon.complete" ]] && echo '  cordon phase: complete' || echo '  cordon phase: not complete'
    [[ -f "$STATE_DIR/pause.complete" ]] && echo '  pause phase:  complete' || echo '  pause phase:  not complete'
    [[ -f "$STATE_DIR/startup.complete" ]] && echo '  startup:      complete' || echo '  startup:      not complete'
  fi
}

case "$MODE" in
  guide)    guide ;;
  discover) discover ;;
  cordon)   cordon_all ;;
  pause)    pause_all ;;
  startup)  startup_all ;;
  status)   status_all ;;
  -h|--help|help|"") usage ;;
  *) usage; die "Unknown mode: $MODE" ;;
esac
