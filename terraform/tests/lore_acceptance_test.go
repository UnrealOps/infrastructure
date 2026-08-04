package tests

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

type loreAcceptanceConfig struct {
	image             string
	runtimeSecretName string
	caFile            string
	client            string
}

type loreECRImage struct {
	accountID  string
	region     string
	repository string
	digest     string
}

var loreECRImagePattern = regexp.MustCompile(`^([0-9]{12})\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/([a-z0-9][a-z0-9/_-]*)@(sha256:[0-9a-f]{64})$`)

func parseLoreECRImage(image string) (loreECRImage, bool) {
	matches := loreECRImagePattern.FindStringSubmatch(image)
	if matches == nil {
		return loreECRImage{}, false
	}
	return loreECRImage{
		accountID:  matches[1],
		region:     matches[2],
		repository: matches[3],
		digest:     matches[4],
	}, true
}

func loadLoreAcceptanceConfig(t *testing.T, region string) *loreAcceptanceConfig {
	t.Helper()
	image := os.Getenv("TEST_LORE_IMAGE")
	related := []string{
		"TEST_LORE_RUNTIME_SECRET_NAME",
		"TEST_LORE_CA_FILE",
		"TEST_LORE_CLIENT",
	}
	if image == "" {
		for _, name := range related {
			require.Empty(t, os.Getenv(name), "%s was set without TEST_LORE_IMAGE", name)
		}
		t.Log("Lore live acceptance is disabled; set TEST_LORE_IMAGE and the documented Lore inputs to enable it")
		return nil
	}

	config := &loreAcceptanceConfig{
		image:             image,
		runtimeSecretName: requiredEnv(t, "TEST_LORE_RUNTIME_SECRET_NAME"),
		caFile:            requiredEnv(t, "TEST_LORE_CA_FILE"),
		client:            requiredEnv(t, "TEST_LORE_CLIENT"),
	}
	parsedImage, ok := parseLoreECRImage(config.image)
	require.True(t, ok, "TEST_LORE_IMAGE must be an immutable private ECR URI ending in @sha256:<64 lowercase hex characters>")
	require.Equal(t, requiredEnv(t, "TEST_AWS_ACCOUNT_ID"), parsedImage.accountID,
		"Lore acceptance image must be in the explicitly authorized AWS account")
	require.Equal(t, region, parsedImage.region,
		"Lore acceptance image must be in the explicitly authorized AWS region")
	info, err := os.Stat(config.caFile)
	require.NoError(t, err, "stat Lore acceptance CA")
	require.False(t, info.IsDir(), "TEST_LORE_CA_FILE must be a file")
	info, err = os.Stat(config.client)
	require.NoError(t, err, "stat Lore client")
	require.False(t, info.IsDir(), "TEST_LORE_CLIENT must be an executable file")
	require.NotZero(t, info.Mode()&0o111, "TEST_LORE_CLIENT must be executable")
	assertLoreAcceptanceImagePlatforms(t, region, parsedImage)
	return config
}

func assertLoreAcceptanceImagePlatforms(t *testing.T, region string, image loreECRImage) {
	t.Helper()
	manifest := awsText(t, region, "ecr", "batch-get-image",
		"--repository-name", image.repository,
		"--image-ids", "imageDigest="+image.digest,
		"--query", "images[0].imageManifest")
	require.NotEqual(t, "None", manifest, "Lore acceptance image digest was not found in ECR")
	var imageIndex struct {
		Manifests []struct {
			Platform struct {
				Architecture string `json:"architecture"`
				OS           string `json:"os"`
			} `json:"platform"`
		} `json:"manifests"`
	}
	require.NoError(t, json.Unmarshal([]byte(manifest), &imageIndex))
	platforms := map[string]bool{}
	for _, entry := range imageIndex.Manifests {
		if entry.Platform.OS == "linux" {
			platforms[entry.Platform.Architecture] = true
		}
	}
	require.True(t, platforms["amd64"], "Lore acceptance image is missing linux/amd64")
	require.True(t, platforms["arm64"], "Lore acceptance image is missing linux/arm64")
}

