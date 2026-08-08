package tests

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/eks"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestCompleteStack(t *testing.T) {
	region := requireAcc(t)
	lore := loadLoreAcceptanceConfig(t, region)
	secretARN := requiredEnv(t, "TEST_COMPLETE_OPENVPN_RUNTIME_SECRET_ARN")
	profile := requiredEnv(t, "TEST_COMPLETE_OPENVPN_PROFILE")
	profileContents, err := os.ReadFile(profile)
	require.NoError(t, err, "read complete-stack OpenVPN profile before provisioning")
	profile = filepath.Join(t.TempDir(), "complete-client.ovpn")
	require.NoError(t, os.WriteFile(profile, profileContents, 0o600))
	requiredCommands := []string{"aws", "kubectl"}
	if os.Getenv("TEST_OPENVPN_CONNECT_CLI") == "" {
		requiredCommands = append(requiredCommands, "openvpn")
	}
	for _, command := range requiredCommands {
		if _, err := exec.LookPath(command); err != nil {
			t.Fatalf("%s is required: %v", command, err)
		}
	}

	root := repositoryRoot(t)
	name := testName("unrealops-e2e")
	foundationDir := filepath.Join(root, "terraform/examples/complete/foundation")
	foundationVariables := map[string]interface{}{
		"aws_region":                 region,
		"name":                       name,
		"openvpn_runtime_secret_arn": secretARN,
	}
	if lore != nil {
		foundationVariables["enable_lore"] = true
		foundationVariables["system_node_instance_types"] = []string{"m6i.large"}
		foundationVariables["system_node_group_size"] = map[string]interface{}{
			"min": 2, "desired": 2, "max": 3,
		}
		foundationVariables["lore_runtime_secret_name"] = lore.runtimeSecretName
		foundationVariables["lore_deletion_protection"] = false
		foundationVariables["lore_force_destroy"] = true
	}
	foundation := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    foundationDir,
		TerraformBinary: terraformBinary(),
		NoColor:         true,
		Vars:            foundationVariables,
	})
	defer terraform.Destroy(t, foundation)
	terraform.InitAndApply(t, foundation)
	t.Logf("UNREALOPS_ACCEPTANCE_KMS_KEY_ARN=%s", terraform.Output(t, foundation, "cluster_kms_key_arn"))
	if lore != nil {
		t.Logf("UNREALOPS_ACCEPTANCE_LORE_KMS_KEY_ARN=%s", terraform.Output(t, foundation, "lore_kms_key_arn"))
	}

	expectedClusterVersion := terraform.Output(t, foundation, "cluster_version")
	require.Regexp(t, `^[0-9]+\.[0-9]+$`, expectedClusterVersion)
	expectedAMIRelease := terraform.Output(t, foundation, "system_node_ami_release_version")
	require.Regexp(t, `^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}$`, expectedAMIRelease)
	expectedAddonVersions := terraform.OutputMap(t, foundation, "cluster_addon_versions")
	require.Len(t, expectedAddonVersions, 6)
	for _, version := range expectedAddonVersions {
		require.Regexp(t, `^v[0-9]+\.[0-9]+\.[0-9]+-eksbuild\.[0-9]+$`, version)
	}
	deployedAddonVersions := make(map[string]string, len(expectedAddonVersions))
	for addon, version := range expectedAddonVersions {
		deployedAddonVersions[addon] = version
	}
	if lore == nil {
		delete(deployedAddonVersions, "cloudwatch_observability")
	}
	assertEKSFoundation(
		t,
		region,
		terraform.Output(t, foundation, "cluster_name"),
		expectedClusterVersion,
		expectedAMIRelease,
		deployedAddonVersions,
	)

	clusterEndpoint := terraform.Output(t, foundation, "cluster_endpoint")
	parsedEndpoint, err := url.Parse(clusterEndpoint)
	require.NoError(t, err)
	require.NotEmpty(t, parsedEndpoint.Hostname())
	assertPrivateEndpoint(t, parsedEndpoint.Hostname())

	privateAPIAddress := net.JoinHostPort(parsedEndpoint.Hostname(), "443")
	assertTCPUnreachable(t, privateAPIAddress)
	if lore != nil {
		assertDNSUnreachable(t, terraform.Output(t, foundation, "lore_endpoint_hostname"))
		assertLoreFoundation(t, region, name, foundation)
	}
	stopTunnel := startOpenVPNTunnel(t, profile, terraform.Output(t, foundation, "openvpn_endpoint"), 3*time.Minute)
	defer stopTunnel()
	waitForTCP(t, privateAPIAddress, 3*time.Minute)

	addonsDir := filepath.Join(root, "terraform/examples/complete/addons")
	addonsVariables := map[string]interface{}{
		"aws_region":   region,
		"cluster_name": name,
	}
	if lore != nil {
		addonsVariables["enable_lore"] = true
		addonsVariables["lore_image"] = lore.image
		addonsVariables["lore_runtime_secret_name"] = lore.runtimeSecretName
		addonsVariables["lore_edge_replicas"] = 3
		addonsVariables["lore_write_replicas"] = 2
	}
	addons := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    addonsDir,
		TerraformBinary: terraformBinary(),
		NoColor:         true,
		Vars:            addonsVariables,
	})
	defer terraform.Destroy(t, addons)
	terraform.InitAndApply(t, addons)
	require.Regexp(t, `^[0-9]+\.[0-9]+\.[0-9]+$`, terraform.Output(t, addons, "karpenter_version"))

	kubeconfig := filepath.Join(t.TempDir(), "kubeconfig")
	runCommand(t, nil, "aws", "eks", "update-kubeconfig", "--region", region, "--name", terraform.Output(t, foundation, "cluster_name"), "--kubeconfig", kubeconfig)
	testKarpenterProvisioningAndConsolidation(t, kubeconfig)
	if lore != nil {
		testLoreAcceptance(t, region, name, kubeconfig, lore, foundation, addons)
	}
}

