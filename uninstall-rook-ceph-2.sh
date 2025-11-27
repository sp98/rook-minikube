#!/bin/bash

set -e

# Rook version
ROOK_VERSION=${ROOK_VERSION:-"v1.18.7"}

# Ceph version (image tag)
CEPH_VERSION=${CEPH_VERSION:-"v18.2.0"}

# Rook namespace
ROOK_CEPH_NAMESPACE=${ROOK_CEPH_NAMESPACE:-"rook-ceph"}

# Rook source directory
ROOK_SOURCE_DIR=${ROOK_SOURCE_DIR:-"$HOME/dev/go/src/github.com/rook/rook"}

# Custom build flag
USE_CUSTOM_BUILD=${USE_CUSTOM_BUILD:-"false"}

# Custom image tag
CUSTOM_IMAGE_TAG=${CUSTOM_IMAGE_TAG:-"local-build"}

# Build Registry to build local images labeled as local/ceph-<arch>
BUILD_REGISTRY=${BUILD_REGISTRY:-"local"}

# Container runtime (docker or podman)
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-"podman"}

# Get the directory where the script itself resides
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"


ROOK_DATA_PATH="/var/lib/rook"
CLEANUP_JOB_NAME_PREFIX="cluster-cleanup-job"
TIMEOUT_SECONDS=180 # 3 minutes timeout
ROOK_IMAGE="quay.io/sp1098/rook:local" 


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Rook version
ROOK_VERSION=${ROOK_VERSION:-"v1.14.9"}

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup_rook_artifacts() {
  print_info "Deleting Rook Ceph CRDs, common resources, and operator..." 
  kubectl delete -f "$ROOK_SOURCE_DIR/deploy/examples/crds.yaml"
  # kubectl delete -f "$ROOK_SOURCE_DIR/deploy/examples/common.yaml"
  kubectl delete -f "$ROOK_SOURCE_DIR/deploy/examples/csi-operator.yaml"
  kubectl delete -f "$ROOK_SOURCE_DIR/deploy/examples/operator.yaml"
  kubectl delete -f "$ROOK_SOURCE_DIR/deploy/examples/toolbox.yaml"
}

# Delete Ceph cluster
delete_ceph_cluster() {
    print_info "Deleting Ceph cluster..."
    # --- Delete CephFilesystems ---
    print_info "Deleting CephFilesystems..."
    CEPH_FILESYSTEMS=$(kubectl get cephfilesystem.ceph.rook.io -n "${ROOK_CEPH_NAMESPACE}" -o custom-columns=NAME:.metadata.name --no-headers)
    if [ -n "$CEPH_FILESYSTEMS" ]; then
    for fs in $CEPH_FILESYSTEMS; do
        print_info "Deleting CephFilesystem: $fs"
        kubectl delete cephfilesystem.ceph.rook.io "$fs" -n "${ROOK_CEPH_NAMESPACE}"
    done
    else
    print_info "No CephFilesystems found."
    fi

    # --- Delete CephObjectStores ---
    print_info "Deleting CephObjectStores..."
    CEPH_OBJECTSTORES=$(kubectl get cephobjectstore.ceph.rook.io -n "${ROOK_CEPH_NAMESPACE}" -o custom-columns=NAME:.metadata.name --no-headers)
    if [ -n "$CEPH_OBJECTSTORES" ]; then
    for os in $CEPH_OBJECTSTORES; do
        print_info "Deleting CephObjectStore: $os"
        kubectl delete cephobjectstore.ceph.rook.io "$os" -n "${ROOK_CEPH_NAMESPACE}"
    done
    else
    print_info "No CephObjectStores found."
    fi

    # --- Delete CephBlockPools ---
    print_info "Deleting CephBlockPools..."
    CEPH_BLOCKPOOLS=$(kubectl get cephblockpool.ceph.rook.io -n "${ROOK_CEPH_NAMESPACE}" -o custom-columns=NAME:.metadata.name --no-headers)
    if [ -n "$CEPH_BLOCKPOOLS" ]; then
    for bp in $CEPH_BLOCKPOOLS; do
        print_info "Deleting CephBlockPool: $bp"
        kubectl delete cephblockpool.ceph.rook.io "$bp" -n "${ROOK_CEPH_NAMESPACE}"
    done
    else
    print_info "No CephBlockPools found."
    fi

    # Step 1: Enable cleanup policy on the CephCluster CRD
    print_info "Enabling cleanup policy on the CephCluster CRD..."
    CEPH_CLUSTER_NAME=$(kubectl -n "$ROOK_CEPH_NAMESPACE" get cephcluster -o jsonpath='{.items[0].metadata.name}')
    kubectl -n "$ROOK_CEPH_NAMESPACE" patch cephcluster "$CEPH_CLUSTER_NAME" --type merge -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'
    if [ $? -ne 0 ]; then
        print_info "Error enabling cleanup policy. Exiting."
        exit 1
    fi
    print_info "Cleanup policy enabled. Waiting for a few seconds..."
    sleep 5

    # Step 2: Delete the CephCluster CRD
    print_info "Deleting the CephCluster CRD..."
    kubectl -n "$ROOK_CEPH_NAMESPACE" delete cephcluster "$CEPH_CLUSTER_NAME"
    if [ $? -ne 0 ]; then
        print_info "Error deleting CephCluster CRD. Exiting."
        exit 1
    fi
    print_info "CephCluster CRD deletion initiated. Waiting for cleanup jobs to complete..."
}


