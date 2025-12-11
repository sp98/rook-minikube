#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for help argument
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    SHOW_HELP=true
fi

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

# COSI controller versions
COSI_CONTROLLER_VERSION=${COSI_CONTROLLER_VERSION:-"v0.2.2"}

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

# Check if Rook Ceph is running
check_rook_ceph() {
    print_info "Checking if Rook Ceph cluster is running..."

    if ! kubectl get namespace $ROOK_CEPH_NAMESPACE &> /dev/null; then
        print_error "Namespace $ROOK_CEPH_NAMESPACE not found. Please install Rook Ceph first."
        exit 1
    fi

    if ! kubectl -n $ROOK_CEPH_NAMESPACE get deployment rook-ceph-operator &> /dev/null; then
        print_error "Rook Ceph operator not found. Please install Rook Ceph first."
        exit 1
    fi

    # Check if CephCluster is healthy
    cluster_health=$(kubectl -n $ROOK_CEPH_NAMESPACE get cephcluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$cluster_health" != "Ready" ]; then
        print_warn "CephCluster status: $cluster_health (expected: Ready)"
        print_warn "COSI might not work properly if the cluster is not healthy"
    else
        print_info "CephCluster is healthy!"
    fi
}

# Check if CephObjectStore exists
check_object_store() {
    print_info "Checking if CephObjectStore exists..."

    if ! kubectl -n $ROOK_CEPH_NAMESPACE get cephobjectstore $OBJECT_STORE_NAME &> /dev/null; then
        print_error "CephObjectStore '$OBJECT_STORE_NAME' not found in namespace '$ROOK_CEPH_NAMESPACE'"
        print_error "Please deploy a CephObjectStore first using ./deploy-object-store.sh"
        exit 1
    fi

    # Check if object store is ready
    store_phase=$(kubectl -n $ROOK_CEPH_NAMESPACE get cephobjectstore $OBJECT_STORE_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$store_phase" != "Ready" ]; then
        print_warn "CephObjectStore status: $store_phase (expected: Ready)"
        print_warn "COSI might not work properly if the object store is not ready"
    else
        print_info "CephObjectStore is ready!"
    fi
}


# Install COSI API and Controller
install_cosi_controller() {
    print_header "Installing COSI API and Controller"

    # According to https://github.com/kubernetes-sigs/container-object-storage-interface
    # Installation is done via: kubectl apply -k github.com/kubernetes-sigs/container-object-storage-interface
    # This installs both CRDs (from ./client/config/crd) and controller (from ./controller)

    # Install COSI (CRDs + Controller) using the official method from the README
    print_info "Installing COSI CRDs and Controller version ${COSI_CONTROLLER_VERSION} from upstream repository..."

    kubectl apply -k "github.com/kubernetes-sigs/container-object-storage-interface?ref=${COSI_CONTROLLER_VERSION}" --request-timeout=90s

    # Wait for CRDs to be established
    print_info "Waiting for COSI CRDs to be established..."
    kubectl wait --for condition=established --timeout=60s crd/bucketclasses.objectstorage.k8s.io
    kubectl wait --for condition=established --timeout=60s crd/bucketclaims.objectstorage.k8s.io
    kubectl wait --for condition=established --timeout=60s crd/buckets.objectstorage.k8s.io
    kubectl wait --for condition=established --timeout=60s crd/bucketaccesses.objectstorage.k8s.io
    kubectl wait --for condition=established --timeout=60s crd/bucketaccessclasses.objectstorage.k8s.io

    # Wait for controller deployment to be ready
    print_info "Waiting for COSI Controller deployment to be ready..."

    # Now wait for deployment to be available
    print_info "Waiting for COSI Controller to become available..."
    kubectl wait -n container-object-storage-system --for=condition=available --timeout=120s deployment/container-object-storage-controller || {
        print_error "COSI Controller deployment failed to become ready"
        print_info "Deployment status:"
        kubectl get deployment objectstorage-controller -n container-object-storage-system 
        print_info "Pod status:"
        kubectl get pods -n container-object-storage-system
        print_info "Pod logs:"
        kubectl logs -l app.kubernetes.io/name=objectstorage-controller --tail=50 -n container-object-storage-system
        return 1
    }

    print_info "COSI API and Controller installed successfully!"
}

# Deploy CephCOSIDriver
deploy_cosi_driver() {
    print_header "Deploying CephCOSIDriver"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephCOSIDriver manifest..."
    sed -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/cosi/ceph-cosi-driver.yaml" > /tmp/ceph-cosi-driver.yaml

    print_info "Applying CephCOSIDriver manifest..."
    kubectl apply -f /tmp/ceph-cosi-driver.yaml

    print_info "Waiting for COSI driver pods to be ready..."
    sleep 5

    # Wait for COSI driver deployment
    timeout=120
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n $ROOK_CEPH_NAMESPACE get deployment ceph-cosi-driver &> /dev/null; then
            print_info "COSI driver deployment found!"
            kubectl wait --for=condition=available --timeout=60s deployment/ceph-cosi-driver -n $ROOK_CEPH_NAMESPACE || {
                print_warn "COSI driver deployment not ready yet"
            }
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        print_warn "COSI driver deployment not found after ${timeout}s"
        print_info "This might be expected if deploymentStrategy is 'Auto'"
    fi

    print_info "CephCOSIDriver deployed successfully!"
}

# Create COSI user
create_cosi_user() {
    print_header "Creating COSI User: $COSI_USER"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephObjectStoreUser manifest..."
    sed -e "s/COSI_USER/$COSI_USER/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/cosi/object-store-user-cosi.yaml" > /tmp/object-store-user-cosi.yaml

    print_info "Applying CephObjectStoreUser manifest..."
    kubectl apply -f /tmp/object-store-user-cosi.yaml

    print_info "Waiting for COSI user credentials to be created..."
    sleep 5

    # Wait for secret to be created
    timeout=60
    elapsed=0
    secret_name="rook-ceph-object-user-$OBJECT_STORE_NAME-$COSI_USER"
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n $ROOK_CEPH_NAMESPACE get secret $secret_name &> /dev/null; then
            print_info "COSI user credentials created!"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        print_error "Timeout waiting for COSI user secret to be created"
        return 1
    fi

    print_info "COSI user created successfully!"
}

# Deploy BucketClass
deploy_bucket_class() {
    print_header "Deploying BucketClass: $BUCKET_CLASS_NAME"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing BucketClass manifest..."
    sed -e "s/BUCKET_CLASS_NAME/$BUCKET_CLASS_NAME/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/COSI_USER/$COSI_USER/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/cosi/bucketclass.yaml" > /tmp/bucketclass.yaml

    print_info "Applying BucketClass manifest..."
    kubectl apply -f /tmp/bucketclass.yaml

    print_info "BucketClass deployed successfully!"
}

# Deploy BucketAccessClass
deploy_bucket_access_class() {
    print_header "Deploying BucketAccessClass: $BUCKET_ACCESS_CLASS_NAME"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing BucketAccessClass manifest..."
    sed -e "s/BUCKET_ACCESS_CLASS_NAME/$BUCKET_ACCESS_CLASS_NAME/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/COSI_USER/$COSI_USER/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/cosi/bucketaccessclass.yaml" > /tmp/bucketaccessclass.yaml

    print_info "Applying BucketAccessClass manifest..."
    kubectl apply -f /tmp/bucketaccessclass.yaml

    print_info "BucketAccessClass deployed successfully!"
}

# Create BucketClaim
create_bucket_claim() {
    print_header "Creating BucketClaim: $BUCKET_CLAIM_NAME"

    # Create namespace if it doesn't exist
    kubectl create namespace $SAMPLE_APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing BucketClaim manifest..."
    sed -e "s/BUCKET_CLAIM_NAME/$BUCKET_CLAIM_NAME/g" \
        -e "s/BUCKET_CLASS_NAME/$BUCKET_CLASS_NAME/g" \
        -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/cosi/bucketclaim.yaml" > /tmp/bucketclaim.yaml

    print_info "Applying BucketClaim manifest..."
    kubectl apply -f /tmp/bucketclaim.yaml

    print_info "Waiting for BucketClaim to be ready..."

    # Wait for BucketClaim to be ready
    timeout=120
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketclaim $BUCKET_CLAIM_NAME -o jsonpath='{.status.bucketReady}' 2>/dev/null || echo "false")

        if [ "$phase" = "true" ]; then
            print_info "BucketClaim is ready!"
            kubectl -n $SAMPLE_APP_NAMESPACE get bucketclaim $BUCKET_CLAIM_NAME
            break
        fi

        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            print_info "Waiting for BucketClaim to be ready... (${elapsed}s elapsed)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ "$phase" != "true" ]; then
        print_warn "BucketClaim not ready after ${timeout}s"
        kubectl -n $SAMPLE_APP_NAMESPACE describe bucketclaim $BUCKET_CLAIM_NAME
    fi

    print_info "BucketClaim created successfully!"
}

# Create BucketAccess
create_bucket_access() {
    print_header "Creating BucketAccess: $BUCKET_ACCESS_NAME"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing BucketAccess manifest..."
    sed -e "s/BUCKET_ACCESS_NAME/$BUCKET_ACCESS_NAME/g" \
        -e "s/BUCKET_CLAIM_NAME/$BUCKET_CLAIM_NAME/g" \
        -e "s/BUCKET_ACCESS_CLASS_NAME/$BUCKET_ACCESS_CLASS_NAME/g" \
        -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
         -e "s/BUCKET_SECRET_NAME/$BUCKET_CLAIM_NAME/g" \
        "$SCRIPT_DIR/manifests/cosi/bucketaccess.yaml" > /tmp/bucketaccess.yaml

    print_info "Applying BucketAccess manifest..."
    kubectl apply -f /tmp/bucketaccess.yaml

    print_info "Waiting for BucketAccess to be ready..."

    # Wait for BucketAccess to be ready
    timeout=120
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        ready=$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME -o jsonpath='{.status.accessGranted}' 2>/dev/null || echo "false")

        if [ "$ready" = "true" ]; then
            print_info "BucketAccess is ready!"
            kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME
            break
        fi

        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            print_info "Waiting for BucketAccess to be ready... (${elapsed}s elapsed)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ "$ready" != "true" ]; then
        print_warn "BucketAccess not ready after ${timeout}s"
        kubectl -n $SAMPLE_APP_NAMESPACE describe bucketaccess $BUCKET_ACCESS_NAME
    fi

    print_info "BucketAccess created successfully!"
}