func assertEKSFoundation(t *testing.T, region, clusterName, expectedClusterVersion, expectedAMIRelease string, expectedAddons map[string]string) {
	t.Helper()
	sess, err := session.NewSession(&aws.Config{Region: aws.String(region)})
	require.NoError(t, err)
	client := eks.New(sess)

	clusterResult, err := client.DescribeClusterWithContext(context.Background(), &eks.DescribeClusterInput{Name: aws.String(clusterName)})
	require.NoError(t, err)
	require.Equal(t, expectedClusterVersion, aws.StringValue(clusterResult.Cluster.Version))
	require.True(t, aws.BoolValue(clusterResult.Cluster.ResourcesVpcConfig.EndpointPrivateAccess))
	require.False(t, aws.BoolValue(clusterResult.Cluster.ResourcesVpcConfig.EndpointPublicAccess))
	require.NotEmpty(t, clusterResult.Cluster.EncryptionConfig)
	require.NotEmpty(t, clusterResult.Cluster.Logging.ClusterLogging)

	addonNames := map[string]string{
		"vpc_cni":                  "vpc-cni",
		"coredns":                  "coredns",
		"kube_proxy":               "kube-proxy",
		"ebs_csi_driver":           "aws-ebs-csi-driver",
		"pod_identity_agent":       "eks-pod-identity-agent",
		"cloudwatch_observability": "amazon-cloudwatch-observability",
	}
	for outputName, addonName := range addonNames {
		expectedVersion, enabled := expectedAddons[outputName]
		if !enabled {
			continue
		}
		result, err := client.DescribeAddonWithContext(context.Background(), &eks.DescribeAddonInput{
			AddonName:   aws.String(addonName),
			ClusterName: aws.String(clusterName),
		})
		require.NoError(t, err)
		require.Equal(t, eks.AddonStatusActive, aws.StringValue(result.Addon.Status))
		require.Equal(t, expectedVersion, aws.StringValue(result.Addon.AddonVersion))
	}

	nodegroups, err := client.ListNodegroupsWithContext(context.Background(), &eks.ListNodegroupsInput{ClusterName: aws.String(clusterName)})
	require.NoError(t, err)
	require.Len(t, nodegroups.Nodegroups, 1)
	nodegroup, err := client.DescribeNodegroupWithContext(context.Background(), &eks.DescribeNodegroupInput{
		ClusterName:   aws.String(clusterName),
		NodegroupName: nodegroups.Nodegroups[0],
	})
	require.NoError(t, err)
	require.Equal(t, expectedClusterVersion, aws.StringValue(nodegroup.Nodegroup.Version))
	require.Equal(t, expectedAMIRelease, aws.StringValue(nodegroup.Nodegroup.ReleaseVersion))
	require.Equal(t, eks.CapacityTypesOnDemand, aws.StringValue(nodegroup.Nodegroup.CapacityType))
}

