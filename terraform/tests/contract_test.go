package tests

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

func TestSupportedModuleLayout(t *testing.T) {
	root := repositoryRoot(t)
	for _, relativePath := range []string{
		"terraform/modules/network",
		"terraform/modules/openvpn",
		"terraform/modules/eks",
		"terraform/modules/karpenter-infra",
		"terraform/modules/cluster-addons-infra",
		"terraform/modules/cluster-addons",
		"terraform/modules/lore-infra",
		"terraform/modules/lore-workload",
		"terraform/examples/complete/foundation",
		"terraform/examples/complete/addons",
	} {
		info, err := os.Stat(filepath.Join(root, relativePath))
		if err != nil {
			t.Errorf("required path %s: %v", relativePath, err)
			continue
		}
		if !info.IsDir() {
			t.Errorf("required path %s is not a directory", relativePath)
		}
	}
}

func TestLoreModulesDoNotConfigureProvidersOrBackends(t *testing.T) {
	root := repositoryRoot(t)
	for _, relativePath := range []string{
		"terraform/modules/cluster-addons-infra",
		"terraform/modules/lore-infra",
		"terraform/modules/lore-workload",
	} {
		matches, err := filepath.Glob(filepath.Join(root, relativePath, "*.tf"))
		if err != nil {
			t.Fatalf("glob %s: %v", relativePath, err)
		}
		for _, path := range matches {
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			for _, forbidden := range []string{`provider "`, `backend "`} {
				if strings.Contains(string(contents), forbidden) {
					t.Errorf("%s contains forbidden module configuration %q", path, forbidden)
				}
			}
		}
	}
}

func TestLegacyEKSModuleTreesAreAbsent(t *testing.T) {
	root := repositoryRoot(t)
	for _, relativePath := range []string{
		"terraform/modules/eks/cluster",
		"terraform/modules/eks/cluster-config",
		"terraform/modules/eks/node-group",
	} {
		_, err := os.Stat(filepath.Join(root, relativePath))
		if err == nil {
			t.Errorf("legacy EKS module tree %s must be removed", relativePath)
			continue
		}
		if !os.IsNotExist(err) {
			t.Errorf("inspect legacy EKS module tree %s: %v", relativePath, err)
		}
	}
}

func TestSupportedEKSWiring(t *testing.T) {
	root := repositoryRoot(t)

	foundationBody := parseHCLBody(t, filepath.Join(root, "terraform/examples/complete/foundation/main.tf"))
	foundationEKS := findHCLBlock(t, foundationBody, "module", "eks")
	if source := hclAttributeString(t, foundationEKS.Body.Attributes["source"], "foundation EKS module source"); source != "../../../modules/eks" {
		t.Errorf("foundation EKS module source is %q, want %q", source, "../../../modules/eks")
	}

	wrapperBody := parseHCLBody(t, filepath.Join(root, "terraform/modules/eks/main.tf"))
	upstreamEKS := findHCLBlock(t, wrapperBody, "module", "eks")
	if source := hclAttributeString(t, upstreamEKS.Body.Attributes["source"], "upstream EKS module source"); source != "terraform-aws-modules/eks/aws" {
		t.Errorf("upstream EKS module source is %q, want %q", source, "terraform-aws-modules/eks/aws")
	}
}

func TestEKSSuppressesDuplicateClusterCreatorAccessEntry(t *testing.T) {
	root := repositoryRoot(t)
	eks := filepath.Join(root, "terraform/modules/eks/main.tf")

	for _, expected := range []string{
		`data "aws_iam_session_context" "current"`,
		`caller_principal_arn     = data.aws_iam_session_context.current.issuer_arn`,
		`entry.principal_arn == local.caller_principal_arn`,
		`var.enable_cluster_creator_admin_permissions && !local.caller_has_access_entry`,
		`enable_cluster_creator_admin_permissions = local.enable_cluster_creator_admin_permissions`,
	} {
		assertFileContains(t, eks, expected)
	}
}

func TestAddonsDiscoversFoundationFromAWS(t *testing.T) {
	root := repositoryRoot(t)
	addonsMain := filepath.Join(root, "terraform/examples/complete/addons/main.tf")
	contents, err := os.ReadFile(addonsMain)
	if err != nil {
		t.Fatalf("read addons main.tf: %v", err)
	}
	if strings.Contains(string(contents), "terraform_remote_state") {
		t.Error("addons root must not use terraform_remote_state; discover foundation from AWS data sources")
	}

	addonsBody := parseHCLBody(t, addonsMain)
	for _, expected := range []struct {
		dataType string
		label    string
	}{
		{"aws_eks_cluster", "this"},
		{"aws_iam_role", "karpenter_node"},
		{"aws_sqs_queue", "karpenter_interruption"},
	} {
		_ = findHCLBlock(t, addonsBody, "data", expected.dataType, expected.label)
	}

	karpenterInfra := filepath.Join(root, "terraform/modules/karpenter-infra/main.tf")
	assertFileContains(t, karpenterInfra, `node_role_name       = "${var.cluster_name}-karpenter-node"`)
	assertFileContains(t, karpenterInfra, `queue_name                = "Karpenter-${var.cluster_name}"`)
	assertFileContains(t, addonsMain, `node_iam_role_name      = "${var.cluster_name}-karpenter-node"`)
	assertFileContains(t, addonsMain, `interruption_queue_name = "Karpenter-${var.cluster_name}"`)
}

