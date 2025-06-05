
#!/bin/bash
set -euo pipefail

# --- CONFIGURATION ---
REGION="us-gov-west-1"
KEY_NAME="CJS KeyPair"
KEY_PATH="$HOME/.ssh/$KEY_NAME.pem"
VPC_ID="vpc-06de3363721772f48"
SUBNET_ID="subnet-06a1a43bbf9462394"
INSTANCE_TYPE="t3.medium"
UBUNTU_AMI="ami-07b49bf14f70d313b"

DATE_SUFFIX=$(date '+%Y%m%d')
MASTER_NAME="CJS-master-$DATE_SUFFIX"
WORKER_NAME_PREFIX="CJS-worker-$DATE_SUFFIX-"
NUM_WORKERS=2

# --- LOG FUNCTION ---
log() {
  local level="${1,,}"
  local timestamp
  timestamp=$(date '+%F %T')

  if [[ "$level" == "info" || "$level" == "error" || "$level" == "debug" ]]; then
    shift
  else
    level="info"
  fi

  case "$level" in
    error)
      echo "$timestamp - [ERROR] $*" >&2
      ;;
    debug)
      echo "$timestamp - [DEBUG] $*" >&2
      ;;
    info|*)
      echo "$timestamp - [INFO] $*"
      ;;
  esac
}

# --- READ AND ENCODE CERTIFICATE ---
CERT_PATH="./dodiis-artifactory.crt"
if [[ ! -f "$CERT_PATH" ]]; then
  log error "Certificate file '$CERT_PATH' not found in current directory."
  exit 1
fi

CERT_B64=$(base64 -w 0 < "$CERT_PATH")

# --- USER DATA TEMPLATE ---
USER_DATA=$(cat <<EOF
#!/bin/bash
set -euxo pipefail
set -x

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# IP forwarding
echo "net.ipv4.ip_forward=1" | tee /etc/sysctl.d/99-k8s-ip-forward.conf
sysctl --system

# Install dependencies
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common containerd ufw

# Disable UFW
ufw disable

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Add Kubernetes APT repository
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes components
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# Enable SSH
systemctl enable ssh
systemctl start ssh

# Install custom CA certificate
mkdir -p /usr/local/share/ca-certificates/
echo "$CERT_B64" | base64 -d > /usr/local/share/ca-certificates/dodiis-artifactory.crt
update-ca-certificates
EOF
)

# --- SECURITY GROUP SETUP ---
# (Security group logic unchanged — omitted here for brevity, but will be included in full in the next message)
# --- SECURITY GROUP ---
SG_NAME="CJS-K8s-SG"
log "Checking for existing Security Group named '$SG_NAME'..."
EXISTING_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --region "$REGION" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || true)

if [[ "$EXISTING_SG_ID" != "None" ]]; then
  SG_ID="$EXISTING_SG_ID"
  log "Using existing Security Group: $SG_ID"
else
  log "Creating new Security Group..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for CJS k8s cluster" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)
  log "Security Group created: $SG_ID"
fi

log "Setting Security Group inbound rules..."
declare -a PORTS_TCP=(22 6443 2379 2380 10250 10251 10252)
declare -a PORTS_UDP=(8472)