# Get bucket credentials
get_bucket_credentials() {
    print_header "Bucket Credentials (from COSI)"

    # Get bucket name from BucketClaim
    print_info "Getting bucket information from BucketClaim..."
    BUCKET_NAME=$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketclaim $BUCKET_CLAIM_NAME -o jsonpath='{.status.bucketName}' 2>/dev/null || echo "")

    # Get credentials from BucketAccess secret
    print_info "Getting bucket credentials from BucketAccess..."
    SECRET_NAME=$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME -o jsonpath='{.spec.credentialsSecretName}' 2>/dev/null || echo "")

    if [ -n "$SECRET_NAME" ]; then
        # Decode the credentials JSON
        CREDS_JSON=$(kubectl -n $SAMPLE_APP_NAMESPACE get secret $SECRET_NAME -o jsonpath='{.data.BucketInfo}' 2>/dev/null | base64 --decode || echo "{}")

        # Parse credentials
        ENDPOINT=$(echo "$CREDS_JSON" | grep -o '"endpoint":"[^"]*"' | cut -d'"' -f4 || echo "")
        ACCESS_KEY=$(echo "$CREDS_JSON" | grep -o '"accessKeyID":"[^"]*"' | cut -d'"' -f4 || echo "")
        SECRET_KEY=$(echo "$CREDS_JSON" | grep -o '"accessSecretKey":"[^"]*"' | cut -d'"' -f4 || echo "")
        BUCKET_FROM_SECRET=$(echo "$CREDS_JSON" | grep -o '"bucketName":"[^"]*"' | cut -d'"' -f4 || echo "")

        echo ""
        echo -e "${GREEN}Bucket Name:${NC}     ${BUCKET_FROM_SECRET:-$BUCKET_NAME}"
        echo -e "${GREEN}S3 Endpoint:${NC}     ${ENDPOINT}"
        echo -e "${GREEN}Access Key:${NC}      ${ACCESS_KEY}"
        echo -e "${GREEN}Secret Key:${NC}      ${SECRET_KEY}"
        echo ""

        # Export for use in sample apps
        echo ""
        echo "export BUCKET_NAME=${BUCKET_FROM_SECRET:-$BUCKET_NAME}"
        echo "export S3_ENDPOINT=${ENDPOINT}"
        echo "export AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
        echo "export AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
        echo ""
    else
        print_warn "BucketAccess secret not found yet"
        print_info "You can retrieve credentials later with:"
        echo "  SECRET_NAME=\$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME -o jsonpath='{.status.credentialsSecretName}')"
        echo "  kubectl -n $SAMPLE_APP_NAMESPACE get secret \$SECRET_NAME -o jsonpath='{.data.BucketInfo}' | base64 --decode | jq ."
        echo ""
    fi
}

