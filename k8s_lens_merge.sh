#!/bin/bash

# Define paths
LENS_KUBECONFIG_DIR="$HOME/.config/Lens/kubeconfigs/"
DEFAULT_KUBECONFIG="$HOME/.kube/config"
BACKUP_KUBECONFIG="$HOME/.kube/config.backup-$(date +%F-%H%M%S)"
TEMP_MERGED_KUBECONFIG="$HOME/.kube/temp-merged-kubeconfig.yaml"

# Backup existing kubeconfig before modifying
if [ -f "$DEFAULT_KUBECONFIG" ]; then
    echo "Backing up ~/.kube/config to: $BACKUP_KUBECONFIG"
    cp "$DEFAULT_KUBECONFIG" "$BACKUP_KUBECONFIG"
fi

# Function to check for orphaned contexts
cleanup_orphaned_contexts() {
    for FILE in "$LENS_KUBECONFIG_DIR"*.yaml; do
        # Skip backup files
        if [[ "$FILE" == *backup* ]]; then
            echo "Skipping backup file during cleanup: $FILE"
            continue
        fi

        CONTEXT_NAMES=$(yq e '.contexts[].name' "$FILE" 2>/dev/null)
        CLUSTER_NAMES=$(yq e '.clusters[].name' "$FILE" 2>/dev/null)

        for CONTEXT in $CONTEXT_NAMES; do
            CLUSTER_REF=$(yq e ".contexts[] | select(.name == \"$CONTEXT\").context.cluster" "$FILE" 2>/dev/null)
            if ! echo "$CLUSTER_NAMES" | grep -q "$CLUSTER_REF"; then
                echo "Removing orphaned context: $CONTEXT from $FILE"
                yq e "del(.contexts[] | select(.name == \"$CONTEXT\"))" -i "$FILE"
            fi
        done
    done
}

# Cleanup orphaned contexts before merging
echo "Cleaning up orphaned contexts in Lens kubeconfig files..."
cleanup_orphaned_contexts

# Function to rename duplicate cluster names to avoid overwriting
rename_duplicate_clusters() {
    for FILE in "$LENS_KUBECONFIG_DIR"*.yaml; do
        # Skip backup files
        if [[ "$FILE" == *backup* ]]; then
            echo "Skipping backup file during rename: $FILE"
            continue
        fi

        # Check cluster names
        CLUSTER_NAMES=$(yq e '.clusters[].name' "$FILE" 2>/dev/null)
        
        for CLUSTER_NAME in $CLUSTER_NAMES; do
            # Rename only if cluster name is exactly 'kubernetes' or doesn't already have unique suffix
            if [[ "$CLUSTER_NAME" == "kubernetes" ]]; then
                UNIQUE_ID=$(basename "$FILE" | cut -d '-' -f1)

                # Make sure we don't rename multiple times
                if ! echo "$CLUSTER_NAME" | grep -q "$UNIQUE_ID"; then
                    NEW_NAME="kubernetes-$UNIQUE_ID"
                    echo "Renaming cluster in $FILE to $NEW_NAME"

                    # Update cluster and context names
                    yq e "(.clusters[] | select(.name == \"$CLUSTER_NAME\") | .name) |= \"$NEW_NAME\"" -i "$FILE"
                    yq e "(.contexts[] | select(.context.cluster == \"$CLUSTER_NAME\") | .context.cluster) |= \"$NEW_NAME\"" -i "$FILE"
                fi
            fi
        done
    done
}

# Rename clusters to prevent overwrite issues
echo "Renaming duplicate clusters in Lens kubeconfigs..."
rename_duplicate_clusters

# List files being merged, excluding backups
echo "Merging the following kubeconfig files:"
KUBECONFIG_FILES=()
for FILE in "$LENS_KUBECONFIG_DIR"*.yaml; do
    if [[ "$FILE" == *backup* ]]; then
        echo "Skipping backup file in merge: $FILE"
        continue
    fi
    echo "- $FILE"
    KUBECONFIG_FILES+=("$FILE")
done
echo "- $DEFAULT_KUBECONFIG (existing kubeconfig)"

# Merge kubeconfig files with proper formatting
echo "Merging kubeconfigs..."
export KUBECONFIG=$(printf "%s:" "${KUBECONFIG_FILES[@]}")"$DEFAULT_KUBECONFIG"
kubectl config view --flatten > "$TEMP_MERGED_KUBECONFIG"

# Verify the merge before replacing the default kubeconfig
if [ -s "$TEMP_MERGED_KUBECONFIG" ]; then
    mv "$TEMP_MERGED_KUBECONFIG" "$DEFAULT_KUBECONFIG"
    echo "Successfully merged into: $DEFAULT_KUBECONFIG"
    echo "Backup created at: $BACKUP_KUBECONFIG"
else
    echo "Error: Merge failed or no kubeconfig files found."
fi

