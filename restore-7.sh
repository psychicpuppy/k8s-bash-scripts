
#!/usr/bin/env bash

set -euo pipefail

# === Configuration ===
BACKUP_FOLDER="$1"
LOG_FILE="restore.log"
REGION="us-gov-west-1"
INSTANCE_NAME="Restored-Instance"
DEVICE_NAME="/dev/xvdf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

cleanup_volume() {
    log "Cleaning up volume $1..."
    aws ec2 detach-volume --volume-id "$1" --region "$REGION" || true
    aws ec2 wait volume-available --volume-ids "$1" --region "$REGION" || true
    aws ec2 delete-volume --volume-id "$1" --region "$REGION" || true
    log "Volume $1 cleaned up."
}

trap 'error_exit "Restore process interrupted."' INT TERM

# === Validate Backup Folder ===
[ -z "$BACKUP_FOLDER" ] && error_exit "Backup folder is required."
[ -d "$BACKUP_FOLDER" ] || error_exit "Backup folder not found: $BACKUP_FOLDER"

log "Starting restore process using backup folder: $BACKUP_FOLDER"

# === Step 1: Extract Backup Metadata ===
AMI_ID=$(jq -r '.[0].ImageId' "$BACKUP_FOLDER/ami-metadata.json")
SNAPSHOT_ID=$(jq -r '.[0].SnapshotId' "$BACKUP_FOLDER/snapshot-metadata.json")
VOLUME_SIZE=$(jq -r '.[0].VolumeSize' "$BACKUP_FOLDER/snapshot-metadata.json")
ROOT_DEVICE=$(jq -r '.[0].RootDeviceName' "$BACKUP_FOLDER/ami-metadata.json")

log "Extracted backup metadata: AMI=$AMI_ID, Snapshot=$SNAPSHOT_ID, Volume Size=$VOLUME_SIZE"

# === Step 2: Initialize and Apply Terraform ===
log "Initializing Terraform..."
cd "$BACKUP_FOLDER/aws"
terraform init -reconfigure || error_exit "Failed to initialize Terraform."

log "Applying Terraform state..."
terraform apply -auto-approve || error_exit "Terraform apply failed."

INSTANCE_ID=$(terraform output -raw aws_instance_tfer--i-0eb70981d72e116ad_CJS-TEST-MACHINE_id)
[ -z "$INSTANCE_ID" ] && error_exit "Restored instance not found. Terraform may not have correctly applied changes."
log "Restored EC2 Instance ID: $INSTANCE_ID"

# === Step 3: Verify and Attach Backup Volume ===
AVAILABILITY_ZONE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

log "Creating EBS volume from snapshot..."
VOLUME_ID=$(aws ec2 create-volume --snapshot-id "$SNAPSHOT_ID" --availability-zone "$AVAILABILITY_ZONE" \
  --volume-type gp3 --region "$REGION" --query "VolumeId" --output text) || true

if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" == "null" ]; then
    log "Snapshot restore failed or returned no volume ID."
    echo "Snapshot restore failed. Would you like to restore from the disk image instead? (y/n): "
    read -r choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        log "User chose to restore from disk image."
        gunzip -c "$BACKUP_FOLDER/ec2-disk-backup.img.gz" | sudo dd of="$DEVICE_NAME" bs=1M status=progress || error_exit "Filesystem restore failed!"
        log "Filesystem restored from disk image."
        exit 0
    else
        error_exit "User declined disk image restore. Exiting."
    fi
fi

log "Created EBS Volume ID: $VOLUME_ID"

EXISTING_VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  "Name=attachment.device,Values=$DEVICE_NAME" --query "Volumes[0].VolumeId" --output text)

if [ "$EXISTING_VOLUME_ID" != "None" ] && [ "$EXISTING_VOLUME_ID" != "null" ]; then
    log "Detaching existing volume $EXISTING_VOLUME_ID from $DEVICE_NAME..."
    aws ec2 detach-volume --volume-id "$EXISTING_VOLUME_ID" --instance-id "$INSTANCE_ID" --region "$REGION"
    aws ec2 wait volume-available --volume-ids "$EXISTING_VOLUME_ID" --region "$REGION"
fi

log "Attaching volume $VOLUME_ID to instance $INSTANCE_ID..."
aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" --device "$DEVICE_NAME" --region "$REGION" \
  || (cleanup_volume "$VOLUME_ID" && error_exit "Failed to attach volume.")

log "Waiting for volume to attach..."
sleep 15

ATTACHMENT_STATE=$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].Attachments[0].State' --output text)
if [[ "$ATTACHMENT_STATE" != "attached" ]]; then
    cleanup_volume "$VOLUME_ID"
    echo "Volume attach failed. Would you like to restore from the disk image instead? (y/n): "
    read -r fallback_choice
    if [[ "$fallback_choice" =~ ^[Yy]$ ]]; then
        log "User chose fallback restore from disk image."
        gunzip -c "$BACKUP_FOLDER/ec2-disk-backup.img.gz" | sudo dd of="$DEVICE_NAME" bs=1M status=progress || error_exit "Filesystem restore failed!"
        log "Filesystem restored from disk image."
        exit 0
    else
        error_exit "User declined fallback restore."
    fi
fi

log "Volume successfully attached."
log "Restore process completed successfully!"