func assertLoreFoundation(t *testing.T, region, clusterName string, foundation *terraform.Options) {
	t.Helper()

	repositoryURL := terraform.Output(t, foundation, "lore_ecr_repository_url")
	require.Contains(t, repositoryURL, ".dkr.ecr."+region+".amazonaws.com/")
	require.Equal(t, clusterName+"/lore-server", awsText(t, region, "ecr", "describe-repositories",
		"--repository-names", clusterName+"/lore-server",
		"--query", "repositories[0].repositoryName"))
	require.Equal(t, "IMMUTABLE", awsText(t, region, "ecr", "describe-repositories",
		"--repository-names", clusterName+"/lore-server",
		"--query", "repositories[0].imageTagMutability"))
	require.Equal(t, "true", strings.ToLower(awsText(t, region, "ecr", "describe-repositories",
		"--repository-names", clusterName+"/lore-server",
		"--query", "repositories[0].imageScanningConfiguration.scanOnPush")))
	require.Equal(t, "AES256", awsText(t, region, "ecr", "describe-repositories",
		"--repository-names", clusterName+"/lore-server",
		"--query", "repositories[0].encryptionConfiguration.encryptionType"))

	bucket := terraform.Output(t, foundation, "lore_bucket_name")
	require.Equal(t, "Enabled", awsText(t, region, "s3api", "get-bucket-versioning",
		"--bucket", bucket, "--query", "Status"))
	require.Equal(t, "aws:kms", awsText(t, region, "s3api", "get-bucket-encryption",
		"--bucket", bucket,
		"--query", "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm"))
	require.Equal(t, "true", strings.ToLower(awsText(t, region, "s3api", "get-bucket-encryption",
		"--bucket", bucket,
		"--query", "ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled")))
	for _, setting := range []string{"BlockPublicAcls", "BlockPublicPolicy", "IgnorePublicAcls", "RestrictPublicBuckets"} {
		require.Equal(t, "true", strings.ToLower(awsText(t, region, "s3api", "get-public-access-block",
			"--bucket", bucket, "--query", "PublicAccessBlockConfiguration."+setting)), setting)
	}

	tableNames := terraform.OutputMap(t, foundation, "lore_table_names")
	require.Len(t, tableNames, 4)
	for logicalName, tableName := range tableNames {
		require.Equal(t, "ACTIVE", awsText(t, region, "dynamodb", "describe-table",
			"--table-name", tableName, "--query", "Table.TableStatus"), logicalName)
		require.Equal(t, "PAY_PER_REQUEST", awsText(t, region, "dynamodb", "describe-table",
			"--table-name", tableName, "--query", "Table.BillingModeSummary.BillingMode"), logicalName)
		require.Equal(t, "ENABLED", awsText(t, region, "dynamodb", "describe-continuous-backups",
			"--table-name", tableName,
			"--query", "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus"), logicalName)
		require.Equal(t, "ENABLED", awsText(t, region, "dynamodb", "describe-table",
			"--table-name", tableName, "--query", "Table.SSEDescription.Status"), logicalName)
		require.Equal(t, "false", strings.ToLower(awsText(t, region, "dynamodb", "describe-table",
			"--table-name", tableName, "--query", "Table.DeletionProtectionEnabled")), logicalName)
	}
	require.Equal(t, "3", awsText(t, region, "dynamodb", "describe-table",
		"--table-name", tableNames["locks"], "--query", "length(Table.GlobalSecondaryIndexes)"))

	hostedZoneID := terraform.Output(t, foundation, "lore_hosted_zone_id")
	hostedZoneVPC := awsText(t, region, "route53", "get-hosted-zone",
		"--id", hostedZoneID, "--query", "VPCs[0].VPCId")
	require.NotEmpty(t, hostedZoneVPC)
	require.NotEqual(t, "None", hostedZoneVPC)
	require.NotEmpty(t, terraform.Output(t, foundation, "lore_nlb_security_group_id"))
	require.Len(t, terraform.OutputMap(t, foundation, "lore_pod_identity_role_arns"), 3)
	require.NotEmpty(t, terraform.Output(t, foundation, "lore_load_balancer_controller_role_arn"))
}

