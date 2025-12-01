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
    print_info "Loading configuration from config.env..."
    source "$SCRIPT_DIR/config.env"
fi

# Configuration
OBJECT_STORE_NAME=${OBJECT_STORE_NAME:-"my-store"}
OBJECT_STORE_USER=${OBJECT_STORE_USER:-"my-user"}
BUCKET_CLAIM_NAME=${BUCKET_CLAIM_NAME:-"my-bucket"}
ROOK_CEPH_NAMESPACE=${ROOK_CEPH_NAMESPACE:-"rook-ceph"}
SAMPLE_APP_NAMESPACE=${SAMPLE_APP_NAMESPACE:-"default"}
ENABLE_TLS=${ENABLE_TLS:-"false"}
TLS_CERT_DOMAIN=${TLS_CERT_DOMAIN:-"rook-ceph-rgw-my-store.rook-ceph.svc"}
TLS_CERT_DAYS=${TLS_CERT_DAYS:-"365"}

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
        print_warn "The object store might not work properly if the cluster is not healthy"
    else
        print_info "CephCluster is healthy!"
    fi
}

# Wait for RGW pods to be ready
wait_for_rgw_pods() {
    print_info "Waiting for RGW pods to be created and ready..."

    local timeout=600  # 10 minutes
    local elapsed=0
    local check_interval=10
    local progress_interval=30

    # Get desired replicas from CephObjectStore spec
    local desired_replicas=$(kubectl -n $ROOK_CEPH_NAMESPACE get cephobjectstore $OBJECT_STORE_NAME -o jsonpath='{.spec.gateway.instances}' 2>/dev/null || echo "1")
    print_info "Waiting for $desired_replicas RGW pod(s) to be ready..."

    while [ $elapsed -lt $timeout ]; do
        # Get current pod count
        local current_pods=$(kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Get ready pod count
        local ready_pods=$(kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Check if desired number of pods are running
        if [ "$ready_pods" -ge "$desired_replicas" ] && [ "$ready_pods" -gt 0 ]; then
            # Double-check all pods are actually ready (not just Running)
            local ready_condition=$(kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l | tr -d ' ')

            if [ "$ready_condition" -ge "$desired_replicas" ]; then
                print_info "All $desired_replicas RGW pod(s) are ready!"
                kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw
                return 0
            fi
        fi

        # Show progress every 30 seconds
        if [ $((elapsed % progress_interval)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            print_info "RGW pods status: $ready_pods/$desired_replicas ready (${elapsed}s elapsed)"
            kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw --no-headers 2>/dev/null || print_warn "No RGW pods found yet"
        fi

        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done

    # Timeout reached
    print_error "Timeout waiting for RGW pods to be ready after ${timeout}s"
    print_info "Current RGW pod status:"
    kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw
    print_info "CephObjectStore status:"
    kubectl -n $ROOK_CEPH_NAMESPACE describe cephobjectstore $OBJECT_STORE_NAME
    return 1
}

# Generate TLS certificate
generate_tls_certificate() {
    print_header "Generating TLS Certificate"

    print_info "Generating self-signed certificate for domain: $TLS_CERT_DOMAIN"

    # Create temporary directory for certificates
    local cert_dir="/tmp/rgw-certs"
    mkdir -p "$cert_dir"

    # Generate private key
    openssl genrsa -out "$cert_dir/tls.key" 2048

    # Generate certificate
    openssl req -new -x509 \
        -key "$cert_dir/tls.key" \
        -out "$cert_dir/tls.crt" \
        -days "$TLS_CERT_DAYS" \
        -subj "/CN=$TLS_CERT_DOMAIN" \
        -addext "subjectAltName=DNS:$TLS_CERT_DOMAIN,DNS:*.rook-ceph.svc,DNS:*.rook-ceph.svc.cluster.local,DNS:localhost,IP:127.0.0.1"

    # Save certificate to local directory for user reference
    local ca_cert_path="$SCRIPT_DIR/rgw-ca-cert.pem"
    cp "$cert_dir/tls.crt" "$ca_cert_path"
    print_info "CA certificate saved to: $ca_cert_path"

    # Base64 encode the certificate and key
    local cert_base64=$(cat "$cert_dir/tls.crt" | base64 | tr -d '\n')
    local key_base64=$(cat "$cert_dir/tls.key" | base64 | tr -d '\n')

    # Create secret manifest
    print_info "Creating TLS secret manifest..."
    sed -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        -e "s|TLS_CERT_BASE64|$cert_base64|g" \
        -e "s|TLS_KEY_BASE64|$key_base64|g" \
        "$SCRIPT_DIR/manifests/object-store/object-store-tls-cert.yaml" > /tmp/object-store-tls-cert.yaml

    print_info "Applying TLS secret..."
    kubectl apply -f /tmp/object-store-tls-cert.yaml

    # Clean up temporary certificates
    rm -rf "$cert_dir"

    print_info "TLS certificate generated and applied successfully!"
}

# Deploy CephObjectStore
deploy_object_store() {
    print_header "Deploying CephObjectStore: $OBJECT_STORE_NAME"

    # Choose manifest based on TLS configuration
    local manifest_file
    if [ "$ENABLE_TLS" = "true" ]; then
        print_info "TLS is enabled. Using TLS-enabled manifest..."
        manifest_file="$SCRIPT_DIR/manifests/object-store/object-store-with-tls.yaml"

        # Generate TLS certificate first
        generate_tls_certificate
    else
        print_info "TLS is disabled. Using standard manifest..."
        manifest_file="$SCRIPT_DIR/manifests/object-store/object-store.yaml"
    fi

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephObjectStore manifest..."
    sed -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$manifest_file" > /tmp/object-store.yaml

    print_info "Applying CephObjectStore manifest..."
    kubectl apply -f /tmp/object-store.yaml

    # Wait for RGW pods to be ready
    wait_for_rgw_pods

    print_info "CephObjectStore deployed successfully!"
}

# Create object store user
create_object_store_user() {
    print_header "Creating ObjectStore User: $OBJECT_STORE_USER"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephObjectStoreUser manifest..."
    sed -e "s/OBJECT_STORE_USER/$OBJECT_STORE_USER/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/object-store/object-store-user.yaml" > /tmp/object-user.yaml

    print_info "Applying CephObjectStoreUser manifest..."
    kubectl apply -f /tmp/object-user.yaml

    print_info "Waiting for user credentials to be created..."
    sleep 5

    # Wait for secret to be created
    timeout=60
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n $ROOK_CEPH_NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER &> /dev/null; then
            print_info "User credentials created!"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""

    print_info "ObjectStore user created successfully!"
}

# Deploy StorageClass for bucket provisioning
deploy_storageclass() {
    print_header "Deploying StorageClass for Object Buckets"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing StorageClass manifest..."
    sed -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$ROOK_CEPH_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/object-store/storageclass-bucket.yaml" > /tmp/storageclass-bucket.yaml

    print_info "Applying StorageClass manifest..."
    kubectl apply -f /tmp/storageclass-bucket.yaml

    print_info "StorageClass created successfully!"
}

# Deploy ObjectBucketClaim
deploy_bucket_claim() {
    print_header "Deploying ObjectBucketClaim: $BUCKET_CLAIM_NAME"

    # Create namespace if it doesn't exist
    kubectl create namespace $SAMPLE_APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing ObjectBucketClaim manifest..."
    sed -e "s/BUCKET_CLAIM_NAME/$BUCKET_CLAIM_NAME/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/object-store/object-bucket-claim.yaml" > /tmp/object-bucket-claim.yaml

    print_info "Applying ObjectBucketClaim manifest..."
    kubectl apply -f /tmp/object-bucket-claim.yaml

    print_info "Waiting for ObjectBucketClaim to be bound..."

    # Wait for OBC to be bound
    timeout=120
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl -n $SAMPLE_APP_NAMESPACE get objectbucketclaim $BUCKET_CLAIM_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$phase" = "Bound" ]; then
            print_info "ObjectBucketClaim is bound!"
            kubectl -n $SAMPLE_APP_NAMESPACE get objectbucketclaim $BUCKET_CLAIM_NAME
            break
        fi

        if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            print_info "Waiting for OBC to be bound... (${elapsed}s elapsed, current phase: ${phase:-pending})"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ "$phase" != "Bound" ]; then
        print_warn "ObjectBucketClaim not bound after ${timeout}s"
        kubectl -n $SAMPLE_APP_NAMESPACE describe objectbucketclaim $BUCKET_CLAIM_NAME
    fi

    print_info "ObjectBucketClaim deployed successfully!"
}

# Get bucket credentials from OBC
get_bucket_credentials() {
    print_header "Object Bucket Credentials (from OBC)"

    # Get S3 endpoint
    print_info "Getting S3 endpoint..."
    ENDPOINT=$(kubectl -n $ROOK_CEPH_NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.clusterIP}')
    PORT=$(kubectl -n $ROOK_CEPH_NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.ports[0].port}')

    # Get bucket name from OBC
    print_info "Getting bucket name from ObjectBucketClaim..."
    BUCKET_NAME=$(kubectl -n $SAMPLE_APP_NAMESPACE get objectbucketclaim $BUCKET_CLAIM_NAME -o jsonpath='{.spec.bucketName}' 2>/dev/null)

    # Get credentials from ConfigMap and Secret created by OBC
    print_info "Getting bucket credentials from OBC resources..."
    CONFIGMAP_NAME=$(kubectl -n $SAMPLE_APP_NAMESPACE get objectbucketclaim $BUCKET_CLAIM_NAME -o jsonpath='{.metadata.name}' 2>/dev/null)

    if [ -n "$CONFIGMAP_NAME" ]; then
        OBC_ACCESS_KEY=$(kubectl -n $SAMPLE_APP_NAMESPACE get secret $CONFIGMAP_NAME -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 --decode)
        OBC_SECRET_KEY=$(kubectl -n $SAMPLE_APP_NAMESPACE get secret $CONFIGMAP_NAME -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 --decode)
        OBC_BUCKET=$(kubectl -n $SAMPLE_APP_NAMESPACE get configmap $CONFIGMAP_NAME -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)
    else
        print_warn "ObjectBucket name not found, using claim name"
        CONFIGMAP_NAME=$BUCKET_CLAIM_NAME
        OBC_ACCESS_KEY=$(kubectl -n $SAMPLE_APP_NAMESPACE get secret $CONFIGMAP_NAME -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 --decode)
        OBC_SECRET_KEY=$(kubectl -n $SAMPLE_APP_NAMESPACE get secret $CONFIGMAP_NAME -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 --decode)
        OBC_BUCKET=$(kubectl -n $SAMPLE_APP_NAMESPACE get configmap $CONFIGMAP_NAME -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)
    fi

    echo ""
    echo -e "${GREEN}S3 Endpoint:${NC}    http://${ENDPOINT}:${PORT}"
    echo -e "${GREEN}Bucket Name:${NC}    ${OBC_BUCKET:-$BUCKET_NAME}"
    echo -e "${GREEN}Access Key:${NC}     ${OBC_ACCESS_KEY}"
    echo -e "${GREEN}Secret Key:${NC}     ${OBC_SECRET_KEY}"
    echo ""
 
    # Export for use in sample apps
    echo ""
    echo "export AWS_HOST=${ENDPOINT}"
    echo "export PORT=${PORT}"
    echo "export AWS_URL=http://${ENDPOINT}:${PORT}"
    echo "export BUCKET_NAME=${OBC_BUCKET:-$BUCKET_NAME}"
    echo "export AWS_ACCESS_KEY_ID=${OBC_ACCESS_KEY}"
    echo "export AWS_SECRET_ACCESS_KEY=${OBC_SECRET_KEY}"
    if [ "$ENABLE_TLS" = "true" ]; then
        echo "export AWS_CA_BUNDLE=${SCRIPT_DIR}/rgw-ca-cert.pem"
    fi
    echo ""

}

# Get credentials
get_credentials() {
    print_header "Object Store Credentials"

    # Get S3 endpoint
    print_info "Getting S3 endpoint..."
    ENDPOINT=$(kubectl -n $ROOK_CEPH_NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.clusterIP}')
    PORT=$(kubectl -n $ROOK_CEPH_NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.ports[0].port}')

    # Determine protocol based on TLS setting
    local protocol="http"
    if [ "$ENABLE_TLS" = "true" ]; then
        protocol="https"
    fi

    # Get access key and secret key
    print_info "Getting access credentials..."
    ACCESS_KEY=$(kubectl -n $ROOK_CEPH_NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o jsonpath='{.data.AccessKey}' | base64 --decode)
    SECRET_KEY=$(kubectl -n $ROOK_CEPH_NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o jsonpath='{.data.SecretKey}' | base64 --decode)

    echo ""
    echo -e "${GREEN}S3 Endpoint:${NC} ${protocol}://${ENDPOINT}:${PORT}"
    echo -e "${GREEN}TLS Enabled:${NC} ${ENABLE_TLS}"
    echo -e "${GREEN}Access Key:${NC}  ${ACCESS_KEY}"
    echo -e "${GREEN}Secret Key:${NC}  ${SECRET_KEY}"
    echo ""

    # Export for use in sample apps
    export S3_ENDPOINT="${protocol}://${ENDPOINT}:${PORT}"
    export S3_ACCESS_KEY="${ACCESS_KEY}"
    export S3_SECRET_KEY="${SECRET_KEY}"
    export S3_USE_TLS="${ENABLE_TLS}"
}

# Deploy sample Python S3 app
deploy_sample_app() {
    print_header "Deploying Sample S3 Application (Python)"

    # Create namespace if it doesn't exist
    kubectl create namespace $SAMPLE_APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # Create secret with S3 credentials
    print_info "Creating secret with S3 credentials..."
    kubectl -n $SAMPLE_APP_NAMESPACE create secret generic s3-credentials \
        --from-literal=endpoint="$S3_ENDPOINT" \
        --from-literal=access-key="$S3_ACCESS_KEY" \
        --from-literal=secret-key="$S3_SECRET_KEY" \
        --from-literal=use-tls="$S3_USE_TLS" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Read Python source files
    print_info "Reading Python source files..."

    # Create ConfigMap from template
    print_info "Creating ConfigMap with Python code..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-test-configmap.yaml" > /tmp/s3-test-configmap-temp.yaml

    # Replace content placeholders with actual Python code
    awk -v python_script="$(cat "$SCRIPT_DIR/manifests/sample-apps/python-s3-test/test_s3.py")" \
        '{gsub(/PYTHON_SCRIPT_CONTENT/, python_script); print}' /tmp/s3-test-configmap-temp.yaml | \
    awk -v requirements="$(cat "$SCRIPT_DIR/manifests/sample-apps/python-s3-test/requirements.txt")" \
        '{gsub(/REQUIREMENTS_CONTENT/, requirements); print}' > /tmp/s3-test-configmap.yaml

    kubectl apply -f /tmp/s3-test-configmap.yaml

    # Create Job from template
    print_info "Creating Job manifest..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-test-job.yaml" > /tmp/s3-test-job.yaml

    print_info "Deploying sample S3 test application..."
    kubectl apply -f /tmp/s3-test-job.yaml

    print_info "Waiting for job to start..."
    sleep 5

    print_info "Watching job logs (Ctrl+C to exit)..."
    echo ""
    kubectl -n $SAMPLE_APP_NAMESPACE wait --for=condition=ready pod -l job-name=s3-test-job --timeout=60s || true
    kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job 2>/dev/null || {
        print_warn "Job not ready yet. Check logs later with:"
        echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job"
    }
}

# Create sample curl-based test
create_curl_test() {
    print_header "Creating Curl-based S3 Test Pod"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing curl test pod manifest..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-curl-pod.yaml" > /tmp/curl-s3-pod.yaml

    print_info "Deploying curl test pod..."
    kubectl apply -f /tmp/curl-s3-pod.yaml

    print_info "Curl test pod created!"
}

# Show usage instructions
show_usage() {
    print_header "Usage Instructions"

    echo "Object Store Information:"
    echo "  Name: $OBJECT_STORE_NAME"
    echo "  Namespace: $ROOK_CEPH_NAMESPACE"
    echo "  User: $OBJECT_STORE_USER"
    echo "  Bucket Claim: $BUCKET_CLAIM_NAME"
    echo ""
    echo "To view object store status:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get cephobjectstore"
    echo ""
    echo "To view RGW (S3 gateway) pods:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get pods -l app=rook-ceph-rgw"
    echo ""
    echo "To view ObjectBucketClaim status:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get objectbucketclaim $BUCKET_CLAIM_NAME"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE describe objectbucketclaim $BUCKET_CLAIM_NAME"
    echo ""
    echo "To get bucket credentials from OBC:"
    echo "  # Get the ObjectBucket name"
    echo "  OB_NAME=\$(kubectl -n $SAMPLE_APP_NAMESPACE get obc $BUCKET_CLAIM_NAME -o jsonpath='{.metadata.name}')"
    echo "  # Get credentials"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get secret \$OB_NAME -o yaml"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE get configmap \$OB_NAME -o yaml"
    echo ""
    echo "To get user credentials:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o yaml"
    echo ""
    echo "To access S3 endpoint from outside the cluster:"
    if [ "$ENABLE_TLS" = "true" ]; then
        echo "  kubectl -n $ROOK_CEPH_NAMESPACE port-forward svc/rook-ceph-rgw-$OBJECT_STORE_NAME 8443:443"
        echo "  Then use: https://localhost:8443"
        echo ""
        echo "TLS Certificate Information:"
        echo "  CA certificate location: $SCRIPT_DIR/rgw-ca-cert.pem"
        echo ""
        echo "  To use with AWS CLI (skip verification):"
        echo "    aws s3 ls --endpoint-url https://localhost:8443 --no-verify-ssl"
        echo ""
        echo "  To use with AWS CLI (with CA cert):"
        echo "    aws s3 ls --endpoint-url https://localhost:8443 --ca-bundle $SCRIPT_DIR/rgw-ca-cert.pem"
        echo ""
        echo "  To use with curl (skip verification):"
        echo "    curl -k https://localhost:8443"
        echo ""
        echo "  To use with curl (with CA cert):"
        echo "    curl --cacert $SCRIPT_DIR/rgw-ca-cert.pem https://localhost:8443"
        echo ""
        echo "  To trust the certificate system-wide (macOS):"
        echo "    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $SCRIPT_DIR/rgw-ca-cert.pem"
        echo ""
        echo "  To trust the certificate system-wide (Linux):"
        echo "    sudo cp $SCRIPT_DIR/rgw-ca-cert.pem /usr/local/share/ca-certificates/rgw-ca-cert.crt"
        echo "    sudo update-ca-certificates"
    else
        echo "  kubectl -n $ROOK_CEPH_NAMESPACE port-forward svc/rook-ceph-rgw-$OBJECT_STORE_NAME 8080:80"
        echo "  Then use: http://localhost:8080"
    fi
    echo ""
    echo "Sample app logs:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job"
    echo ""
    echo "To run manual S3 tests with curl pod:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE exec -it s3-curl-test -- sh"
    echo ""
}

# Main execution
main() {
    # If help flag is set, show usage and exit
    if [ "$SHOW_HELP" = "true" ]; then
        show_usage
        exit 0
    fi

    print_info "Starting CephObjectStore deployment..."
    echo ""

    check_rook_ceph
    deploy_object_store
    create_object_store_user
    get_credentials
    deploy_storageclass
    deploy_bucket_claim
    get_bucket_credentials
    # TODO: Sample APP doesn't work
    # deploy_sample_app
    # create_curl_test
    show_usage

    print_info "Deployment complete!"
}

# Run main function
main