# Clean up namespace
cleanup_namespace() {
    print_info "Cleaning up rook-ceph namespace..."
    print_info "Deleting the Rook Ceph namespace..."
    kubectl delete namespace "$ROOK_CEPH_NAMESPACE" --grace-period=0 --force --wait=false
    if [ $? -ne 0 ]; then
        print_info "Error deleting Rook Ceph namespace. Exiting."
        exit 1
    fi
    print_info "Rook Ceph namespace deletion initiated."
    sleep 10

    print_info "Checking for and removing finalizers if namespace is stuck..."
    NAMESPACE_STATUS=$(kubectl get ns "$ROOK_CEPH_NAMESPACE" -o jsonpath='{.status.phase}')
    if [[ "$NAMESPACE_STATUS" == "Terminating" ]]; then
        print_info "Namespace $ROOK_CEPH_NAMESPACE is in Terminating state. Attempting to remove finalizers."
        kubectl get namespace "$ROOK_CEPH_NAMESPACE" -o json | \
        jq 'del(.spec.finalizers[] | select(. == "kubernetes"))' | \
        kubectl replace --raw "/api/v1/namespaces/$ROOK_CEPH_NAMESPACE/finalize" -f -
    fi
}


wait_for_cleanup() {
  echo "Waiting for Rook-Ceph cleanup jobs to complete..."
  # Get the number of Minikube nodes
  NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)

  # Loop until all cleanup jobs are completed
  while true; do
      COMPLETED_JOBS=$(kubectl get jobs -n "${ROOK_CEPH_NAMESPACE}" -l app=rook-ceph-cleanup -o jsonpath='{.items[?(@.status.succeeded==1)].metadata.name}' | wc -w)

      if [[ "${COMPLETED_JOBS}" -eq "${NODE_COUNT}" ]]; then
          echo "All ${NODE_COUNT} Rook-Ceph cleanup jobs have completed."
          break
      else
          echo "Waiting for cleanup jobs... ${COMPLETED_JOBS}/${NODE_COUNT} completed."
          sleep 10 # Wait for 10 seconds before checking again
      fi
  done

  echo "Rook-Ceph cleanup job waiting complete."
}


# Clean up data on nodes
cleanup_data() {
    print_info "Cleaning up Ceph data on Minikube node..."
    echo "Starting cleanup of Rook Ceph data on Minikube nodes."

    # Get a list of Minikube nodes
    NODES=$(kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers)

    for NODE in $NODES; do
        print_info "Cleaning up data on node: $NODE"

        # Delete the Rook data directory
        print_info "Deleting $ROOK_DATA_PATH on $NODE..."
        minikube ssh -n "$NODE" -- "sudo rm -rf $ROOK_DATA_ docker rmi $ROOK_IMAGE"

        # If you were using specific devices for OSDs, you might need to wipe them.
        # This example assumes you are using hostPath and not dedicated devices.
        # If you used devices, you would need to identify and wipe them on each node.
        # Example for wiping a device (use with extreme caution):
        # minikube ssh -- "sudo sgdisk --zap-all /dev/sdX" # Replace sdX with the actual device name

        print_info "Cleanup on $NODE complete."
    done

    kubectl delete pv --all --force
    print_info "Cleanup of Rook Ceph data on all Minikube nodes finished."

    print_info "Data cleanup complete!"
}

clean_terminating_pods() {
    # Get all pods in Terminating state within the current namespace
    TERMINATING_PODS=$(kubectl get pods -n "$ROOK_CEPH_NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
    
    # Check if there are any terminating pods
    if [[ -n "$TERMINATING_PODS" ]]; then
        print_info "Found terminating pods in $ROOK_CEPH_NAMESPACE: $TERMINATING_PODS"
        # Loop through each terminating pod and force delete it
        for POD in $TERMINATING_PODS; do
            print_info "Force deleting pod: $POD in namespace: $NAMESPACE"
            kubectl delete pod "$POD" -n "$ROOK_CEPH_NAMESPACE" --grace-period=0 --force
        done
    else
        print_info "No terminating pods found in namespace: $ROOK_CEPH_NAMESPACE"
    fi
}


# Main uninstallation flow
main() {
    print_warn "This will uninstall Rook Ceph from your cluster"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Uninstallation cancelled"
        exit 0
    fi

    delete_ceph_cluster
    wait_for_cleanup
    cleanup_rook_artifacts
    cleanup_namespace
    clean_terminating_pods
    cleanup_data

    print_info "Uninstallation complete!"
}

# Run main function
main