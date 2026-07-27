package tests

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/autoscaling"
	"github.com/aws/aws-sdk-go/service/ec2"
	"github.com/aws/aws-sdk-go/service/ssm"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestOpenVPNFailoverAndRevocation(t *testing.T) {
	region := requireAcc(t)
	secretARN := requiredEnv(t, "TEST_OPENVPN_RUNTIME_SECRET_ARN")
	profile := requiredEnv(t, "TEST_OPENVPN_PROFILE")
	controlProfile := requiredEnv(t, "TEST_OPENVPN_CONTROL_PROFILE")
	pkiEnvironment := requiredEnv(t, "TEST_OPENVPN_PKI_ENV")
	clientName := requiredEnv(t, "TEST_OPENVPN_CLIENT_NAME")
	if _, err := exec.LookPath("openvpn"); err != nil {
		t.Fatalf("openvpn client is required: %v", err)
	}
	if os.Getenv("EASYRSA_PASSIN") == "" {
		t.Fatal("EASYRSA_PASSIN is required so the test can publish a revoked-client CRL")
	}

	name := testName("unrealops-vpn")
	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    filepath.Join(repositoryRoot(t), "terraform/tests/fixtures/openvpn"),
		TerraformBinary: terraformBinary(),
		NoColor:         true,
		Vars: map[string]interface{}{
			"name":               name,
			"region":             region,
			"runtime_secret_arn": secretARN,
		},
	})

	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	endpoint := terraform.Output(t, opts, "endpoint")
	eip := terraform.Output(t, opts, "eip")
	asgName := terraform.Output(t, opts, "autoscaling_group_name")
	require.Equal(t, endpoint, eip)
	initialHandshake := openVPNHandshake(t, profile, endpoint, 90*time.Second)
	require.True(t, initialHandshake.connected, "initial OpenVPN handshake failed: %s", tail(initialHandshake.log, 20))

	sess, err := session.NewSession(&aws.Config{Region: aws.String(region)})
	require.NoError(t, err)
	oldInstanceID := currentASGInstance(t, autoscaling.New(sess), asgName)
	assertOpenVPNInstanceControls(t, sess, oldInstanceID, terraform.Output(t, opts, "security_group_id"))

	_, err = autoscaling.New(sess).TerminateInstanceInAutoScalingGroupWithContext(context.Background(), &autoscaling.TerminateInstanceInAutoScalingGroupInput{
		InstanceId:                     aws.String(oldInstanceID),
		ShouldDecrementDesiredCapacity: aws.Bool(false),
	})
	require.NoError(t, err)

	newInstanceID := waitForASGReplacement(t, autoscaling.New(sess), asgName, oldInstanceID, 10*time.Minute)
	waitForEIPAssociation(t, ec2.New(sess), eip, newInstanceID, 2*time.Minute)
	recoveredHandshake := openVPNHandshake(t, profile, endpoint, 2*time.Minute)
	require.True(t, recoveredHandshake.connected, "OpenVPN did not recover after ASG replacement: %s", tail(recoveredHandshake.log, 20))

	revoke := exec.Command(
		filepath.Join(repositoryRoot(t), "scripts/openvpn-pki.sh"),
		"revoke",
		"--environment", pkiEnvironment,
		"--name", clientName,
		"--secret-id", secretARN,
		"--region", region,
	)
	revoke.Env = os.Environ()
	output, err := revoke.CombinedOutput()
	require.NoError(t, err, "revoke client certificate: %s", string(output))

	// The appliance polls Secrets Manager every five minutes and reloads the CRL.
	time.Sleep(6 * time.Minute)
	revokedHandshake := openVPNHandshake(t, profile, endpoint, 75*time.Second)
	// Certificate verification is performed by the server. OpenVPN intentionally
	// does not disclose that verification reason to the rejected peer, so clients
	// commonly report a TLS negotiation timeout rather than "certificate revoked".
	require.False(t, revokedHandshake.connected, "revoked OpenVPN certificate was accepted")

	controlHandshake := openVPNHandshake(t, controlProfile, endpoint, 90*time.Second)
	require.True(t, controlHandshake.connected, "non-revoked control client could not connect after CRL reload: %s", tail(controlHandshake.log, 20))
}

func currentASGInstance(t *testing.T, client *autoscaling.AutoScaling, asgName string) string {
	t.Helper()
	result, err := client.DescribeAutoScalingGroupsWithContext(context.Background(), &autoscaling.DescribeAutoScalingGroupsInput{
		AutoScalingGroupNames: []*string{aws.String(asgName)},
	})
	require.NoError(t, err)
	require.Len(t, result.AutoScalingGroups, 1)
	require.Len(t, result.AutoScalingGroups[0].Instances, 1)
	return aws.StringValue(result.AutoScalingGroups[0].Instances[0].InstanceId)
}

func waitForASGReplacement(t *testing.T, client *autoscaling.AutoScaling, asgName, oldInstanceID string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		result, err := client.DescribeAutoScalingGroupsWithContext(context.Background(), &autoscaling.DescribeAutoScalingGroupsInput{
			AutoScalingGroupNames: []*string{aws.String(asgName)},
		})
		if err == nil && len(result.AutoScalingGroups) == 1 {
			for _, instance := range result.AutoScalingGroups[0].Instances {
				id := aws.StringValue(instance.InstanceId)
				if id != oldInstanceID && aws.StringValue(instance.LifecycleState) == autoscaling.LifecycleStateInService {
					return id
				}
			}
		}
		time.Sleep(15 * time.Second)
	}
	t.Fatalf("OpenVPN ASG did not replace %s within %s", oldInstanceID, timeout)
	return ""
}

