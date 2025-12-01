# TLS Configuration for Rook Ceph Object Store

This document describes how to deploy the Rook Ceph Object Store with TLS enabled.

## Overview

The object store can now be deployed with TLS support, which enables secure HTTPS connections to the S3-compatible endpoint. TLS is disabled by default and can be enabled via configuration.

## Configuration

### Option 1: Using config.env file

1. Copy the example configuration file:
   ```bash
   cp config.env.example config.env
   ```

2. Edit `config.env` and set the following variables:
   ```bash
   # Enable TLS for Object Store
   ENABLE_TLS="true"

   # TLS certificate domain name (update based on your object store name and namespace)
   TLS_CERT_DOMAIN="rook-ceph-rgw-my-store.rook-ceph.svc"

   # TLS certificate validity in days
   TLS_CERT_DAYS="365"
   ```

3. Deploy the object store:
   ```bash
   ./deploy-object-store.sh
   ```

### Option 2: Using Environment Variables

Deploy with TLS enabled directly from the command line:

```bash
ENABLE_TLS=true ./deploy-object-store.sh
```

Or with custom settings:

```bash
ENABLE_TLS=true \
TLS_CERT_DOMAIN="rook-ceph-rgw-my-store.rook-ceph.svc" \
TLS_CERT_DAYS="730" \
./deploy-object-store.sh
```

## What Happens When TLS is Enabled

1. **Certificate Generation**: A self-signed TLS certificate is automatically generated with:
   - Common Name (CN): Value from `TLS_CERT_DOMAIN`
   - Subject Alternative Names (SANs):
     - The specified domain
     - `*.rook-ceph.svc`
     - `*.rook-ceph.svc.cluster.local`
   - Validity: Number of days specified in `TLS_CERT_DAYS` (default: 365)

2. **Secret Creation**: A Kubernetes secret named `<object-store-name>-tls` is created containing:
   - `tls.crt`: The TLS certificate
   - `tls.key`: The private key

3. **Object Store Deployment**: The CephObjectStore is deployed with:
   - HTTPS enabled on port 443
   - Reference to the TLS secret

4. **Sample Application**: The Python S3 test app is configured to:
   - Use HTTPS endpoint
   - Skip certificate verification (for self-signed certificates)

## Files Modified/Created

### New Files
- `manifests/object-store/object-store-with-tls.yaml` - TLS-enabled CephObjectStore manifest
- `manifests/object-store/object-store-tls-cert.yaml` - TLS certificate secret template
- `TLS_SETUP.md` - This documentation file

### Modified Files
- `deploy-object-store.sh` - Added TLS support with automatic certificate generation
- `config.env.example` - Added TLS configuration options
- `manifests/sample-apps/python-s3-test/test_s3.py` - Added TLS support
- `manifests/sample-apps/s3-test-job.yaml` - Added S3_USE_TLS environment variable

## Accessing the TLS-Enabled Object Store

### From Inside the Cluster

Use the service DNS name:
```
https://rook-ceph-rgw-my-store.rook-ceph.svc:443
```

### From Outside the Cluster

Port-forward the HTTPS port:
```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8443:443
```

Then access via:
```
https://localhost:8443
```

**Note**: You may need to skip certificate verification when using self-signed certificates.

## Using Custom Certificates

If you want to use your own certificates instead of auto-generated self-signed ones:

1. Create a Kubernetes secret manually:
   ```bash
   kubectl -n rook-ceph create secret tls my-store-tls \
     --cert=/path/to/tls.crt \
     --key=/path/to/tls.key
   ```

2. Set `ENABLE_TLS=false` to skip auto-generation

3. Manually apply the TLS-enabled object store manifest:
   ```bash
   sed -e "s/OBJECT_STORE_NAME/my-store/g" \
       -e "s/NAMESPACE/rook-ceph/g" \
       manifests/object-store/object-store-with-tls.yaml | kubectl apply -f -
   ```

## Testing

The Python S3 test application automatically detects TLS configuration and adjusts accordingly:

```bash
# Check the job logs
kubectl -n default logs -f job/s3-test-job
```

You should see output indicating TLS is enabled:
```
Connecting to S3 endpoint: https://10.x.x.x:443
TLS enabled: True
```

## Port Information

- **HTTP (TLS disabled)**: Port 80
- **HTTPS (TLS enabled)**: Port 443

The port-forward commands in the usage instructions automatically adjust based on TLS configuration.

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_TLS` | `false` | Enable or disable TLS for the object store |
| `TLS_CERT_DOMAIN` | `rook-ceph-rgw-my-store.rook-ceph.svc` | Domain name for the TLS certificate |
| `TLS_CERT_DAYS` | `365` | Certificate validity period in days |

## Security Considerations

1. **Self-Signed Certificates**: The auto-generated certificates are self-signed and should only be used for development/testing.

2. **Certificate Verification**: The Python test app disables certificate verification (`verify=False`) to work with self-signed certificates. In production, use proper CA-signed certificates.

3. **Certificate Renewal**: Self-signed certificates expire after the specified validity period. You'll need to regenerate them before expiration.

4. **Production Use**: For production deployments, use certificates signed by a trusted Certificate Authority (CA).

## Certificate Trust Issues

If you encounter "certificate signed by unknown authority" errors, this is expected with self-signed certificates. See **[TLS_TROUBLESHOOTING.md](./TLS_TROUBLESHOOTING.md)** for detailed solutions.

### Quick Fixes

**Option 1: Skip verification (development only)**
```bash
# AWS CLI
aws s3 ls --endpoint-url https://localhost:8443 --no-verify-ssl

# curl
curl -k https://localhost:8443
```

**Option 2: Use CA bundle (recommended)**
```bash
# AWS CLI
aws s3 ls --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem

# curl
curl --cacert ./rgw-ca-cert.pem https://localhost:8443
```

The CA certificate is saved to `rgw-ca-cert.pem` in the project directory when TLS is enabled.

## Troubleshooting

### Check if TLS secret exists
```bash
kubectl -n rook-ceph get secret my-store-tls
```

### View TLS certificate details
```bash
# View from file
openssl x509 -in rgw-ca-cert.pem -text -noout

# View from Kubernetes secret
kubectl -n rook-ceph get secret my-store-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

### Check RGW pod logs
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-rgw --tail=100
```

### Verify object store configuration
```bash
kubectl -n rook-ceph get cephobjectstore my-store -o yaml
```

### Extract CA certificate from Kubernetes
If you lost the `rgw-ca-cert.pem` file:
```bash
kubectl -n rook-ceph get secret my-store-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > rgw-ca-cert.pem
```

## Examples

### Deploy with TLS enabled (single command)
```bash
ENABLE_TLS=true OBJECT_STORE_NAME=secure-store ./deploy-object-store.sh
```

### Deploy with custom certificate validity
```bash
ENABLE_TLS=true TLS_CERT_DAYS=730 ./deploy-object-store.sh
```

### Test S3 operations with TLS
```bash
# After deployment, the sample app will automatically use HTTPS
kubectl -n default logs -f job/s3-test-job
```
