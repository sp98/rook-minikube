# Rook Ceph on Minikube

This project provides automated scripts to install and manage Rook Ceph on Minikube.

## Project Structure

```
rook-minikube/
├── install-rook-ceph.sh       # Main Rook Ceph installation script
├── uninstall-rook-ceph.sh     # Rook Ceph cleanup and uninstallation
├── deploy-object-store.sh     # Deploy CephObjectStore with sample apps
├── cleanup-object-store.sh    # Remove object store and sample apps
├── config.env.example          # Example configuration file
├── README.md                   # This file
├── .gitignore                 # Git ignore rules
└── manifests/                 # Kubernetes YAML manifests
    ├── README.md                   # Manifests documentation
    ├── object-store/               # CephObjectStore manifests
    │   ├── object-store.yaml       # ObjectStore definition
    │   └── object-store-user.yaml  # ObjectStore user definition
    └── sample-apps/                # Sample application manifests
        ├── go-s3-test/             # Go S3 test app source
        │   ├── main.go             # Main application code
        │   └── go.mod              # Go module definition
        ├── s3-test-configmap.yaml  # ConfigMap template
        ├── s3-test-job.yaml        # Job template
        └── s3-curl-pod.yaml        # Curl test pod template
```

## Prerequisites

Before running the installation script, ensure you have the following installed:

- **minikube** - Local Kubernetes cluster
- **kubectl** - Kubernetes command-line tool
- **QEMU** - Virtualization platform (used as the minikube driver, recommended for Mac M1/M2)
  - Install on Mac: `brew install qemu`
  - Install on Linux: `sudo apt-get install qemu-kvm` or `sudo yum install qemu-kvm`

### Additional Prerequisites for Custom Builds

If you want to build a custom Rook operator from source:

- **podman** - Container engine (used instead of Docker)
- **Go** - Go programming language (1.21 or later)

## Installation

### Quick Start

1. Make the script executable:
```bash
chmod +x install-rook-ceph.sh
```

2. Run the installation:
```bash
./install-rook-ceph.sh
```

The script will:
- Check prerequisites
- Start Minikube with appropriate resources (4GB RAM, 2 CPUs, 2 extra disks, 1 node by default)
- Deploy Rook operator
- Deploy Rook Ceph cluster
- Deploy Rook toolbox for debugging
- Show cluster status

### Configuration File

Instead of passing environment variables on the command line, you can use a `config.env` file to manage all configuration settings.

1. Copy the example configuration file:
```bash
cp config.env.example config.env
```

2. Edit the config file with your desired settings:
```bash
vi config.env
```

3. Run the installation (it will automatically read config.env):
```bash
./install-rook-ceph.sh
```

The configuration file includes:
- **Rook Settings**: Version, source directory, custom build options
- **Minikube Settings**: Nodes, memory, CPUs, disk size, driver
- **Example Configurations**: Pre-configured setups for different use cases

**Available Configuration Options:**

| Variable | Default | Description |
|----------|---------|-------------|
| `ROOK_VERSION` | `v1.14.9` | Rook version to install |
| `ROOK_SOURCE_DIR` | `~/dev/go/src/github.com/rook/rook` | Path to Rook source code |
| `USE_CUSTOM_BUILD` | `false` | Build from local source |
| `CUSTOM_IMAGE_TAG` | `local-build` | Tag for custom images |
| `MINIKUBE_NODES` | `1` | Number of cluster nodes |
| `MINIKUBE_MEMORY` | `4096` | Memory per node (MB) |
| `MINIKUBE_CPUS` | `2` | CPU cores per node |
| `MINIKUBE_DISK_SIZE` | `20g` | Main disk size |
| `MINIKUBE_EXTRA_DISKS` | `2` | Extra disks for Ceph |
| `MINIKUBE_DRIVER` | `qemu` | Minikube driver |

**Note**: Environment variables passed on the command line will override values in `config.env`.

### Multi-Node Cluster

To create a multi-node Minikube cluster:

```bash
MINIKUBE_NODES=3 ./install-rook-ceph.sh
```

You can also customize other Minikube settings:

```bash
MINIKUBE_NODES=3 \
MINIKUBE_MEMORY=8192 \
MINIKUBE_CPUS=4 \
MINIKUBE_DISK_SIZE=30g \
MINIKUBE_EXTRA_DISKS=3 \
./install-rook-ceph.sh
```

Configuration options:
- `MINIKUBE_NODES` - Number of nodes (default: 1)
- `MINIKUBE_MEMORY` - Memory per node in MB (default: 4096)
- `MINIKUBE_CPUS` - CPUs per node (default: 2)
- `MINIKUBE_DISK_SIZE` - Main disk size (default: 20g)
- `MINIKUBE_EXTRA_DISKS` - Number of extra disks for Ceph (default: 2)