func waitForEIPAssociation(t *testing.T, client *ec2.EC2, publicIP, instanceID string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		result, err := client.DescribeAddressesWithContext(context.Background(), &ec2.DescribeAddressesInput{
			PublicIps: []*string{aws.String(publicIP)},
		})
		if err == nil && len(result.Addresses) == 1 && aws.StringValue(result.Addresses[0].InstanceId) == instanceID {
			return
		}
		time.Sleep(10 * time.Second)
	}
	t.Fatalf("EIP %s was not associated with replacement %s within %s", publicIP, instanceID, timeout)
}

func assertOpenVPNInstanceControls(t *testing.T, sess *session.Session, instanceID, securityGroupID string) {
	t.Helper()
	ec2Client := ec2.New(sess)
	instances, err := ec2Client.DescribeInstancesWithContext(context.Background(), &ec2.DescribeInstancesInput{
		InstanceIds: []*string{aws.String(instanceID)},
	})
	require.NoError(t, err)
	require.Len(t, instances.Reservations, 1)
	require.Len(t, instances.Reservations[0].Instances, 1)
	instance := instances.Reservations[0].Instances[0]
	require.Equal(t, ec2.HttpTokensStateRequired, aws.StringValue(instance.MetadataOptions.HttpTokens))
	require.False(t, aws.BoolValue(instance.SourceDestCheck))

	volumes, err := ec2Client.DescribeVolumesWithContext(context.Background(), &ec2.DescribeVolumesInput{
		Filters: []*ec2.Filter{{Name: aws.String("attachment.instance-id"), Values: []*string{aws.String(instanceID)}}},
	})
	require.NoError(t, err)
	require.NotEmpty(t, volumes.Volumes)
	for _, volume := range volumes.Volumes {
		require.True(t, aws.BoolValue(volume.Encrypted), "OpenVPN root volume must be encrypted")
	}

	groups, err := ec2Client.DescribeSecurityGroupsWithContext(context.Background(), &ec2.DescribeSecurityGroupsInput{
		GroupIds: []*string{aws.String(securityGroupID)},
	})
	require.NoError(t, err)
	require.Len(t, groups.SecurityGroups, 1)
	for _, permission := range groups.SecurityGroups[0].IpPermissions {
		if permission.FromPort != nil && permission.ToPort != nil {
			require.False(t, *permission.FromPort <= 22 && *permission.ToPort >= 22, "OpenVPN security group exposes SSH")
		}
	}

	ssmClient := ssm.New(sess)
	require.Eventually(t, func() bool {
		result, err := ssmClient.DescribeInstanceInformationWithContext(context.Background(), &ssm.DescribeInstanceInformationInput{
			Filters: []*ssm.InstanceInformationStringFilter{{Key: aws.String("InstanceIds"), Values: []*string{aws.String(instanceID)}}},
		})
		return err == nil && len(result.InstanceInformationList) == 1 && aws.StringValue(result.InstanceInformationList[0].PingStatus) == ssm.PingStatusOnline
	}, 5*time.Minute, 15*time.Second, "OpenVPN instance never registered with SSM")
}

type openVPNHandshakeResult struct {
	connected bool
	log       string
}

func openVPNHandshake(t *testing.T, profile, endpoint string, timeout time.Duration) openVPNHandshakeResult {
	t.Helper()
	profile = profileWithoutRemote(t, profile)
	logFile, err := os.CreateTemp(t.TempDir(), "openvpn-*.log")
	require.NoError(t, err)
	logPath := logFile.Name()
	require.NoError(t, logFile.Close())

	command := exec.Command("openvpn",
		"--config", profile,
		"--remote", endpoint, "1194",
		"--dev", "null",
		"--ifconfig-noexec",
		"--route-noexec",
		"--script-security", "0",
		"--pull-filter", "ignore", "redirect-gateway",
		"--pull-filter", "ignore", "route",
		"--pull-filter", "ignore", "dhcp-option",
		"--connect-retry-max", "1",
		"--connect-timeout", "20",
		"--auth-nocache",
		"--verb", "4",
		"--log", logPath,
	)
	process, err := startManagedProcess(command)
	if err != nil {
		return openVPNHandshakeResult{log: fmt.Sprintf("start openvpn: %v", err)}
	}
	stop := registerProcessCleanup(t, process, "OpenVPN handshake")

	connected := false
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	finished := false
	for !finished {
		contents, _ := os.ReadFile(logPath)
		logOutput := string(contents)
		lowerLogOutput := strings.ToLower(logOutput)
		if strings.Contains(logOutput, "Initialization Sequence Completed") {
			connected = true
			finished = true
			continue
		}
		if strings.Contains(lowerLogOutput, "certificate revoked") || strings.Contains(logOutput, "AUTH_FAILED") {
			finished = true
			continue
		}

		select {
		case <-process.Done():
			finished = true
		case <-timer.C:
			finished = true
		case <-ticker.C:
		}
	}
	stop()
	contents, _ := os.ReadFile(logPath)
	return openVPNHandshakeResult{connected: connected, log: string(contents)}
}

func profileWithoutRemote(t *testing.T, profile string) string {
	t.Helper()
	contents, err := os.ReadFile(profile)
	require.NoError(t, err)

	lines := strings.Split(string(contents), "\n")
	filtered := lines[:0]
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == "remote" {
			continue
		}
		filtered = append(filtered, line)
	}

	path := filepath.Join(t.TempDir(), "client-without-remote.ovpn")
	require.NoError(t, os.WriteFile(path, []byte(strings.Join(filtered, "\n")), 0o600))
	return path
}

func tail(value string, lines int) string {
	parts := strings.Split(value, "\n")
	if len(parts) <= lines {
		return value
	}
	return fmt.Sprintf("...\n%s", strings.Join(parts[len(parts)-lines:], "\n"))
}