func testLoreAcceptance(
	t *testing.T,
	region string,
	clusterName string,
	kubeconfig string,
	config *loreAcceptanceConfig,
	foundation *terraform.Options,
	addons *terraform.Options,
) {
	t.Helper()

	endpoint := terraform.Output(t, addons, "lore_endpoint")
	hostname := strings.TrimSuffix(strings.TrimPrefix(endpoint, "lores://"), ":41337")
	require.Equal(t, terraform.Output(t, foundation, "lore_endpoint_hostname"), hostname)
	require.Equal(t, config.image, terraform.Output(t, addons, "lore_deployed_image"))
	require.NotEmpty(t, terraform.Output(t, addons, "lore_nlb_name"))
	require.NotEmpty(t, terraform.Output(t, addons, "lore_nlb_dns_name"))

	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"rollout", "status", "deployment/lore-write", "--timeout=30m")
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"rollout", "status", "deployment/lore-edge", "--timeout=45m")
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"rollout", "status", "deployment/lore-otel", "--timeout=10m")

	require.Eventually(t, func() bool {
		addresses, err := net.LookupIP(hostname)
		if err != nil || len(addresses) == 0 {
			return false
		}
		for _, address := range addresses {
			if !address.IsPrivate() {
				return false
			}
		}
		return true
	}, 10*time.Minute, 10*time.Second, "Lore private DNS did not resolve through OpenVPN")
	waitForTCP(t, net.JoinHostPort(hostname, "41337"), 10*time.Minute)
	assertLoreTLS(t, hostname, config.caFile)

	nlbName := terraform.Output(t, addons, "lore_nlb_name")
	require.Equal(t, "internal", awsText(t, region, "elbv2", "describe-load-balancers",
		"--names", nlbName, "--query", "LoadBalancers[0].Scheme"))
	require.Equal(t, "ip", awsText(t, region, "elbv2", "describe-target-groups",
		"--load-balancer-arn", awsText(t, region, "elbv2", "describe-load-balancers",
			"--names", nlbName, "--query", "LoadBalancers[0].LoadBalancerArn"),
		"--query", "TargetGroups[0].TargetType"))

	testLoreDataPlane(t, region, clusterName, hostname, config, terraform.Output(t, foundation, "lore_bucket_name"))
	testLoreWriteTierRecovery(t, kubeconfig, hostname, config)
	testLoreEdgeRecovery(t, kubeconfig, hostname, config)
	testLoreAWSRecoveryControls(
		t,
		region,
		clusterName,
		terraform.Output(t, foundation, "lore_bucket_name"),
		terraform.OutputMap(t, foundation, "lore_table_names")["mutable_store"],
	)
	assertDefaultServiceAccountHasNoAWSCredentials(t, region, clusterName, kubeconfig, config.image)
}

func assertLoreTLS(t *testing.T, hostname, caFile string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := runCommandE(ctx, nil, "openssl", "s_client",
		"-connect", net.JoinHostPort(hostname, "41337"),
		"-servername", hostname,
		"-verify_hostname", hostname,
		"-verify_return_error",
		"-CAfile", caFile,
		"-brief")
	require.NoError(t, err, "Lore TLS verification failed: %s", output)
	require.Contains(t, output, "Verification: OK")
}