# Deploy sample COSI S3 app
deploy_cosi_sample_app() {
    print_header "Deploying Sample COSI S3 Application (Python)"

    # Get the COSI secret name from BucketAccess
    print_info "Getting COSI secret name from BucketAccess..."
    COSI_SECRET_NAME=$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME -o jsonpath='{.spec.credentialsSecretName}' 2>/dev/null || echo "")

    if [ -z "$COSI_SECRET_NAME" ]; then
        print_error "Failed to get COSI secret name from BucketAccess"
        print_error "Make sure BucketAccess '$BUCKET_ACCESS_NAME' is ready"
        return 1
    fi

    print_info "Using COSI secret: $COSI_SECRET_NAME"

    # Create ConfigMap from template
    print_info "Creating ConfigMap with Python code..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/cosi-s3-test-configmap.yaml" > /tmp/cosi-s3-test-configmap-temp.yaml

    # Replace content placeholders with actual Python code (properly indented for YAML)
    # Indent the Python script content with 4 spaces for YAML formatting
    # Create temp files with indented content
    sed 's/^/    /' "$SCRIPT_DIR/manifests/sample-apps/python-cosi-test/test_cosi_s3.py" > /tmp/python_cosi_indented.tmp
    sed 's/^/    /' "$SCRIPT_DIR/manifests/sample-apps/python-cosi-test/requirements.txt" > /tmp/requirements_cosi_indented.tmp

    # Use sed to replace placeholders with file contents (works on both macOS and Linux)
    sed -e '/PYTHON_SCRIPT_CONTENT/{
        r /tmp/python_cosi_indented.tmp
        d
    }' -e '/REQUIREMENTS_CONTENT/{
        r /tmp/requirements_cosi_indented.tmp
        d
    }' /tmp/cosi-s3-test-configmap-temp.yaml > /tmp/cosi-s3-test-configmap.yaml

    # Clean up temp files
    rm -f /tmp/python_cosi_indented.tmp /tmp/requirements_cosi_indented.tmp

    kubectl apply -f /tmp/cosi-s3-test-configmap.yaml

    # Create Job from template
    print_info "Creating Job manifest..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        -e "s/COSI_SECRET_NAME/$COSI_SECRET_NAME/g" \
        "$SCRIPT_DIR/manifests/sample-apps/cosi-s3-test-job.yaml" > /tmp/cosi-s3-test-job.yaml

    print_info "Deploying sample COSI S3 test application..."
    kubectl apply -f /tmp/cosi-s3-test-job.yaml

    print_info "Waiting for job to start..."
    sleep 5

    print_info "Watching job logs (Ctrl+C to exit)..."
    echo ""
    kubectl -n $SAMPLE_APP_NAMESPACE wait --for=condition=ready pod -l app=cosi-s3-test --timeout=60s || true
    kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/cosi-s3-test-job 2>/dev/null || {
        print_warn "Job not ready yet. Check logs later with:"
        echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/cosi-s3-test-job"
    }
}

