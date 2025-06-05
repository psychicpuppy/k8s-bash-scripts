#!/bin/bash
set -euo pipefail

# -------- Config --------
REGION="us-gov-west-1"
KEY_NAME="CJS KeyPair"
DEFAULT_KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"
RETRY_MAX=5
RETRY_WAIT=10  # seconds initial wait for retry backoff

# -------- Logging --------
log() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" | tee -a "$BACKUP_DIR/backup.log" >&2
}

# -------- Usage --------
usage() {
  echo "Usage: $0 --master-ip=<IP> --backup-name=<name> [--key-path=<path>] [--skip-dd]"
  echo
  echo "  --master-ip       IP address of the Kubernetes control plane node"
  echo "  --backup-name     Name for the backup folder and tarball"
  echo "  --key-path        Path to SSH private key (default: ~/.ssh/CJS KeyPair.pem)"
  echo "  --skip-dd         Skip disk image backups (but still take EBS snapshots)"
  exit 1
}

# -------- Functions --------

get_worker_nodes() {
  local master_ip=$1
  log INFO "Querying control plane node $master_ip for worker node IPs..."
  (ssh-keygen -f ~/.ssh/known_hosts -R "$master_ip" 2>/dev/null || true) >&2

  local master_node_name
  master_node_name=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "ubuntu@$master_ip" \
    "kubectl get nodes -o json | jq -r '
      .items[] |
      select(.status.addresses[]?.address == \"$master_ip\") |
      .metadata.name'")

  log INFO "Master node name identified as: $master_node_name"

  local workers
  workers=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "ubuntu@$master_ip" \
    "kubectl get nodes -o json | jq -r '
      .items[] |
      select(.metadata.name != \"$master_node_name\") |
      .status.addresses[] |
      select(.type == \"InternalIP\") |
      .address'")

  log INFO "Worker node IPs found: $workers"

  for ip in $workers; do
    local worker_instance_id
    worker_instance_id=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=private-ip-address,Values=$ip" \
      --query 'Reservations[].Instances[].InstanceId' --output text)
    log INFO "$ip,$worker_instance_id,worker-node"
    echo "$ip,$worker_instance_id,worker-node"
  done
}

take_snapshot() {
  local ip="$1"
  local instance_id="$2"
  local name="$3"
  local snapshot_log="$BACKUP_DIR/$ip.snapshot.log"
  local snapshot_file="$BACKUP_DIR/$ip.snapshot"
  local snapshot_id=""
  local attempt=1
  local wait_time=$RETRY_WAIT

  : > "$snapshot_log"

  while [[ $attempt -le $RETRY_MAX ]]; do
    log INFO "Attempt $attempt: Creating snapshot for $ip ($instance_id, $name)" | tee -a "$snapshot_log"

    snapshot_id=$(aws ec2 create-snapshot \
      --region "$REGION" \
      --description "Backup snapshot for $name ($ip, $instance_id) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      --volume-id "$(aws ec2 describe-instances --region "$REGION" --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)" \
      --query SnapshotId --output text 2>>"$snapshot_log") || true

    if [[ -n "$snapshot_id" ]]; then
      log INFO "Snapshot $snapshot_id started for $ip ($instance_id)" | tee -a "$snapshot_log"

      aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$snapshot_id" >>"$snapshot_log" 2>&1
      if [[ $? -eq 0 ]]; then
        echo "$instance_id,$ip,$name,$snapshot_id" >> "$BACKUP_DIR/snapshots.manifest"
        echo "$snapshot_id" > "$snapshot_file"
        log INFO "Snapshot $snapshot_id completed for $ip ($instance_id)" | tee -a "$snapshot_log"
        return 0
      else
        log WARN "Snapshot $snapshot_id failed to complete for $ip ($instance_id)" | tee -a "$snapshot_log"
      fi
    else
      log WARN "Snapshot creation failed for $ip ($instance_id)" | tee -a "$snapshot_log"
    fi

    sleep "$wait_time"
    attempt=$((attempt + 1))
    wait_time=$((wait_time * 2))
  done

  log ERROR "Snapshot creation failed after $RETRY_MAX attempts for $ip ($instance_id)" | tee -a "$snapshot_log"
  return 1
}

backup_disk() {
  local ip="$1"
  local name="$2"
  local done_file="$BACKUP_DIR/$ip.done"
  local node_log="$BACKUP_DIR/$ip.log"
  local node_status="$BACKUP_DIR/$ip.status"
  local image="$BACKUP_DIR/$ip.img"

  if [[ -f "$done_file" ]]; then
    log INFO "Skipping $ip ($name) – already backed up"
    return
  fi

  log INFO "Backing up $ip ($name)..."
  ssh-keygen -f ~/.ssh/known_hosts -R "$ip" 2>/dev/null || true
  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "ubuntu@$ip" "sudo dd if=/dev/nvme0n1 bs=64K status=progress" \
    | dd of="$image" bs=64K status=progress conv=fsync > "$node_log" 2>&1

  local status=$?
  echo "$status" > "$node_status"
  if [[ "$status" -eq 0 ]]; then
    touch "$done_file"
    log INFO "Backup of $ip ($name) completed"
  else
    log ERROR "Backup of $ip ($name) failed (code $status). See $node_log"
  fi
}

backup_etcd() {
  local master_ip="$1"
  log INFO "Starting etcd snapshot from control plane node $master_ip..."
  local etcd_snapshot="$BACKUP_DIR/etcd-backup.db"
  local etcd_log="$BACKUP_DIR/etcd.log"

  ssh-keygen -f ~/.ssh/known_hosts -R "$CONTROL_PLANE_IP" 2>/dev/null || true

  if ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "ubuntu@$master_ip" command -v etcdctl >/dev/null ; then
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "ubuntu@$master_ip" bash -c "'
      set -e
      export ETCDCTL_API=3
      sudo etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        snapshot save /tmp/etcd-backup.db
      cat /tmp/etcd-backup.db
    '" > "$etcd_snapshot" 2> "$etcd_log"

    if [[ -s "$etcd_snapshot" ]]; then
      log INFO "etcd snapshot saved to $etcd_snapshot"
    else
      log WARN "etcd snapshot empty or failed. Check $etcd_log"
    fi
  else
    log WARN "etcdctl not found on control plane node. Skipping etcd snapshot."
  fi
}

run_terraformer() {
  log INFO "Running Terraformer to export EC2 infrastructure..."
  cd "$BACKUP_DIR"
  local instance_ids
  instance_ids=$(printf "%s\n" "${NODES[@]}" | cut -d',' -f2 | paste -sd',' -)
  terraformer import aws --resources=ec2,vpc,subnet,security_group,instance \
    --regions="$REGION" \
    --filter=Name=id;Value="$instance_ids" \
    > terraformer.log 
  cd - >/dev/null
}

compress_backup() {
  log INFO "Compressing backup directory into tarball..."
  local tarball="${BACKUP_DIR}.tar.gz"
  tar -czf "$tarball" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"

  if [[ -f "$tarball" ]]; then
    log INFO "Cluster backup completed and archived at $tarball"
  else
    log ERROR "Backup tarball creation failed!"
    exit 1
  fi
}

# -------- Main Script --------
main() {
  CONTROL_PLANE_IP=""
  BACKUP_NAME=""
  KEY_PATH="$DEFAULT_KEY_PATH"
  SKIP_DD=false

  for arg in "$@"; do
    case $arg in
      --master-ip=*) CONTROL_PLANE_IP="${arg#*=}" ;;
      --backup-name=*) BACKUP_NAME="${arg#*=}" ;;
      --key-path=*) KEY_PATH="${arg#*=}" ;;
      --skip-dd) SKIP_DD=true ;;
      *) echo "[ERROR] Unknown argument: $arg"; usage ;;
    esac
  done

  if [[ -z "$CONTROL_PLANE_IP" || -z "$BACKUP_NAME" ]]; then
    echo "[ERROR] Missing required arguments"
    usage
  fi

  BACKUP_DIR="$$BACKUP_NAME"
  mkdir -p "$BACKUP_DIR"

  log INFO "Starting Kubernetes cluster backup for control plane $CONTROL_PLANE_IP"

  local worker_ips
  worker_ips=$(get_worker_nodes "$CONTROL_PLANE_IP")

  NODES=()

  local control_instance_id
  control_instance_id=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=private-ip-address,Values=$CONTROL_PLANE_IP" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  NODES+=("$CONTROL_PLANE_IP,$control_instance_id,control-plane")

  for ip in $worker_ips; do
    local worker_instance_id
    worker_instance_id=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=private-ip-address,Values=$ip" \
      --query 'Reservations[].Instances[].InstanceId' --output text)
    NODES+=("$ip,$worker_instance_id,worker-node")
  done

  log INFO "Starting parallel snapshots for all nodes..."
  SNAPSHOT_MANIFEST="$BACKUP_DIR/snapshots.manifest"
  : > "$SNAPSHOT_MANIFEST"

  for node in "${NODES[@]}"; do
    IFS=',' read -r ip instance_id name <<< "$node"
    (
      if ! take_snapshot "$ip" "$instance_id" "$name"; then
        log ERROR "Snapshot failed for $ip ($instance_id)"
      fi
    ) &
  done
  log INFO "Waiting for snapshots to complete . . . "
  wait
  log INFO "All snapshot operations completed."

  if [[ "$SKIP_DD" == false ]]; then
    log INFO "Starting parallel disk backups of all nodes..."
    for node in "${NODES[@]}"; do
      IFS=',' read -r ip id name <<< "$node"
      backup_disk "$ip" "$name" &
    done
    log INFO "Waiting for disk backups to complete . . . "
    wait
  else
    log INFO "Skipping disk backups due to --skip-dd flag"
  fi

  backup_etcd "$CONTROL_PLANE_IP"
  run_terraformer
  compress_backup

  log INFO "Backup process finished."
}

main "$@"

