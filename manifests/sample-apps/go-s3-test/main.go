package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
)

func main() {
	// Get credentials from environment
	endpoint := os.Getenv("S3_ENDPOINT")
	accessKey := os.Getenv("S3_ACCESS_KEY")
	secretKey := os.Getenv("S3_SECRET_KEY")

	fmt.Printf("Connecting to S3 endpoint: %s\n", endpoint)

	// Create S3 session
	sess, err := session.NewSession(&aws.Config{
		Endpoint:         aws.String(endpoint),
		Region:           aws.String("us-east-1"),
		Credentials:      credentials.NewStaticCredentials(accessKey, secretKey, ""),
		S3ForcePathStyle: aws.Bool(true),
		DisableSSL:       aws.Bool(true),
	})
	if err != nil {
		fmt.Printf("✗ Failed to create session: %v\n", err)
		os.Exit(1)
	}

	// Create S3 client
	svc := s3.New(sess)
	bucketName := "test-bucket"

	// Create bucket
	fmt.Printf("Creating bucket: %s\n", bucketName)
	_, err = svc.CreateBucket(&s3.CreateBucketInput{
		Bucket: aws.String(bucketName),
	})
	if err != nil {
		fmt.Printf("✗ Failed to create bucket: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("✓ Bucket created successfully!")

	// Upload a test file
	fmt.Println("Uploading test file...")
	testContent := "Hello from Rook Ceph Object Store!"
	_, err = svc.PutObject(&s3.PutObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String("test.txt"),
		Body:   bytes.NewReader([]byte(testContent)),
	})
	if err != nil {
		fmt.Printf("✗ Failed to upload file: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("✓ File uploaded successfully!")

	// List buckets
	fmt.Println("\nListing all buckets:")
	listBucketsResult, err := svc.ListBuckets(&s3.ListBucketsInput{})
	if err != nil {
		fmt.Printf("✗ Failed to list buckets: %v\n", err)
		os.Exit(1)
	}
	for _, bucket := range listBucketsResult.Buckets {
		fmt.Printf("  - %s\n", *bucket.Name)
	}

	// List objects in bucket
	fmt.Printf("\nListing objects in %s:\n", bucketName)
	listObjectsResult, err := svc.ListObjectsV2(&s3.ListObjectsV2Input{
		Bucket: aws.String(bucketName),
	})
	if err != nil {
		fmt.Printf("✗ Failed to list objects: %v\n", err)
		os.Exit(1)
	}
	for _, obj := range listObjectsResult.Contents {
		fmt.Printf("  - %s (%d bytes)\n", *obj.Key, *obj.Size)
	}

	// Download and verify
	fmt.Println("\nDownloading and verifying file...")
	getObjectResult, err := svc.GetObject(&s3.GetObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String("test.txt"),
	})
	if err != nil {
		fmt.Printf("✗ Failed to download file: %v\n", err)
		os.Exit(1)
	}
	defer getObjectResult.Body.Close()

	buf := new(strings.Builder)
	_, err = io.Copy(buf, getObjectResult.Body)
	if err != nil {
		fmt.Printf("✗ Failed to read file content: %v\n", err)
		os.Exit(1)
	}
	content := buf.String()
	fmt.Printf("Content: %s\n", content)

	if content == testContent {
		fmt.Println("✓ Content verified successfully!")
	} else {
		fmt.Println("✗ Content verification failed!")
		os.Exit(1)
	}

	fmt.Println("\n" + strings.Repeat("=", 50))
	fmt.Println("All S3 operations completed successfully!")
	fmt.Println(strings.Repeat("=", 50))
}
