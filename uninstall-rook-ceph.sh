#!/bin/bash

set -e

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

# Delete Ceph cluster
delete_ceph_cluster() {
    print_info "Deleting Ceph cluster..."

    if kubectl get namespace rook-ceph &> /dev/null; then
        # Delete the cluster CR
        kubectl -n rook-ceph delete cephcluster --all --wait=true --timeout=300s 2>/dev/null || print_warn "No CephCluster found"

        # Delete block pools
        kubectl -n rook-ceph delete cephblockpool --all --wait=true --timeout=60s 2>/dev/null || print_warn "No CephBlockPool found"

        # Delete object stores
        kubectl -n rook-ceph delete cephobjectstore --all --wait=true --timeout=60s 2>/dev/null || print_warn "No CephObjectStore found"

        # Delete filesystem
        kubectl -n rook-ceph delete cephfilesystem --all --wait=true --timeout=60s 2>/dev/null || print_warn "No CephFilesystem found"

        print_info "Ceph cluster deleted!"
    else
        print_warn "rook-ceph namespace not found, skipping cluster deletion"
    fi
}

# Delete Rook operator
delete_rook_operator() {
    print_info "Deleting Rook operator..."

    # Delete operator
    kubectl delete -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml 2>/dev/null || print_warn "Operator already deleted"

    # Delete common resources
    kubectl delete -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/common.yaml 2>/dev/null || print_warn "Common resources already deleted"

    # Delete CRDs
    kubectl delete -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/crds.yaml 2>/dev/null || print_warn "CRDs already deleted"

    print_info "Rook operator deleted!"
}

# Clean up namespace
cleanup_namespace() {
    print_info "Cleaning up rook-ceph namespace..."

    if kubectl get namespace rook-ceph &> /dev/null; then
        # Remove finalizers from any stuck resources
        for resource in $(kubectl api-resources --verbs=list --namespaced -o name); do
            kubectl -n rook-ceph get "$resource" -o name 2>/dev/null | while read -r obj; do
                kubectl -n rook-ceph patch "$obj" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
        done

        # Delete namespace
        kubectl delete namespace rook-ceph --wait=true --timeout=120s 2>/dev/null || print_warn "Namespace deletion timed out"

        print_info "Namespace cleaned up!"
    else
        print_warn "rook-ceph namespace not found"
    fi
}

# Clean up data on nodes
cleanup_data() {
    print_info "Cleaning up Ceph data on Minikube node..."

    # SSH into minikube and clean up data directories
    minikube ssh "sudo rm -rf /var/lib/rook" 2>/dev/null || print_warn "Could not clean /var/lib/rook"

    print_info "Data cleanup complete!"
}

# Ask about deleting Minikube
delete_minikube() {
    read -p "Do you want to delete the entire Minikube cluster? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting Minikube cluster..."
        minikube delete
        print_info "Minikube cluster deleted!"
    else
        print_info "Keeping Minikube cluster"
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
    delete_rook_operator
    cleanup_namespace
    cleanup_data
    delete_minikube

    print_info "Uninstallation complete!"
}

# Run main function
main
