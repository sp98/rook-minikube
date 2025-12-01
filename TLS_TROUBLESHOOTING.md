# TLS Troubleshooting Guide

## "Certificate Signed by Unknown Authority" Error

This error occurs because the deployment uses a **self-signed certificate** that isn't trusted by your system's certificate authority store.

### Understanding the Issue

When you deploy with `ENABLE_TLS=true`, the script:
1. Generates a self-signed TLS certificate
2. Stores it in a Kubernetes secret
3. Saves a copy to `rgw-ca-cert.pem` in the project directory

Your client (AWS CLI, curl, boto3, etc.) doesn't trust this certificate because it's not signed by a recognized Certificate Authority (CA).

---

## Solutions

### Solution 1: Skip Certificate Verification (Quick Testing)

**⚠️ WARNING: Only use this for development/testing. Never in production!**

#### AWS CLI
```bash
aws s3 ls --endpoint-url https://localhost:8443 --no-verify-ssl
```

#### curl
```bash
curl -k https://localhost:8443
# -k flag tells curl to skip certificate verification
```

#### Python (boto3)
```python
import boto3

s3_client = boto3.client(
    's3',
    endpoint_url='https://localhost:8443',
    aws_access_key_id='YOUR_ACCESS_KEY',
    aws_secret_access_key='YOUR_SECRET_KEY',
    verify=False  # Skip certificate verification
)
```

#### Go (AWS SDK)
```go
import (
    "crypto/tls"
    "net/http"
    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/aws-sdk-go/aws/session"
)

tr := &http.Transport{
    TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
}

sess := session.Must(session.NewSession(&aws.Config{
    HTTPClient: &http.Client{Transport: tr},
    Endpoint:   aws.String("https://localhost:8443"),
}))
```

---

### Solution 2: Use CA Bundle (Recommended for Development)

The deployment script saves the CA certificate to `rgw-ca-cert.pem`. Use this file to verify the connection:

#### AWS CLI
```bash
aws s3 ls --endpoint-url https://localhost:8443 \
  --ca-bundle ./rgw-ca-cert.pem
```

#### curl
```bash
curl --cacert ./rgw-ca-cert.pem https://localhost:8443
```

#### Python (boto3)
```python
import boto3

s3_client = boto3.client(
    's3',
    endpoint_url='https://localhost:8443',
    aws_access_key_id='YOUR_ACCESS_KEY',
    aws_secret_access_key='YOUR_SECRET_KEY',
    verify='./rgw-ca-cert.pem'  # Path to CA certificate
)
```

#### Go (AWS SDK)
```go
import (
    "crypto/tls"
    "crypto/x509"
    "io/ioutil"
    "net/http"
    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/aws-sdk-go/aws/session"
)

caCert, _ := ioutil.ReadFile("./rgw-ca-cert.pem")
caCertPool := x509.NewCertPool()
caCertPool.AppendCertsFromPEM(caCert)

tr := &http.Transport{
    TLSClientConfig: &tls.Config{RootCAs: caCertPool},
}

sess := session.Must(session.NewSession(&aws.Config{
    HTTPClient: &http.Client{Transport: tr},
    Endpoint:   aws.String("https://localhost:8443"),
}))
```

---

### Solution 3: Trust Certificate System-Wide (Development Environments)

Install the certificate in your system's trust store:

#### macOS
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ./rgw-ca-cert.pem
```

To remove later:
```bash
sudo security delete-certificate -c "rook-ceph-rgw-my-store.rook-ceph.svc"
```

#### Linux (Debian/Ubuntu)
```bash
sudo cp ./rgw-ca-cert.pem /usr/local/share/ca-certificates/rgw-ca-cert.crt
sudo update-ca-certificates
```

To remove later:
```bash
sudo rm /usr/local/share/ca-certificates/rgw-ca-cert.crt
sudo update-ca-certificates
```

#### Linux (RHEL/CentOS/Fedora)
```bash
sudo cp ./rgw-ca-cert.pem /etc/pki/ca-trust/source/anchors/rgw-ca-cert.crt
sudo update-ca-trust
```

To remove later:
```bash
sudo rm /etc/pki/ca-trust/source/anchors/rgw-ca-cert.crt
sudo update-ca-trust
```

---

### Solution 4: Use Production Certificates (Production Environments)

For production, use certificates from a trusted CA like Let's Encrypt, DigiCert, etc.

#### Using Custom Certificates

1. **Create a Kubernetes secret with your certificates:**
   ```bash
   kubectl -n rook-ceph create secret tls my-store-tls \
     --cert=/path/to/tls.crt \
     --key=/path/to/tls.key
   ```

2. **Deploy without auto-generated certificates:**

   Set `ENABLE_TLS=false` to skip auto-generation, then manually apply the TLS-enabled manifest:
   ```bash
   sed -e "s/OBJECT_STORE_NAME/my-store/g" \
       -e "s/NAMESPACE/rook-ceph/g" \
       manifests/object-store/object-store-with-tls.yaml | kubectl apply -f -
   ```

3. **Or modify the script:**

   Edit `deploy-object-store.sh` and comment out the `generate_tls_certificate` call, then create your secret manually before running the script.

---

## Verification Steps

### 1. Check if the certificate was created
```bash
ls -la rgw-ca-cert.pem
```

### 2. View certificate details
```bash
openssl x509 -in rgw-ca-cert.pem -text -noout
```

Look for:
- **Subject**: Should match your `TLS_CERT_DOMAIN`
- **Subject Alternative Names**: Should include localhost and 127.0.0.1
- **Validity**: Check "Not Before" and "Not After" dates

### 3. Extract certificate from Kubernetes
```bash
kubectl -n rook-ceph get secret my-store-tls -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout
```

### 4. Test TLS connection
```bash
# Test with openssl
openssl s_client -connect localhost:8443 -CAfile ./rgw-ca-cert.pem

