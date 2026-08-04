package tests

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoreFoundationContracts(t *testing.T) {
	root := repositoryRoot(t)
	infra := filepath.Join(root, "terraform/modules/lore-infra/main.tf")
	eks := filepath.Join(root, "terraform/modules/eks/main.tf")

	for _, expected := range []string{
		`image_tag_mutability = "IMMUTABLE"`,
		`scan_on_push = true`,
		`encryption_type = "AES256"`,
		`bucket_key_enabled = true`,
		`status = "Enabled"`,
		`noncurrent_days = 30`,
		`days_after_initiation = 7`,
		`billing_mode                = "PAY_PER_REQUEST"`,
		`deletion_protection_enabled = var.deletion_protection`,
		`kms_key_arn = aws_kms_key.lore.arn`,
		`name            = "owner-repo-branch"`,
		`name            = "repo-branch"`,
		`name            = "repo-branch-description"`,
		`service_account = "lore-edge"`,
		`service_account = "lore-write"`,
		`service_account = "lore-otel"`,
		`prefix_list_id    = var.vpn_source_prefix_list_id`,
	} {
		assertFileContains(t, infra, expected)
	}

	for _, forbidden := range []string{"ARCHIVE_ACCESS", "DEEP_ARCHIVE_ACCESS", "secret_string", "terraform_remote_state"} {
		contents, err := os.ReadFile(infra)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(contents), forbidden) {
			t.Errorf("%s must not contain %q", infra, forbidden)
		}
	}

	for _, expected := range []string{
		`"application"`,
		`"dataplane"`,
		`"host"`,
		`"performance"`,
		`name              = "/aws/containerinsights/${var.cluster_name}/${each.value}"`,
		`depends_on = [aws_cloudwatch_log_group.container_insights]`,
	} {
		assertFileContains(t, eks, expected)
	}
}

func TestLoreDynamoDBSchemasMatchPinnedSource(t *testing.T) {
	root := repositoryRoot(t)
	infra := filepath.Join(root, "terraform/modules/lore-infra/main.tf")

	for _, expected := range []string{
		`hash_key                    = "hash"`,
		`range_key                   = "repository_context"`,
		`hash_key                    = "repository_id"`,
		`range_key                   = "key"`,
		`range_key                   = "repositoryBranch"`,
		`attribute_name = "ownerId"`,
		`attribute_name = "repositoryBranch"`,
		`attribute_name = "repository"`,
		`attribute_name = "branch"`,
		`attribute_name = "description"`,
		`key_type       = "HASH"`,
		`key_type       = "RANGE"`,
	} {
		assertFileContains(t, infra, expected)
	}
}

func TestLoreWorkloadSecurityAndTopologyContracts(t *testing.T) {
	root := repositoryRoot(t)
	chart := filepath.Join(root, "terraform/modules/lore-workload/charts/lore/templates")
	expectedByFile := map[string][]string{
		"edge-nodepool.yaml": {
			"instanceStorePolicy: RAID0",
			"karpenter.sh/capacity-type",
			"karpenter.sh/discovery:",
			"Environment:",
			"- on-demand",
			"consolidationPolicy: WhenEmpty",
			"consolidateAfter: 30m",
			`nodes: "1"`,
		},
		"edge.yaml": {
			"ephemeral-storage: 750Gi",
			"maxUnavailable: 1",
			"minAvailable: 2",
			"requiredDuringSchedulingIgnoredDuringExecution",
			"topology.kubernetes.io/zone",
		},
		"_helpers.tpl": {
			"readOnlyRootFilesystem: true",
			"allowPrivilegeEscalation: false",
			"type: RuntimeDefault",
		},
		"write.yaml": {
			"ephemeral-storage: 30Gi",
			"minAvailable: 1",
			"karpenter.sh/capacity-type: on-demand",
		},
		"services.yaml": {
			"service.beta.kubernetes.io/aws-load-balancer-scheme: internal",
			"service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip",
			"service.beta.kubernetes.io/aws-load-balancer-enable-tcp-udp-listener",
			"service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules",
			"service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: \"41339\"",
			"service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags:",
			"deregistration_delay.timeout_seconds=30",
		},
		"secretproviderclasses.yaml": {
			`usePodIdentity: "true"`,
		},
		"networkpolicies.yaml": {
			"name: default-deny",
			"port: 443",
			"port: 41340",
			"port: 4317",
			"port: 13133",
		},
	}

	for file, expectedValues := range expectedByFile {
		path := filepath.Join(chart, file)
		for _, expected := range expectedValues {
			assertFileContains(t, path, expected)
		}
	}

	services, err := os.ReadFile(filepath.Join(chart, "services.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if count := strings.Count(string(services), "port: 41339"); count != 1 {
		t.Errorf("only the ClusterIP write service may expose port 41339, found %d service ports", count)
	}
}

func TestLoreConfigurationUsesDurableTwoTierStores(t *testing.T) {
	root := repositoryRoot(t)
	config := filepath.Join(root, "terraform/modules/lore-workload/charts/lore/templates/configmaps.yaml")

	for _, expected := range []string{
		`remote_url = "quics://lore-write.lore.svc.cluster.local:41340"`,
		`remote_url = "lores://lore-write.lore.svc.cluster.local:41337"`,
		`replication_mode = "read_write"`,
		`cert_chain = "/etc/lore/certs/ca.crt"`,
		`[plugins.aws.immutable_store]`,
		`[plugins.aws.mutable_store]`,
		`[plugins.aws.lock_store]`,
		`store_health_check = true`,
		`enable_otlp = false`,
		`format = "json"`,
	} {
		assertFileContains(t, config, expected)
	}

	contents, err := os.ReadFile(config)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"presigned_url_hmac_key", "[server.auth]", `mode = "local"\n\n    [lock_store]`} {
		if strings.Contains(string(contents), forbidden) {
			t.Errorf("Lore workload config must not contain %q", forbidden)
		}
	}
}