### Custom Rook Version

To install a specific version of Rook:
```bash
ROOK_VERSION=v1.14.9 ./install-rook-ceph.sh
```

### Building from Custom Rook Source

To build and deploy a custom Rook operator from your local source code:

1. Clone or have the Rook repository at `~/dev/go/src/github.com/rook/rook` (or set a custom path)

2. Build and deploy with custom source:
```bash
USE_CUSTOM_BUILD=true ./install-rook-ceph.sh
```

3. Optional: Customize the source directory and image tag:
```bash
USE_CUSTOM_BUILD=true \
ROOK_SOURCE_DIR=~/my-rook-fork \
CUSTOM_IMAGE_TAG=my-custom-build \
./install-rook-ceph.sh
```

The script will:
- Detect your architecture (ARM64 for Mac M2 or AMD64)
- Build the Rook operator binary for Linux
- Build a container image using podman
- Load the image into Minikube
- Deploy the custom operator image

**Note**: This is designed to work on Mac M2 (ARM64) using podman. The build process will create a Linux ARM64 or AMD64 image as appropriate.

## Verification

After installation, verify the cluster status:

```bash
# Check all pods in rook-ceph namespace
kubectl -n rook-ceph get pods

# Check Ceph cluster status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# Check Ceph health
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health
```

## Accessing Ceph Dashboard

1. Get the dashboard service:
```bash
kubectl -n rook-ceph get service rook-ceph-mgr-dashboard
```

2. Port forward to access the dashboard:
```bash
kubectl -n rook-ceph port-forward service/rook-ceph-mgr-dashboard 8443:8443
```

3. Get the admin password:
```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo
```

4. Access the dashboard at: https://localhost:8443
   - Username: `admin`
   - Password: (from step 3)

## Using Ceph Storage

### Create a Storage Class

The cluster automatically creates a default storage class. To verify:
```bash
kubectl get storageclass
```

### Example: Create a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
```

Apply it:
```bash
kubectl apply -f pvc.yaml
```

## Using Ceph Object Store (S3-compatible)

In addition to block storage, you can deploy a Ceph Object Store which provides an S3-compatible API.

### Deploy Object Store

To deploy a CephObjectStore with sample applications:

```bash
./deploy-object-store.sh
```

This script will:
- Deploy a CephObjectStore (S3-compatible gateway)
- Create an object store user with credentials
- Deploy a sample Go application that tests S3 operations
- Create a curl test pod for manual testing
- Display S3 endpoint and credentials

### Custom Object Store Configuration

You can customize the object store deployment:

```bash
OBJECT_STORE_NAME=production-store \
OBJECT_STORE_USER=app-user \
SAMPLE_APP_NAMESPACE=apps \
./deploy-object-store.sh
```

### Access Object Store

After deployment, you'll see output similar to:

```
S3 Endpoint:  http://10.96.xxx.xxx:80
Access Key:   XXXXXXXXXXXXXXXXXX
Secret Key:   XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

#### From Inside the Cluster

Use the internal service endpoint shown in the script output.

#### From Outside the Cluster

Port-forward the RGW service:

```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8080:80
```

Then access at: `http://localhost:8080`

### Sample Applications

The deployment script creates two sample applications:

1. **Go S3 Test Job** - Automatically tests S3 operations using AWS SDK for Go:
   - Creates a bucket
   - Uploads a test file
   - Lists buckets and objects
   - Downloads and verifies content

   View logs:
   ```bash
   kubectl -n default logs -f job/s3-test-job
   ```

   The Go application uses the official AWS SDK for Go (aws-sdk-go) to interact with the S3-compatible API.

2. **Curl Test Pod** - For manual S3 testing:
   ```bash
   kubectl -n default exec -it s3-curl-test -- sh
   # Inside the pod, credentials are available as environment variables
   echo $S3_ENDPOINT
   echo $S3_ACCESS_KEY
   echo $S3_SECRET_KEY
   ```

### Using with S3-Compatible SDKs

You can use standard S3 tools and SDKs with the Ceph Object Store:

**AWS CLI Example:**
```bash
aws configure set aws_access_key_id <ACCESS_KEY>
aws configure set aws_secret_access_key <SECRET_KEY>
aws --endpoint-url http://localhost:8080 s3 ls
aws --endpoint-url http://localhost:8080 s3 mb s3://my-bucket
```

