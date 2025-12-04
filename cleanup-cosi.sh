#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load config.env if exists
if [ -f "$SCRIPT_DIR/config.env" ]; then
    echo "Loading configuration from config.env..."
    source "$SCRIPT_DIR/config.env"
fi

# Configuration
OBJECT_STORE_NAME=${OBJECT_STORE_NAME:-"my-store"}
ROOK_CEPH_NAMESPACE=${ROOK_CEPH_NAMESPACE:-"rook-ceph"}
SAMPLE_APP_NAMESPACE=${SAMPLE_APP_NAMESPACE:-"default"}
COSI_USER=${COSI_USER:-"cosi"}
BUCKET_CLASS_NAME=${BUCKET_CLASS_NAME:-"sample-bcc"}
BUCKET_ACCESS_CLASS_NAME=${BUCKET_ACCESS_CLASS_NAME:-"sample-bac"}
BUCKET_CLAIM_NAME=${BUCKET_CLAIM_NAME:-"cosi-bucket"}
BUCKET_ACCESS_NAME=${BUCKET_ACCESS_NAME:-"cosi-bucket-access"}

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

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Delete BucketAccess
delete_bucket_access() {
    print_header "Deleting BucketAccess: $BUCKET_ACCESS_NAME"

    if kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME &> /dev/null; then
        print_info "Deleting BucketAccess..."
        kubectl -n $SAMPLE_APP_NAMESPACE delete bucketaccess $BUCKET_ACCESS_NAME --timeout=60s || {
            print_warn "Failed to delete BucketAccess gracefully, forcing deletion..."
            kubectl -n $SAMPLE_APP_NAMESPACE delete bucketaccess $BUCKET_ACCESS_NAME --force --grace-period=0 || true
        }
        print_info "BucketAccess deleted!"
    else
        print_info "BucketAccess not found, skipping"
    fi
}

# Delete BucketClaim
delete_bucket_claim() {
    print_header "Deleting BucketClaim: $BUCKET_CLAIM_NAME"

    if kubectl -n $SAMPLE_APP_NAMESPACE get bucketclaim $BUCKET_CLAIM_NAME &> /dev/null; then
        print_info "Deleting BucketClaim..."
        kubectl -n $SAMPLE_APP_NAMESPACE delete bucketclaim $BUCKET_CLAIM_NAME --timeout=60s || {
            print_warn "Failed to delete BucketClaim gracefully, forcing deletion..."
            kubectl -n $SAMPLE_APP_NAMESPACE delete bucketclaim $BUCKET_CLAIM_NAME --force --grace-period=0 || true
        }
        print_info "BucketClaim deleted!"
    else
        print_info "BucketClaim not found, skipping"
    fi
}

# Delete BucketAccessClass
delete_bucket_access_class() {
    print_header "Deleting BucketAccessClass: $BUCKET_ACCESS_CLASS_NAME"

    if kubectl get bucketaccessclass $BUCKET_ACCESS_CLASS_NAME &> /dev/null; then
        print_info "Deleting BucketAccessClass..."
        kubectl delete bucketaccessclass $BUCKET_ACCESS_CLASS_NAME --timeout=60s || {
            print_warn "Failed to delete BucketAccessClass gracefully, forcing deletion..."
            kubectl delete bucketaccessclass $BUCKET_ACCESS_CLASS_NAME --force --grace-period=0 || true
        }
        print_info "BucketAccessClass deleted!"
    else
        print_info "BucketAccessClass not found, skipping"
    fi
}

# Delete BucketClass
delete_bucket_class() {
    print_header "Deleting BucketClass: $BUCKET_CLASS_NAME"

    if kubectl get bucketclass $BUCKET_CLASS_NAME &> /dev/null; then
        print_info "Deleting BucketClass..."
        kubectl delete bucketclass $BUCKET_CLASS_NAME --timeout=60s || {
            print_warn "Failed to delete BucketClass gracefully, forcing deletion..."
            kubectl delete bucketclass $BUCKET_CLASS_NAME --force --grace-period=0 || true
        }
        print_info "BucketClass deleted!"
    else
        print_info "BucketClass not found, skipping"
    fi
}