for port in "${PORTS_TCP[@]}"; do
  EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --region "$REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\` && IpProtocol=='tcp' && IpRanges[?CidrIp=='0.0.0.0/0']]" \
    --output text)
  if [[ -z "$EXISTS" ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$port" \
      --cidr "0.0.0.0/0" \
      --region "$REGION"
    log "TCP rule for port $port added"
  else
    log "TCP rule for port $port already exists — skipping..."
  fi
done

for port in "${PORTS_UDP[@]}"; do
  EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --region "$REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\` && IpProtocol=='udp' && IpRanges[?CidrIp=='0.0.0.0/0']]" \
    --output text)
  if [[ -z "$EXISTS" ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol udp \
      --port "$port" \
      --cidr "0.0.0.0/0" \
      --region "$REGION"
    log "UDP rule for port $port added"
  else
    log "UDP rule for port $port already exists — skipping..."
  fi
done

# --- INSTANCE LAUNCH FUNCTION ---
launch_instance() {
  local name="$1"
  local role="$2"

  log "debug" "Launching instance: $name ($role)..."

  local user_data_file
  user_data_file=$(mktemp)
  printf "%s\n" "$USER_DATA" > "$user_data_file"

  local output_file
  output_file=$(mktemp)

  if ! aws ec2 run-instances \
      --image-id "$UBUNTU_AMI" \
      --count 1 \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" \
      --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,AssociatePublicIpAddress=false,Groups=$SG_ID" \
      --user-data "file://$user_data_file" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Role,Value=$role}]" \
      --region "$REGION" \
      --output json > "$output_file"; then
    log error "Failed to launch instance $name"
    cat "$output_file"
    exit 1
  fi

  local instance_id
  instance_id=$(jq -r '.Instances[0].InstanceId' < "$output_file")

  log debug "$name launched with ID: $instance_id"
  echo "$instance_id"
}

# --- CREATE INSTANCES ---
MASTER_INSTANCE_ID=$(launch_instance "$MASTER_NAME" "master")
WORKER_INSTANCE_IDS=()
for i in $(seq 1 $NUM_WORKERS); do
  WORKER_NAME="${WORKER_NAME_PREFIX}${i}"
  id=$(launch_instance "$WORKER_NAME" "worker")
  WORKER_INSTANCE_IDS+=("$id")
done

# --- WAIT FOR INSTANCE STATUS OK ---
wait_for_instance() {
  local id="$1"
  aws ec2 wait instance-status-ok --instance-ids "$id" --region "$REGION"
}
log "Waiting for instances to become ready..."
wait_for_instance "$MASTER_INSTANCE_ID"
for id in "${WORKER_INSTANCE_IDS[@]}"; do
  wait_for_instance "$id"
done

# --- GET IP ADDRESSES ---
MASTER_IP=$(aws ec2 describe-instances \
  --instance-ids "$MASTER_INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

WORKER_IPS=()
for id in "${WORKER_INSTANCE_IDS[@]}"; do
  ip=$(aws ec2 describe-instances \
    --instance-ids "$id" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
  WORKER_IPS+=("$ip")
done

# --- INITIALIZE MASTER NODE AND SETUP CALICO ---
log "Initializing Kubernetes on master..."
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$MASTER_IP" <<'EOF'
sudo kubeadm init --pod-network-cidr=192.168.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
EOF

# --- RETRIEVE JOIN COMMAND ---
JOIN_CMD=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$MASTER_IP" \
  "kubeadm token create --print-join-command")

# --- JOIN WORKER NODES ---
log "Joining worker nodes..."
for ip in "${WORKER_IPS[@]}"; do
  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$ip" "sudo $JOIN_CMD"
done

# --- FINAL OUTPUT ---
log "Kubernetes cluster is ready!"
echo "Master IP: $MASTER_IP"
echo "Worker IPs:"
for ip in "${WORKER_IPS[@]}"; do
  echo " - $ip"
done


read -rp "Do you want to fetch the kubeconfig from the master node? (y/N): " fetch_kubeconfig

if [[ "$fetch_kubeconfig" =~ ^[Yy]$ ]]; then
  read -rp "Enter filename to save kubeconfig (leave blank to print to stdout): " kubeconfig_file

  # Fetch kubeconfig content from master node
  kubeconfig_content=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@"$MASTER_IP" "sudo cat /etc/kubernetes/admin.conf")

  if [[ -z "$kubeconfig_file" ]]; then
    echo "----- kubeconfig from master node -----"
    echo "$kubeconfig_content"
    echo "--------------------------------------"
  else
    echo "$kubeconfig_content" > "$kubeconfig_file"
    echo "kubeconfig saved to '$kubeconfig_file'"
  fi
else
  echo "Skipping kubeconfig fetch."
fi