func TestLoreImageSupplyChainIsPinned(t *testing.T) {
	root := repositoryRoot(t)
	dockerfile := filepath.Join(root, "docker/lore/Dockerfile")
	workflow := filepath.Join(root, ".github/workflows/lore-image.yml")
	source := filepath.Join(root, "docker/lore/source.env")

	for _, expected := range []string{
		"2d86d1dda98bfc1575ac7a20a6ff8c7fbc760383",
		"LORE_VERSION=0.8.5",
		"LORE_IMAGE_VERSION=0.8.5-unrealops.1",
	} {
		assertFileContains(t, source, expected)
	}
	for _, expected := range []string{
		"FROM rust:slim-bookworm@sha256:",
		"FROM ubuntu:24.04@sha256:",
		"libprotobuf-dev",
		"cargo build --locked --profile release-lto --bin loreserver",
		"USER 65532:65532",
	} {
		assertFileContains(t, dockerfile, expected)
	}
	for _, expected := range []string{
		"runner: ubuntu-24.04-arm",
		"Provision fat-LTO linker swap",
		`sudo fallocate --length 16G "$SWAP_FILE"`,
		`sudo swapon "$SWAP_FILE"`,
		"push-by-digest=true",
		"docker buildx imagetools create",
		"provenance: mode=max",
		"sbom: true",
		"cosign sign --yes",
		`--tag "${IMAGE_URI}:${LORE_IMAGE_VERSION}"`,
	} {
		assertFileContains(t, workflow, expected)
	}

	workflowContents, err := os.ReadFile(workflow)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(workflowContents), ":latest") {
		t.Error("Lore image workflow must never publish latest")
	}
}

func TestLoreAddonsRejectMutableImageReferences(t *testing.T) {
	root := repositoryRoot(t)
	variables := filepath.Join(root, "terraform/examples/complete/addons/variables.tf")
	main := filepath.Join(root, "terraform/examples/complete/addons/main.tf")
	assertFileContains(t, variables, `@sha256:[0-9a-f]{64}`)
	assertFileContains(t, main, `!var.enable_lore || var.lore_image != null`)
}

func TestLoreAcceptanceImageParsing(t *testing.T) {
	digest := strings.Repeat("a", 64)
	image, ok := parseLoreECRImage("123456789012.dkr.ecr.us-west-2.amazonaws.com/stable/lore@sha256:" + digest)
	if !ok {
		t.Fatal("expected valid immutable private ECR image")
	}
	if image.accountID != "123456789012" || image.region != "us-west-2" ||
		image.repository != "stable/lore" || image.digest != "sha256:"+digest {
		t.Fatalf("unexpected parsed image: %#v", image)
	}

	for _, invalid := range []string{
		"public.ecr.aws/example/lore@sha256:" + digest,
		"123456789012.dkr.ecr.us-west-2.amazonaws.com/lore:latest",
		"123456789012.dkr.ecr.us-west-2.amazonaws.com/lore@sha256:short",
	} {
		if _, ok := parseLoreECRImage(invalid); ok {
			t.Errorf("expected image to be rejected: %s", invalid)
		}
	}
}

func TestLorePKIAndAcceptanceRemainExplicit(t *testing.T) {
	root := repositoryRoot(t)
	pki := filepath.Join(root, "scripts/lore-pki.sh")
	acceptance := filepath.Join(root, ".agents/skills/test-unrealops-infrastructure/scripts/run-acceptance.sh")
	complete := filepath.Join(root, "terraform/tests/complete_test.go")

	for _, expected := range []string{
		`LORE_CA_PASSIN`,
		`LORE_CA_PASSOUT`,
		`edge_client_cert`,
		`edge_client_key`,
		`use a different offline location`,
	} {
		assertFileContains(t, pki, expected)
	}
	pkiContents, err := os.ReadFile(pki)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(pkiContents), "ca_private_key") {
		t.Error("Lore runtime payload must never contain the CA private key")
	}

	for _, expected := range []string{
		`--lore-image`,
		`--lore-client`,
		`TEST_LORE_IMAGE`,
		`TEST_LORE_RUNTIME_SECRET_NAME`,
		`TEST_LORE_CA_FILE`,
		`TEST_LORE_CLIENT`,
		`cleanup_evidence.lore_kms_key`,
	} {
		assertFileContains(t, acceptance, expected)
	}
	for _, expected := range []string{
		`foundationVariables["enable_lore"] = true`,
		`foundationVariables["lore_deletion_protection"] = false`,
		`foundationVariables["lore_force_destroy"] = true`,
		`addonsVariables["enable_lore"] = true`,
	} {
		assertFileContains(t, complete, expected)
	}
	liveLore := filepath.Join(root, "terraform/tests/lore_acceptance_test.go")
	for _, expected := range []string{
		`testLoreWriteTierRecovery`,
		`restore-table-to-point-in-time`,
		`testLoreS3VersionRecovery`,
		`assertDefaultServiceAccountHasNoAWSCredentials`,
	} {
		assertFileContains(t, liveLore, expected)
	}
}