# Test with curl (should succeed)
curl --cacert ./rgw-ca-cert.pem https://localhost:8443

# Test with curl (should fail with certificate error)
curl https://localhost:8443
```

---

## Common Issues and Fixes

### Issue: Certificate has wrong domain name

**Symptoms:**
```
curl: (60) SSL: certificate subject name does not match target host name
```

**Solution:**
Update `TLS_CERT_DOMAIN` to match the hostname you're using. The certificate includes these SANs:
- The value of `TLS_CERT_DOMAIN`
- `*.rook-ceph.svc`
- `*.rook-ceph.svc.cluster.local`
- `localhost`
- `127.0.0.1`

When using port-forward to localhost, the certificate should work. If connecting to a different hostname, regenerate with the correct domain:

```bash
ENABLE_TLS=true TLS_CERT_DOMAIN="my-custom-domain.com" ./deploy-object-store.sh
```

### Issue: Certificate expired

**Symptoms:**
```
curl: (60) SSL certificate problem: certificate has expired
```

**Solution:**
Regenerate the certificate with a new validity period:

```bash
# Redeploy with longer validity (2 years)
ENABLE_TLS=true TLS_CERT_DAYS=730 ./deploy-object-store.sh
```

### Issue: rgw-ca-cert.pem not found

**Symptoms:**
```
aws s3 ls --ca-bundle ./rgw-ca-cert.pem
# Error: Could not find file
```

**Solution:**
Extract the certificate from Kubernetes:

```bash
kubectl -n rook-ceph get secret my-store-tls -o jsonpath='{.data.tls\.crt}' | \
  base64 -d > rgw-ca-cert.pem
```

### Issue: Still getting certificate errors after system-wide trust

**Symptoms:**
Certificate errors persist even after adding to system trust store.

**Solution:**

1. **Verify installation:**
   ```bash
   # macOS
   security find-certificate -c "rook-ceph-rgw-my-store.rook-ceph.svc"

   # Linux
   ls -la /usr/local/share/ca-certificates/ | grep rgw
   ```

2. **Check certificate format:**
   The certificate must be in PEM format. Verify:
   ```bash
   openssl x509 -in rgw-ca-cert.pem -text -noout
   ```

3. **Restart applications:**
   Some applications cache the trust store. Restart them after installing the certificate.

4. **Check application-specific trust stores:**
   Some applications (like Python) use their own trust stores. Use the CA bundle method instead.

---

## Testing After Fixes

### Test with AWS CLI
```bash
# Set up port-forward
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8443:443 &

# Get credentials
ACCESS_KEY=$(kubectl -n rook-ceph get secret rook-ceph-object-user-my-store-my-user \
  -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl -n rook-ceph get secret rook-ceph-object-user-my-store-my-user \
  -o jsonpath='{.data.SecretKey}' | base64 -d)

# Configure AWS CLI
aws configure set aws_access_key_id "$ACCESS_KEY"
aws configure set aws_secret_access_key "$SECRET_KEY"

# Test with CA bundle
aws s3 ls --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem

# Create a test bucket
aws s3 mb s3://test-bucket --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem

# Upload a file
echo "Hello from TLS" > test.txt
aws s3 cp test.txt s3://test-bucket/ --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem

# List objects
aws s3 ls s3://test-bucket/ --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem
```

### Test with Python
```python
#!/usr/bin/env python3
import boto3
import os

endpoint = 'https://localhost:8443'
access_key = os.getenv('ACCESS_KEY')
secret_key = os.getenv('SECRET_KEY')

# Test with CA bundle
s3_client = boto3.client(
    's3',
    endpoint_url=endpoint,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    verify='./rgw-ca-cert.pem'
)

# List buckets
response = s3_client.list_buckets()
print("Buckets:", [b['Name'] for b in response['Buckets']])
```

---

## Environment Variables for Scripts

Set these to avoid repeating the CA bundle parameter:

```bash
# For AWS CLI
export AWS_CA_BUNDLE=./rgw-ca-cert.pem

# For curl
alias curl='curl --cacert ./rgw-ca-cert.pem'

# For Python requests
export REQUESTS_CA_BUNDLE=./rgw-ca-cert.pem

# For Go
export SSL_CERT_FILE=./rgw-ca-cert.pem
```

---

## Production Best Practices

1. **Never use self-signed certificates in production**
2. **Use certificates from a trusted CA** (Let's Encrypt, DigiCert, etc.)
3. **Never disable certificate verification in production code**
4. **Rotate certificates before expiration**
5. **Use cert-manager** for automated certificate management in Kubernetes:
   ```bash
   # Example with cert-manager
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
   ```

---

## Additional Resources

- [Rook Ceph Object Store Documentation](https://rook.io/docs/rook/latest/CRDs/Object-Storage/ceph-object-store-crd/)
- [OpenSSL Certificate Commands](https://www.openssl.org/docs/man1.1.1/man1/openssl-x509.html)
- [AWS CLI SSL Configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html)
- [Boto3 SSL Configuration](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/configuration.html)