func assertPrivateEndpoint(t *testing.T, hostname string) {
	t.Helper()
	addresses, err := net.LookupIP(hostname)
	require.NoError(t, err)
	require.NotEmpty(t, addresses)
	for _, address := range addresses {
		require.True(t, address.IsPrivate(), "private EKS endpoint resolved to public address %s", address)
	}
}

func startOpenVPNTunnel(t *testing.T, profile, endpoint string, timeout time.Duration) func() {
	t.Helper()
	if connectCLI := os.Getenv("TEST_OPENVPN_CONNECT_CLI"); connectCLI != "" {
		return startOpenVPNConnectTunnel(t, connectCLI, profile, endpoint)
	}

	profile = profileWithoutRemote(t, profile)
	logFile := filepath.Join(t.TempDir(), "openvpn-tunnel.log")
	command := exec.Command("openvpn", "--config", profile, "--remote", endpoint, "1194", "--auth-nocache", "--verb", "3", "--log", logFile)
	process, err := startManagedProcess(command)
	require.NoError(t, err)
	stop := registerProcessCleanup(t, process, "persistent OpenVPN tunnel")

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		contents, _ := os.ReadFile(logFile)
		if strings.Contains(string(contents), "Initialization Sequence Completed") {
			return stop
		}

		select {
		case <-process.Done():
			contents, _ = os.ReadFile(logFile)
			t.Fatalf("OpenVPN exited before connecting (%v): %s", process.WaitErr(), tail(string(contents), 30))
		case <-timer.C:
			stop()
			contents, _ = os.ReadFile(logFile)
			t.Fatalf("OpenVPN did not connect within %s: %s", timeout, tail(string(contents), 30))
		case <-ticker.C:
		}
	}
}

func waitForTCP(t *testing.T, address string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("tcp", address, 5*time.Second)
		if err == nil {
			_ = connection.Close()
			return
		}
		time.Sleep(5 * time.Second)
	}
	t.Fatalf("%s was not reachable within %s", address, timeout)
}

func assertTCPUnreachable(t *testing.T, address string) {
	t.Helper()
	connection, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		return
	}
	_ = connection.Close()
	t.Fatalf("%s was reachable before the acceptance OpenVPN tunnel started", address)
}

func assertDNSUnreachable(t *testing.T, hostname string) {
	t.Helper()
	addresses, err := net.LookupHost(hostname)
	if err != nil {
		return
	}
	t.Fatalf("%s unexpectedly resolved before the OpenVPN tunnel and private Lore alias existed: %v", hostname, addresses)
}