func testLoreDataPlane(t *testing.T, region, clusterName, hostname string, config *loreAcceptanceConfig, bucket string) {
	t.Helper()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	clone := filepath.Join(root, "clone")
	require.NoError(t, os.MkdirAll(filepath.Join(source, "Content", "Characters"), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(source, "Content", "World"), 0o755))

	files := []string{
		filepath.Join(source, "Content", "Characters", "hero.bin"),
		filepath.Join(source, "Content", "World", "level.bin"),
	}
	for index, path := range files {
		writeDeterministicBinary(t, path, byte(31+index), 64*1024*1024)
	}

	repositoryURL := fmt.Sprintf("lores://%s:41337/acceptance-%s", hostname, os.Getenv("TEST_RUN_ID"))
	runLore(t, config, source, "repository", "create", repositoryURL)
	runLore(t, config, source, "stage", "--scan", ".")
	runLore(t, config, source, "commit", "acceptance initial binary tree")
	runLore(t, config, source, "push")
	firstSize := loreBucketBytes(t, region, bucket)
	require.Positive(t, firstSize)

	file, err := os.OpenFile(files[0], os.O_WRONLY, 0)
	require.NoError(t, err)
	patch := make([]byte, 1024*1024)
	for index := range patch {
		patch[index] = byte(index%251 + 1)
	}
	_, err = file.WriteAt(patch, 24*1024*1024)
	require.NoError(t, err)
	require.NoError(t, file.Close())
	runLore(t, config, source, "stage", "Content/Characters/hero.bin")
	runLore(t, config, source, "commit", "acceptance small binary edit")
	runLore(t, config, source, "push")
	secondSize := loreBucketBytes(t, region, bucket)
	require.Greater(t, secondSize, firstSize)
	require.Less(t, secondSize-firstSize, firstSize/2, "small edit did not exhibit fragment-level deduplication")

	runLore(t, config, root, "clone", repositoryURL, clone)
	for _, sourcePath := range files {
		relative, err := filepath.Rel(source, sourcePath)
		require.NoError(t, err)
		require.Equal(t, sha256File(t, sourcePath), sha256File(t, filepath.Join(clone, relative)))
	}

	runLore(t, config, source, "lock", "acquire", "Content/Characters/hero.bin")
	query := runLore(t, config, clone, "lock", "query", "--path", "Content/Characters/hero.bin")
	require.Contains(t, query, "Content/Characters/hero.bin")
	runLore(t, config, source, "lock", "release", "Content/Characters/hero.bin")

	t.Logf("Lore data-plane validation completed for %s with deduplicated S3 growth %d -> %d bytes", clusterName, firstSize, secondSize)
}

func testLoreEdgeRecovery(t *testing.T, kubeconfig, hostname string, config *loreAcceptanceConfig) {
	t.Helper()
	pod := strings.TrimSpace(runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"get", "pods", "-l", "app.kubernetes.io/component=edge",
		"-o", "jsonpath={.items[0].metadata.name}"))
	require.NotEmpty(t, pod)
	node := strings.TrimSpace(runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"get", "pod", pod, "-o", "jsonpath={.spec.nodeName}"))
	require.NotEmpty(t, node)
	nodeClaim := nodeClaimForNode(t, kubeconfig, node)
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"delete", "pod", pod, "--wait=false")
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig,
		"delete", "nodeclaim", nodeClaim, "--wait=false")
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"rollout", "status", "deployment/lore-edge", "--timeout=45m")

	repositoryURL := fmt.Sprintf("lores://%s:41337/acceptance-%s", hostname, os.Getenv("TEST_RUN_ID"))
	recoveryClone := filepath.Join(t.TempDir(), "recovery-clone")
	runLore(t, config, filepath.Dir(recoveryClone), "clone", repositoryURL, recoveryClone)
	require.FileExists(t, filepath.Join(recoveryClone, "Content", "Characters", "hero.bin"))
}

