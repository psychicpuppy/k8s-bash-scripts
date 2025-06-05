#!/bin/bash

set -euo pipefail

KUBECONFIG_FILE="${HOME}/.kube/config"
BACKUP_FILE="${KUBECONFIG_FILE}.backup-$(date +%F-%H%M%S)"

echo "Backing up current kubeconfig to ${BACKUP_FILE}"
cp "${KUBECONFIG_FILE}" "${BACKUP_FILE}"

echo "Starting kubeconfig cleanup..."

# Orphaned context cleanup
orphans_removed=0
for ctx in $(kubectl config get-contexts -o name); do
    cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
    user=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.user}")
    if ! kubectl config get-clusters | grep -qx "${cluster}" || ! kubectl config get-users | grep -qx "${user}"; then
        echo "Removing orphaned context: ${ctx} (cluster: ${cluster}, user: ${user})"
        kubectl config delete-context "${ctx}" >/dev/null
        ((orphans_removed++))
    fi
done
echo "Orphaned contexts removed: ${orphans_removed}"

# Remove duplicate/backup clusters
clusters_removed=0
for cluster in $(kubectl config view -o jsonpath='{.clusters[*].name}'); do
    if [[ "$cluster" == *"-config.backup"* ]]; then
        echo "Removing backup/duplicate cluster: $cluster"
        kubectl config unset "clusters.${cluster}" >/dev/null
        ((clusters_removed++))
    fi
done
echo "Removed backup/duplicate clusters: ${clusters_removed}"

# Remove duplicate/backup users
users_removed=0
for user in $(kubectl config view -o jsonpath='{.users[*].name}'); do
    if [[ "$user" == *"-config.backup"* ]]; then
        echo "Removing backup/duplicate user: $user"
        kubectl config unset "users.${user}" >/dev/null
        ((users_removed++))
    fi
done
echo "Removed backup/duplicate users: ${users_removed}"

# Remove orphaned context kubernetes-admin@kubernetes if cluster is missing
if kubectl config get-contexts -o name | grep -qx "kubernetes-admin@kubernetes"; then
    cluster_exists=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='kubernetes')].name}" 2>/dev/null || true)
    if [[ -z "$cluster_exists" ]]; then
        echo "Removing orphaned default context: kubernetes-admin@kubernetes (cluster 'kubernetes' does not exist)"
        kubectl config delete-context kubernetes-admin@kubernetes >/dev/null || true
    fi
fi

# Create Lens-friendly contexts (lens-<cluster>-<user>)
echo "Creating Lens-friendly contexts..."
for ctx in $(kubectl config get-contexts -o name); do
    cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
    user=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.user}")
    lens_ctx="lens-${cluster}-${user}"
    if ! kubectl config get-contexts -o name | grep -qx "$lens_ctx"; then
        echo "Creating context: ${lens_ctx} (cluster: ${cluster}, user: ${user})"
        kubectl config set-context "${lens_ctx}" --cluster="${cluster}" --user="${user}" >/dev/null
    fi
done

fi
echo "Creating Lens-friendly contexts..."

current_set=false

kubectl config get-contexts --no-headers | while read -r line; do
  context_name=$(echo "$line" | awk '{print $1}')
  cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context_name')].context.cluster}")
  user_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context_name')].context.user}")
  
  # Sanitize names for Lens context
  lens_ctx_name="lens-$(echo $cluster_name | tr -c '[:alnum:]' '-')-$(echo $user_name | tr -c '[:alnum:]' '-')"
  
  kubectl config set-context "$lens_ctx_name" --cluster="$cluster_name" --user="$user_name" >/dev/null
  
  echo "Created context: $lens_ctx_name (cluster: $cluster_name, user: $user_name)"

  if ! $current_set; then
    kubectl config use-context "$lens_ctx_name" >/dev/null
    echo "Current context set to $lens_ctx_name"
    current_set=true
  fi
done

if ! $current_set; then
  echo "No Lens-friendly contexts created, current context unchanged."
fi


# Show summary
echo "Final kubeconfig summary (name:server):"
kubectl config view --flatten --output=yaml | grep -E 'name:|server:'

echo "Cleanup complete."

