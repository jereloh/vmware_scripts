#!/usr/bin/env bash
#
# Interactive Supervisor pod cleanup
#
# Lists namespaces, lets you select one, then reviews failed pods one by one.
# Only typing "yes" requests normal deletion. The pod list refreshes after
# each deletion request.
#
# Requirements: kubectl access to the Supervisor, jq, column, and a terminal.
# This script does not check vCenter or VM power state.
#
# Script is AI-generated. 
# USE AT YOUR OWN RISK. Review each pod before answering "yes". 
# A deletion request does not guarantee cleanup has completed.
#
# Run a local copy:
#   bash supervisor-pods-review.sh
#
# Demo: run directly from a trusted URL without saving a .sh file:
#   curl -fsSL 'https://github.com/jereloh/vmware_scripts/supervisor-pods-review.sh' | bash
#
# Replace the example URL with the actual script URL. Review the remote
# script before piping it to Bash.
#
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v column >/dev/null || { echo "column is required"; exit 1; }
[[ -r /dev/tty ]] || { echo "Run this from an interactive terminal"; exit 1; }

# Discover namespaces and select one.
NAMESPACE_JSON=$(kubectl get namespaces -o json) || exit 1
mapfile -t NAMESPACES < <(
  jq -r '.items[].metadata.name' <<<"$NAMESPACE_JSON" | sort
)

((${#NAMESPACES[@]} > 0)) || { echo "No namespaces found"; exit 1; }

echo "Available namespaces:"
for i in "${!NAMESPACES[@]}"; do
  printf '%3d) %s\n' "$((i + 1))" "${NAMESPACES[$i]}"
done

read -r -p 'Select namespace number: ' SELECTION </dev/tty
if [[ ! "$SELECTION" =~ ^[0-9]+$ ]] ||
   (( SELECTION < 1 || SELECTION > ${#NAMESPACES[@]} )); then
  echo "Invalid selection"
  exit 1
fi
NS=${NAMESPACES[$((SELECTION - 1))]}

show_status() {
  local data
  data=$(kubectl get pods -n "$NS" -o json) || return 1

  jq -r '
    ["POD","PHASE","REASON","DELETE_REQUESTED"],
    (.items[]
     | [
         .metadata.name,
         (.status.phase // ""),
         (.status.reason // ""),
         (if .metadata.deletionTimestamp then "YES" else "NO" end)
       ])
    | @tsv
  ' <<<"$data" | column -t -s "$(printf '\t')"
}

SNAPSHOT=$(kubectl get pods -n "$NS" -o json) || exit 1

echo
echo "Current pods in $NS:"
show_status || exit 1

while IFS= read -r POD; do
  DATA=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) || continue
  REASON=$(jq -r '.status.reason // ""' <<<"$DATA")
  POD_UID=$(jq -r '.metadata.uid' <<<"$DATA")

  if ! jq -e '
    .status.phase == "Failed"
    and (.status.reason == "NotFound"
         or .status.reason == "ProviderFailed"
         or .status.reason == "PodVMAnnotationsMissing")
    and .metadata.deletionTimestamp == null
  ' <<<"$DATA" >/dev/null; then
    continue
  fi

  printf '\nNamespace: %s\nPod: %s\nReason: %s\n' "$NS" "$POD" "$REASON"
  read -r -p 'Delete this pod? Type yes: ' ANSWER </dev/tty
  [[ "$ANSWER" == yes ]] || { echo "Skipped"; continue; }

  CURRENT=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) || {
    echo "SKIP: pod no longer exists"
    continue
  }

  if ! jq -e --arg pod_uid "$POD_UID" --arg reason "$REASON" '
    .metadata.uid == $pod_uid
    and .metadata.deletionTimestamp == null
    and .status.phase == "Failed"
    and .status.reason == $reason
  ' <<<"$CURRENT" >/dev/null; then
    echo "SKIP: pod changed since the prompt"
    continue
  fi

  kubectl delete pod "$POD" -n "$NS" --wait=false || {
    echo "Deletion request failed; stopping"
    exit 1
  }

  echo
  echo "Refreshed status in $NS:"
  show_status || exit 1
done < <(
  jq -r '
    .items[]
    | select(.status.phase == "Failed")
    | select(.status.reason == "NotFound"
             or .status.reason == "ProviderFailed"
             or .status.reason == "PodVMAnnotationsMissing")
    | .metadata.name
  ' <<<"$SNAPSHOT"
)