func testLoreWriteTierRecovery(t *testing.T, kubeconfig, hostname string, config *loreAcceptanceConfig) {
	t.Helper()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	clone := filepath.Join(root, "clone")
	require.NoError(t, os.MkdirAll(source, 0o755))
	payload := filepath.Join(source, "write-failover.bin")
	writeDeterministicBinary(t, payload, 91, 256*1024*1024)

	repositoryURL := fmt.Sprintf("lores://%s:41337/write-failover-%s", hostname, os.Getenv("TEST_RUN_ID"))
	runLore(t, config, source, "repository", "create", repositoryURL)
	runLore(t, config, source, "stage", "--scan", ".")
	runLore(t, config, source, "commit", "write tier failover payload")

	commandContext, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	command := exec.CommandContext(commandContext, config.client, "push")
	command.Dir = source
	command.Env = append(os.Environ(),
		"SSL_CERT_FILE="+config.caFile,
		"GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="+config.caFile,
	)
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	require.NoError(t, command.Start())
	done := make(chan error, 1)
	go func() {
		done <- command.Wait()
	}()

	select {
	case err := <-done:
		require.NoError(t, err, "Lore push failed before write-tier disruption: %s", output.String())
		t.Fatal("Lore push completed before write-tier disruption could be exercised")
	case <-time.After(100 * time.Millisecond):
	}

	writePod := strings.TrimSpace(runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"get", "pods", "-l", "app.kubernetes.io/component=write",
		"-o", "jsonpath={.items[0].metadata.name}"))
	require.NotEmpty(t, writePod)
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"delete", "pod", writePod, "--wait=false")

	select {
	case err := <-done:
		require.NoError(t, err, "Lore push did not survive write-tier disruption: %s", output.String())
	case <-commandContext.Done():
		err := <-done
		t.Fatalf("Lore push timed out after write-tier disruption (%v): %s", err, output.String())
	}
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "lore",
		"rollout", "status", "deployment/lore-write", "--timeout=30m")

	runLore(t, config, root, "clone", repositoryURL, clone)
	require.Equal(t, sha256File(t, payload), sha256File(t, filepath.Join(clone, "write-failover.bin")))
}

func testLoreAWSRecoveryControls(t *testing.T, region, clusterName, bucket, sourceTable string) {
	t.Helper()
	testLoreS3VersionRecovery(t, region, bucket)
	testLoreDynamoDBPITR(t, region, clusterName, sourceTable)
}

func testLoreS3VersionRecovery(t *testing.T, region, bucket string) {
	t.Helper()
	key := "acceptance-recovery/" + os.Getenv("TEST_RUN_ID") + "/versioned-object.bin"
	defer cleanupLoreS3Versions(t, region, bucket, key)

	root := t.TempDir()
	firstPath := filepath.Join(root, "first.bin")
	secondPath := filepath.Join(root, "second.bin")
	recoveredPath := filepath.Join(root, "recovered.bin")
	require.NoError(t, os.WriteFile(firstPath, []byte("lore-recovery-version-one"), 0o600))
	require.NoError(t, os.WriteFile(secondPath, []byte("lore-recovery-version-two"), 0o600))

	firstVersion := awsText(t, region, "s3api", "put-object",
		"--bucket", bucket, "--key", key, "--body", firstPath, "--query", "VersionId")
	secondVersion := awsText(t, region, "s3api", "put-object",
		"--bucket", bucket, "--key", key, "--body", secondPath, "--query", "VersionId")
	require.NotEmpty(t, firstVersion)
	require.NotEqual(t, firstVersion, secondVersion)
	runCommand(t, nil, "aws", "--region", region, "s3api", "get-object",
		"--bucket", bucket, "--key", key, "--version-id", firstVersion, recoveredPath)
	require.Equal(t, sha256File(t, firstPath), sha256File(t, recoveredPath))
}

