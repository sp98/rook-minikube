#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
OBJECT_STORE_NAME=${OBJECT_STORE_NAME:-"my-store"}
OBJECT_STORE_USER=${OBJECT_STORE_USER:-"my-user"}
NAMESPACE=${NAMESPACE:-"rook-ceph"}
SAMPLE_APP_NAMESPACE=${SAMPLE_APP_NAMESPACE:-"default"}

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

# Delete sample applications
cleanup_sample_apps() {
    print_info "Cleaning up sample applications..."

    # Delete job
    kubectl -n $SAMPLE_APP_NAMESPACE delete job s3-test-job 2>/dev/null || print_warn "Job not found"

    # Delete pod
    kubectl -n $SAMPLE_APP_NAMESPACE delete pod s3-curl-test 2>/dev/null || print_warn "Pod not found"

    # Delete configmap
    kubectl -n $SAMPLE_APP_NAMESPACE delete configmap s3-test-script 2>/dev/null || print_warn "ConfigMap not found"

    # Delete secret
    kubectl -n $SAMPLE_APP_NAMESPACE delete secret s3-credentials 2>/dev/null || print_warn "Secret not found"

    print_info "Sample applications cleaned up!"
}

# Delete object store user
delete_object_store_user() {
    print_info "Deleting object store user: $OBJECT_STORE_USER..."

    kubectl -n $NAMESPACE delete cephobjectstoreuser $OBJECT_STORE_USER 2>/dev/null || print_warn "User not found"

    print_info "Object store user deleted!"
}

# Delete object store
delete_object_store() {
    print_info "Deleting object store: $OBJECT_STORE_NAME..."

    kubectl -n $NAMESPACE delete cephobjectstore $OBJECT_STORE_NAME 2>/dev/null || print_warn "Object store not found"

    print_info "Waiting for RGW pods to terminate..."
    sleep 10

    print_info "Object store deleted!"
}

# Main cleanup
main() {
    print_warn "This will delete the CephObjectStore and all sample applications"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Cleanup cancelled"
        exit 0
    fi

    cleanup_sample_apps
    delete_object_store_user
    delete_object_store

    print_info "Cleanup complete!"
    echo ""
    echo "To verify cleanup:"
    echo "  kubectl -n $NAMESPACE get cephobjectstore"
    echo "  kubectl -n $NAMESPACE get cephobjectstoreuser"
    echo "  kubectl -n $NAMESPACE get pods -l app=rook-ceph-rgw"
}

# Run main function
main