# Show usage instructions
show_usage() {
    print_header "Usage Instructions"

    echo "COSI Resources:"
    echo "  CephCOSIDriver: ceph-cosi-driver"
    echo "  COSI User: $COSI_USER"
    echo "  BucketClass: $BUCKET_CLASS_NAME"
    echo "  BucketAccessClass: $BUCKET_ACCESS_CLASS_NAME"
    echo "  BucketClaim: $BUCKET_CLAIM_NAME"
    echo "  BucketAccess: $BUCKET_ACCESS_NAME"
    echo ""
    echo "To view COSI driver status:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get cephcosidriver"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get deployment ceph-cosi-driver"
    echo ""
    echo "To view COSI resources:"
    echo "  kubectl get bucketclass"
    echo "  kubectl get bucketaccessclass"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get bucketclaim"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess"
    echo ""
    echo "To view BucketClaim details:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE describe bucketclaim $BUCKET_CLAIM_NAME"
    echo ""
    echo "To view BucketAccess details:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE describe bucketaccess $BUCKET_ACCESS_NAME"
    echo ""
    echo "To get bucket credentials:"
    echo "  SECRET_NAME=\$(kubectl -n $SAMPLE_APP_NAMESPACE get bucketaccess $BUCKET_ACCESS_NAME -o jsonpath='{.status.credentialsSecretName}')"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get secret \$SECRET_NAME -o jsonpath='{.data.BucketInfo}' | base64 --decode | jq ."
    echo ""
    echo "Sample COSI app logs:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/cosi-s3-test-job"
    echo ""
    echo "To cleanup COSI resources:"
    echo "  ./cleanup-cosi.sh"
    echo ""
}

# Main execution
main() {
    # If help flag is set, show usage and exit
    if [ "$SHOW_HELP" = "true" ]; then
        show_usage
        exit 0
    fi

    print_info "Starting COSI deployment..."
    echo ""

    check_rook_ceph
    check_object_store
    install_cosi_controller
    deploy_cosi_driver
    create_cosi_user
    deploy_bucket_class
    deploy_bucket_access_class
    create_bucket_claim
    create_bucket_access
    get_bucket_credentials
    deploy_cosi_sample_app
    show_usage

    print_info "COSI deployment complete!"
}

# Run main function
main