func cleanupLoreS3Versions(t *testing.T, region, bucket, key string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	output, err := runCommandE(ctx, nil, "aws", "--region", region, "s3api", "list-object-versions",
		"--bucket", bucket, "--prefix", key, "--output", "json")
	if err != nil {
		t.Errorf("list Lore S3 recovery versions for cleanup: %v", err)
		return
	}
	var inventory struct {
		Versions []struct {
			Key       string `json:"Key"`
			VersionID string `json:"VersionId"`
		} `json:"Versions"`
		DeleteMarkers []struct {
			Key       string `json:"Key"`
			VersionID string `json:"VersionId"`
		} `json:"DeleteMarkers"`
	}
	if err := json.Unmarshal([]byte(output), &inventory); err != nil {
		t.Errorf("decode Lore S3 recovery version inventory: %v", err)
		return
	}
	objects := append(inventory.Versions, inventory.DeleteMarkers...)
	for _, object := range objects {
		if object.Key != key {
			continue
		}
		if output, err := runCommandE(ctx, nil, "aws", "--region", region, "s3api", "delete-object",
			"--bucket", bucket, "--key", key, "--version-id", object.VersionID); err != nil {
			t.Errorf("delete Lore S3 recovery version %s: %v: %s", object.VersionID, err, output)
		}
	}
}

func testLoreDynamoDBPITR(t *testing.T, region, clusterName, sourceTable string) {
	t.Helper()
	targetTable := clusterName + "-lore-pitr-restore"
	defer cleanupLoreDynamoDBRestore(t, region, targetTable)

	restoredARN := awsText(t, region, "dynamodb", "restore-table-to-point-in-time",
		"--source-table-name", sourceTable,
		"--target-table-name", targetTable,
		"--use-latest-restorable-time",
		"--query", "TableDescription.TableArn")
	require.NotEmpty(t, restoredARN)
	require.Eventually(t, func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		status, err := runCommandE(ctx, nil, "aws", "--region", region, "dynamodb", "describe-table",
			"--table-name", targetTable, "--query", "Table.TableStatus", "--output", "text")
		return err == nil && strings.TrimSpace(status) == "ACTIVE"
	}, 20*time.Minute, 15*time.Second, "DynamoDB PITR restore did not become ACTIVE")
	runCommand(t, nil, "aws", "--region", region, "dynamodb", "tag-resource",
		"--resource-arn", restoredARN,
		"--tags", "Key=Environment,Value="+clusterName, "Key=ManagedBy,Value=Terratest")
	require.Equal(t, "ENABLED", awsText(t, region, "dynamodb", "describe-table",
		"--table-name", targetTable, "--query", "Table.SSEDescription.Status"))
}

func cleanupLoreDynamoDBRestore(t *testing.T, region, table string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	output, err := runCommandE(ctx, nil, "aws", "--region", region, "dynamodb", "delete-table",
		"--table-name", table)
	if err != nil {
		if strings.Contains(output, "ResourceNotFoundException") {
			return
		}
		t.Errorf("delete Lore PITR restore table: %v: %s", err, output)
		return
	}
	for {
		output, err = runCommandE(ctx, nil, "aws", "--region", region, "dynamodb", "describe-table",
			"--table-name", table)
		if err != nil && strings.Contains(output, "ResourceNotFoundException") {
			return
		}
		if err != nil {
			t.Errorf("inspect Lore PITR restore table during cleanup: %v: %s", err, output)
			return
		}
		if ctx.Err() != nil {
			t.Errorf("Lore PITR restore table %s was not deleted: %v", table, ctx.Err())
			return
		}
		time.Sleep(10 * time.Second)
	}
}

