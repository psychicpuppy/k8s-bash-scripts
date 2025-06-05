
#!/bin/bash
set -euo pipefail

REGION="us-gov-west-1"
MASTER_NAME="CJS-master"
WORKER_NAME_PREFIX="CJS-worker"
NUM_WORKERS=2

log() {
  echo "$(date '+%F %T') - $*"
}

terminate_instance_by_name() {
  local name="$1"
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --region "$REGION" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

  if [[ -n "$INSTANCE_IDS" ]]; then
    for id in $INSTANCE_IDS; do
      log "Terminating instance '$name' (ID: $id)..."
      aws ec2 terminate-instances --instance-ids "$id" --region "$REGION" >/dev/null
    done
  else
    log "No instance found with name '$name' to terminate."
  fi
}

log "Terminating master node..."
terminate_instance_by_name "$MASTER_NAME"

log "Terminating worker nodes..."
for i in $(seq 1 $NUM_WORKERS); do
  WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
  terminate_instance_by_name "$WORKER_NAME"
done

log "Teardown complete."