**Go (aws-sdk-go) Example:**
```go
package main

import (
    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/aws-sdk-go/aws/credentials"
    "github.com/aws/aws-sdk-go/aws/session"
    "github.com/aws/aws-sdk-go/service/s3"
)

func main() {
    sess, _ := session.NewSession(&aws.Config{
        Endpoint:         aws.String("http://localhost:8080"),
        Region:           aws.String("us-east-1"),
        Credentials:      credentials.NewStaticCredentials("<ACCESS_KEY>", "<SECRET_KEY>", ""),
        S3ForcePathStyle: aws.Bool(true),
        DisableSSL:       aws.Bool(true),
    })

    svc := s3.New(sess)
    result, _ := svc.ListBuckets(&s3.ListBucketsInput{})
    // Use result...
}
```

**Python boto3 Example:**
```python
import boto3

s3 = boto3.client(
    's3',
    endpoint_url='http://localhost:8080',
    aws_access_key_id='<ACCESS_KEY>',
    aws_secret_access_key='<SECRET_KEY>'
)

# List buckets
response = s3.list_buckets()
print(response['Buckets'])
```

### Cleanup Object Store

To remove the object store and sample applications:

```bash
./cleanup-object-store.sh
```

This will:
- Delete sample applications
- Delete the object store user
- Delete the CephObjectStore
- Clean up all related resources

## Customizing Manifests

All Kubernetes YAML manifests are stored in the `manifests/` directory, making them easy to customize.

### Manifest Directory Structure

```
manifests/
├── object-store/           # CephObjectStore definitions
└── sample-apps/           # Sample application code and manifests
```

### Customization Examples

**Modify Object Store Replicas:**
Edit `manifests/object-store/object-store.yaml` to change replica count:
```yaml
spec:
  metadataPool:
    replicated:
      size: 3  # Change from 1 to 3
```

**Customize Sample App:**
Edit `manifests/sample-apps/go-s3-test/main.go` to add custom S3 operations.

**Direct Manifest Usage:**
You can also apply manifests directly:
```bash
# Substitute variables manually
export NAMESPACE=rook-ceph
export OBJECT_STORE_NAME=my-store

# Apply with substitution
sed -e "s/NAMESPACE/$NAMESPACE/g" \
    -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
    manifests/object-store/object-store.yaml | kubectl apply -f -
```

See `manifests/README.md` for detailed documentation on each manifest.

## Troubleshooting

### Check operator logs
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-operator
```

### Check OSD logs
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd
```

### Access toolbox for debugging
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash
```

### Common Issues

1. **Pods stuck in Pending**: Check if Minikube has enough resources
2. **OSDs not starting**: Verify extra disks are attached to Minikube
3. **Cluster not ready**: Wait a few more minutes, initial setup can take 5-10 minutes

## Uninstallation

To remove Rook Ceph and clean up:
```bash
./uninstall-rook-ceph.sh
```

This will:
- Delete the Ceph cluster
- Remove the Rook operator
- Clean up all resources
- Optionally delete the Minikube cluster

## Resources

- [Rook Documentation](https://rook.io/docs/rook/latest/)
- [Ceph Documentation](https://docs.ceph.com/)
- [Minikube Documentation](https://minikube.sigs.k8s.io/)

## Architecture

### Single Node (default)

```
┌─────────────────────────────────────┐
│      Minikube Cluster (1 node)      │
│                                     │
│  ┌────────────────────────────┐    │
│  │   rook-ceph namespace      │    │
│  │                            │    │
│  │  ├─ rook-ceph-operator    │    │
│  │  ├─ rook-ceph-mon (x3)    │    │
│  │  ├─ rook-ceph-mgr         │    │
│  │  ├─ rook-ceph-osd (x2)    │    │
│  │  ├─ rook-ceph-tools       │    │
│  │  └─ rook-ceph-dashboard   │    │
│  └────────────────────────────┘    │
└─────────────────────────────────────┘
```

### Multi-Node (when MINIKUBE_NODES > 1)

```
┌───────────────────────────────────────────────────────┐
│          Minikube Cluster (3 nodes)                   │
│                                                       │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│  │   Node 1   │  │   Node 2   │  │   Node 3   │     │
│  └────────────┘  └────────────┘  └────────────┘     │
│                                                       │
│  ┌──────────────────────────────────────────────┐    │
│  │         rook-ceph namespace                  │    │
│  │                                              │    │
│  │  ├─ rook-ceph-operator (1)                  │    │
│  │  ├─ rook-ceph-mon (3, distributed)          │    │
│  │  ├─ rook-ceph-mgr (2, distributed)          │    │
│  │  ├─ rook-ceph-osd (per node, distributed)   │    │
│  │  ├─ rook-ceph-tools (1)                     │    │
│  │  └─ rook-ceph-dashboard (1)                 │    │
│  └──────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────┘
```

## License

MIT