# Delete COSI user
delete_cosi_user() {
    print_header "Deleting COSI User: $COSI_USER"

    if kubectl -n $ROOK_CEPH_NAMESPACE get cephobjectstoreuser $COSI_USER &> /dev/null; then
        print_info "Deleting CephObjectStoreUser..."
        kubectl -n $ROOK_CEPH_NAMESPACE delete cephobjectstoreuser $COSI_USER --timeout=60s || {
            print_warn "Failed to delete CephObjectStoreUser gracefully, forcing deletion..."
            kubectl -n $ROOK_CEPH_NAMESPACE delete cephobjectstoreuser $COSI_USER --force --grace-period=0 || true
        }
        print_info "COSI user deleted!"
    else
        print_info "COSI user not found, skipping"
    fi

    # Delete user secret if it still exists
    secret_name="rook-ceph-object-user-$OBJECT_STORE_NAME-$COSI_USER"
    if kubectl -n $ROOK_CEPH_NAMESPACE get secret $secret_name &> /dev/null; then
        print_info "Deleting COSI user secret..."
        kubectl -n $ROOK_CEPH_NAMESPACE delete secret $secret_name || true
    fi
}

# Delete CephCOSIDriver
delete_cosi_driver() {
    print_header "Deleting CephCOSIDriver"

    if kubectl -n $ROOK_CEPH_NAMESPACE get cephcosidriver ceph-cosi-driver &> /dev/null; then
        print_info "Deleting CephCOSIDriver..."
        kubectl -n $ROOK_CEPH_NAMESPACE delete cephcosidriver ceph-cosi-driver --timeout=60s || {
            print_warn "Failed to delete CephCOSIDriver gracefully, forcing deletion..."
            kubectl -n $ROOK_CEPH_NAMESPACE delete cephcosidriver ceph-cosi-driver --force --grace-period=0 || true
        }
        print_info "CephCOSIDriver deleted!"
    else
        print_info "CephCOSIDriver not found, skipping"
    fi

    # Delete COSI driver deployment if it still exists
    if kubectl -n $ROOK_CEPH_NAMESPACE get deployment ceph-cosi-driver &> /dev/null; then
        print_info "Deleting COSI driver deployment..."
        kubectl -n $ROOK_CEPH_NAMESPACE delete deployment ceph-cosi-driver || true
    fi
}

# Optionally uninstall COSI controller
uninstall_cosi_controller() {
    print_header "COSI Controller Cleanup (Optional)"

    # Ask user if they want to remove COSI controller
    read -p "Do you want to remove the COSI Controller? This affects all COSI resources in the cluster. (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Removing COSI Controller..."
        kubectl delete -k github.com/kubernetes-sigs/container-object-storage-interface-controller || true

        print_info "Removing COSI API CRDs..."
        kubectl delete -k github.com/kubernetes-sigs/container-object-storage-interface-api || true

        print_info "COSI Controller and API removed!"
    else
        print_info "Skipping COSI Controller removal"
        print_info "The COSI Controller and CRDs are still installed and can be used for other applications"
    fi
}

# Main execution
main() {
    print_info "Starting COSI cleanup..."
    echo ""

    # Delete resources in reverse order of creation
    delete_bucket_access
    delete_bucket_claim
    delete_bucket_access_class
    delete_bucket_class
    delete_cosi_user
    delete_cosi_driver
    uninstall_cosi_controller

    print_info "COSI cleanup complete!"
    echo ""
    print_info "Note: The CephObjectStore and Rook Ceph cluster are still running."
    print_info "To remove them, use ./cleanup-object-store.sh and ./uninstall-rook-ceph.sh"
}

# Run main function
main