func TestKarpenterManifestsDoNotSetControllerOwnedTags(t *testing.T) {
	root := repositoryRoot(t)
	for _, relativePath := range []string{
		"terraform/modules/cluster-addons/main.tf",
		"terraform/modules/cluster-addons/charts/karpenter-resources/templates/ec2nodeclass.yaml",
	} {
		contents, err := os.ReadFile(filepath.Join(root, relativePath))
		if err != nil {
			t.Fatalf("read %s: %v", relativePath, err)
		}
		for _, key := range []string{
			"eks:eks-cluster-name",
			"kubernetes.io/cluster",
			"karpenter.sh/nodepool",
			"karpenter.sh/nodeclaim",
			"karpenter.k8s.aws/ec2nodeclass",
		} {
			if strings.Contains(string(contents), key) {
				t.Errorf("%s configures Karpenter-owned tag %q", relativePath, key)
			}
		}
	}
}

func TestBackendHelperAcceptsOnlyEmptyLineagelessState(t *testing.T) {
	root := repositoryRoot(t)
	helper := filepath.Join(root, ".agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh")

	for _, expected := range []string{
		`[[ "$allow_new_state" == "true" ]]`,
		`.serial == 0`,
		`(.outputs | type == "object" and length == 0)`,
		`[.resources[]? | select(.mode == "managed")] | length) == 0`,
		`state lacks a lineage but is not an empty new state`,
	} {
		assertFileContains(t, helper, expected)
	}
}

func TestBackendHelperAllowsOnlyLoreWorkloadAWSResourcesInAddonsState(t *testing.T) {
	root := repositoryRoot(t)
	helper := filepath.Join(root, ".agents/skills/deploy-unrealops-infrastructure/scripts/init-backend.sh")

	for _, expected := range []string{
		`startswith("module.lore_workload")`,
		`"aws_cloudwatch_dashboard"`,
		`"aws_cloudwatch_metric_alarm"`,
		`"aws_route53_record"`,
		`add-ons state contains AWS resources outside the Lore workload allowlist`,
	} {
		assertFileContains(t, helper, expected)
	}
}

func TestCleanupAuditSupportsLoreKMSAndRuntimeSecret(t *testing.T) {
	root := repositoryRoot(t)
	audit := filepath.Join(root, ".agents/skills/deploy-unrealops-infrastructure/scripts/audit-cleanup.sh")

	for _, expected := range []string{
		`kms_key_ids+=("$2")`,
		`runtime_secret_ids+=("$2")`,
		`array_contains "$arn" "${kms_key_ids[@]}"`,
		`"alias/$environment-lore"`,
		`for kms_key_id in "${kms_key_ids[@]}"`,
		`for runtime_secret_id in "${runtime_secret_ids[@]}"`,
	} {
		assertFileContains(t, audit, expected)
	}
}

func parseHCLBody(t *testing.T, path string) *hclsyntax.Body {
	t.Helper()
	parser := hclparse.NewParser()
	file, diagnostics := parser.ParseHCLFile(path)
	if diagnostics.HasErrors() {
		t.Fatalf("parse %s: %s", path, diagnostics.Error())
	}
	body, ok := file.Body.(*hclsyntax.Body)
	if !ok {
		t.Fatalf("parse %s: body is not native HCL syntax", path)
	}
	return body
}

func findHCLBlock(t *testing.T, body *hclsyntax.Body, blockType string, labels ...string) *hclsyntax.Block {
	t.Helper()
	var match *hclsyntax.Block
	for _, block := range body.Blocks {
		if block.Type != blockType || !reflect.DeepEqual(block.Labels, labels) {
			continue
		}
		if match != nil {
			t.Fatalf("found more than one %s block with labels %v", blockType, labels)
		}
		match = block
	}
	if match == nil {
		t.Fatalf("missing %s block with labels %v", blockType, labels)
	}
	return match
}

func hclAttributeString(t *testing.T, attribute *hclsyntax.Attribute, description string) string {
	t.Helper()
	if attribute == nil {
		t.Fatalf("missing %s", description)
	}
	value, diagnostics := attribute.Expr.Value(nil)
	if diagnostics.HasErrors() {
		t.Fatalf("evaluate %s: %s", description, diagnostics.Error())
	}
	if !value.IsKnown() || value.IsNull() || value.Type() != cty.String {
		t.Fatalf("%s must be a literal string, got %s", description, value.Type().FriendlyName())
	}
	return value.AsString()
}

func assertFileContains(t *testing.T, path, value string) {
	t.Helper()
	if value == "" {
		t.Fatal("expected file content must not be empty")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if !strings.Contains(string(contents), value) {
		t.Errorf("%s does not contain expected content %q", path, value)
	}
}