func testKarpenterProvisioningAndConsolidation(t *testing.T, kubeconfig string) {
	t.Helper()
	manifest := map[string]interface{}{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]interface{}{
			"name":      "karpenter-acceptance",
			"namespace": "default",
		},
		"spec": map[string]interface{}{
			"replicas": 1,
			"selector": map[string]interface{}{"matchLabels": map[string]interface{}{"app": "karpenter-acceptance"}},
			"template": map[string]interface{}{
				"metadata": map[string]interface{}{"labels": map[string]interface{}{"app": "karpenter-acceptance"}},
				"spec": map[string]interface{}{
					"nodeSelector": map[string]interface{}{
						"unrealops.io/capacity-provider": "karpenter",
						"karpenter.sh/capacity-type":     "on-demand",
					},
					"containers": []map[string]interface{}{{
						"name":  "pause",
						"image": "registry.k8s.io/pause:3.10",
						"resources": map[string]interface{}{"requests": map[string]interface{}{
							"cpu": "1", "memory": "1Gi",
						}},
					}},
				},
			},
		},
	}
	encoded, err := json.Marshal(manifest)
	require.NoError(t, err)
	defer cleanupKarpenterWorkload(t, kubeconfig, 10*time.Minute)
	runCommand(t, encoded, "kubectl", "--kubeconfig", kubeconfig, "apply", "-f", "-")
	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "rollout", "status", "deployment/karpenter-acceptance", "--timeout=20m")

	nodes := runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "get", "nodes", "-l", "unrealops.io/capacity-provider=karpenter", "-o", "name")
	require.NotEmpty(t, strings.TrimSpace(nodes), "Karpenter did not provision a labeled workload node")

	runCommand(t, nil, "kubectl", "--kubeconfig", kubeconfig, "delete", "deployment", "karpenter-acceptance", "--wait=true")
	require.Eventually(t, func() bool {
		nodes, nodeClaims, err := karpenterWorkloadResources(kubeconfig)
		return err == nil && nodes == "" && nodeClaims == ""
	}, 15*time.Minute, 30*time.Second, "Karpenter did not consolidate the empty workload node")
}

func cleanupKarpenterWorkload(t *testing.T, kubeconfig string, timeout time.Duration) {
	t.Helper()
	selector := "unrealops.io/capacity-provider=karpenter"
	cleanupCommands := [][]string{
		{"--kubeconfig", kubeconfig, "delete", "deployment", "karpenter-acceptance", "--ignore-not-found=true", "--wait=true"},
		{"--kubeconfig", kubeconfig, "delete", "nodeclaims.karpenter.sh", "-l", selector, "--ignore-not-found=true", "--wait=false"},
	}
	for _, args := range cleanupCommands {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		output, err := runCommandE(ctx, nil, "kubectl", args...)
		cancel()
		if err != nil {
			t.Logf("best-effort Karpenter cleanup command failed: kubectl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(output))
		}
	}

	deadline := time.Now().Add(timeout)
	var lastNodes, lastNodeClaims string
	var lastErr error
	for time.Now().Before(deadline) {
		lastNodes, lastNodeClaims, lastErr = karpenterWorkloadResources(kubeconfig)
		if lastErr == nil && lastNodes == "" && lastNodeClaims == "" {
			return
		}
		time.Sleep(15 * time.Second)
	}
	t.Errorf(
		"Karpenter cleanup did not finish within %s: nodes=%q nodeclaims=%q last_error=%v",
		timeout,
		lastNodes,
		lastNodeClaims,
		lastErr,
	)
}

func karpenterWorkloadResources(kubeconfig string) (string, string, error) {
	selector := "unrealops.io/capacity-provider=karpenter"
	resources := []string{"nodes", "nodeclaims.karpenter.sh"}
	results := make([]string, len(resources))
	for index, resource := range resources {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		output, err := runCommandE(ctx, nil, "kubectl", "--kubeconfig", kubeconfig, "get", resource, "-l", selector, "-o", "name")
		cancel()
		if err != nil {
			return "", "", fmt.Errorf("get %s: %w: %s", resource, err, strings.TrimSpace(output))
		}
		results[index] = strings.TrimSpace(output)
	}
	return results[0], results[1], nil
}

func runCommand(t *testing.T, stdin []byte, name string, args ...string) string {
	t.Helper()
	output, err := runCommandE(context.Background(), stdin, name, args...)
	require.NoError(t, err, "%s %s: %s", name, strings.Join(args, " "), output)
	return output
}

func runCommandE(ctx context.Context, stdin []byte, name string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, name, args...)
	if stdin != nil {
		command.Stdin = strings.NewReader(string(stdin))
	}
	output, err := command.CombinedOutput()
	return fmt.Sprintf("%s", output), err
}