func assertDefaultServiceAccountHasNoAWSCredentials(
	t *testing.T,
	region, clusterName, kubeconfig, image string,
) {
	t.Helper()
	require.Equal(t, "0", awsText(t, region, "eks", "list-pod-identity-associations",
		"--cluster-name", clusterName,
		"--namespace", "default",
		"--service-account", "default",
		"--query", "length(associations)"))

	podName := "lore-default-identity-denial"
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		_, _ = runCommandE(ctx, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "default",
			"delete", "pod", podName, "--ignore-not-found=true", "--wait=false")
	}()
	manifest := fmt.Sprintf(`apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: default
spec:
  restartPolicy: Never
  serviceAccountName: default
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: verify
      image: %s
      command:
        - /bin/sh
        - -ec
        - |
          test -z "${AWS_ROLE_ARN:-}"
          if [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]; then
            test -n "${AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE:-}"
            if curl --fail --silent --show-error --max-time 3 \
              --header "Authorization: $(cat "${AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE}")" \
              "${AWS_CONTAINER_CREDENTIALS_FULL_URI}" >/dev/null 2>&1; then
              exit 1
            fi
          fi
          if token="$(curl --fail --silent --show-error --max-time 3 \
            --request PUT \
            --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
            http://169.254.169.254/latest/api/token 2>/dev/null)" && [ -n "${token}" ]; then
            role="$(curl --fail --silent --show-error --max-time 3 \
              --header "X-aws-ec2-metadata-token: ${token}" \
              http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || true)"
            test -z "${role}"
          fi
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
`, podName, image)
	runCommand(t, []byte(manifest), "kubectl", "--kubeconfig", kubeconfig, "apply", "-f", "-")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	output, err := runCommandE(ctx, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "default",
		"wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/"+podName, "--timeout=4m")
	if err != nil {
		logContext, logCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer logCancel()
		logs, _ := runCommandE(logContext, nil, "kubectl", "--kubeconfig", kubeconfig, "-n", "default",
			"logs", podName)
		t.Fatalf("default service account credential-denial pod failed: %s\n%s", output, logs)
	}
}

func nodeClaimForNode(t *testing.T, kubeconfig, node string) string {
	t.Helper()
	providerID := strings.TrimSpace(runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig,
		"get", "node", node, "-o", "jsonpath={.spec.providerID}"))
	require.NotEmpty(t, providerID)
	output := runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig,
		"get", "nodeclaims", "-o", "json")
	var claims struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Status struct {
				ProviderID string `json:"providerID"`
			} `json:"status"`
		} `json:"items"`
	}
	require.NoError(t, json.Unmarshal([]byte(output), &claims))
	for _, claim := range claims.Items {
		if claim.Status.ProviderID == providerID {
			return claim.Metadata.Name
		}
	}
	t.Fatalf("no NodeClaim owns edge node %s with provider ID %s", node, providerID)
	return ""
}

func runLore(t *testing.T, config *loreAcceptanceConfig, directory string, arguments ...string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, config.client, arguments...)
	command.Dir = directory
	command.Env = append(os.Environ(),
		"SSL_CERT_FILE="+config.caFile,
		"GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="+config.caFile,
	)
	output, err := command.CombinedOutput()
	require.NoError(t, err, "lore %s: %s", strings.Join(arguments, " "), output)
	return string(output)
}

func writeDeterministicBinary(t *testing.T, path string, seed byte, size int64) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	require.NoError(t, err)
	defer func() {
		require.NoError(t, file.Close())
	}()
	buffer := make([]byte, 1024*1024)
	generator := rand.New(rand.NewSource(int64(seed)))
	for written := int64(0); written < size; {
		_, err = generator.Read(buffer)
		require.NoError(t, err)
		count, err := file.Write(buffer)
		require.NoError(t, err)
		written += int64(count)
	}
}

func sha256File(t *testing.T, path string) string {
	t.Helper()
	file, err := os.Open(path)
	require.NoError(t, err)
	defer func() {
		require.NoError(t, file.Close())
	}()
	hash := sha256.New()
	_, err = io.Copy(hash, file)
	require.NoError(t, err)
	return hex.EncodeToString(hash.Sum(nil))
}

func loreBucketBytes(t *testing.T, region, bucket string) int64 {
	t.Helper()
	output := awsText(t, region, "s3api", "list-objects-v2",
		"--bucket", bucket, "--query", "sum(Contents[].Size)")
	if output == "None" {
		return 0
	}
	value, err := strconv.ParseInt(output, 10, 64)
	require.NoError(t, err)
	return value
}

func awsText(t *testing.T, region string, arguments ...string) string {
	t.Helper()
	fullArguments := append([]string{"--region", region}, arguments...)
	fullArguments = append(fullArguments, "--output", "text")
	output := runCommand(t, nil, "aws", fullArguments...)
	return strings.TrimSpace(output)
}
