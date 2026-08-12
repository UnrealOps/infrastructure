package tests

import (
	"context"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/eks"
	"github.com/aws/aws-sdk-go/service/iam"
	"github.com/aws/aws-sdk-go/service/sts"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestAccountBootstrap(t *testing.T) {
	region := requireAcc(t)
	name := testName("unrealops-bootstrap")
	clusterName := testName("unrealops-cluster")
	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    filepath.Join(repositoryRoot(t), "terraform/tests/fixtures/account-bootstrap"),
		TerraformBinary: terraformBinary(),
		NoColor:         true,
		Vars: map[string]interface{}{
			"name":         name,
			"region":       region,
			"cluster_name": clusterName,
		},
	})

	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	roleARN := terraform.Output(t, opts, "role_arn")
	roleName := terraform.Output(t, opts, "role_name")
	trustedPrincipalARN := terraform.Output(t, opts, "trusted_principal_arn")
	clusterARN := terraform.Output(t, opts, "cluster_arn")

	sess, err := session.NewSession(&aws.Config{Region: aws.String(region)})
	require.NoError(t, err)

	roleResult, err := iam.New(sess).GetRoleWithContext(context.Background(), &iam.GetRoleInput{
		RoleName: aws.String(roleName),
	})
	require.NoError(t, err)
	require.Equal(t, "/unrealops/", aws.StringValue(roleResult.Role.Path))
	require.EqualValues(t, 3600, aws.Int64Value(roleResult.Role.MaxSessionDuration))

	trustDocument, err := url.QueryUnescape(aws.StringValue(roleResult.Role.AssumeRolePolicyDocument))
	require.NoError(t, err)
	require.Contains(t, trustDocument, trustedPrincipalARN)
	require.Contains(t, trustDocument, "sts:AssumeRole")
	require.NotContains(t, trustDocument, "arn:aws:sts::")
	require.NotContains(t, trustDocument, "\"AWS\":\"*\"")

	policyResult, err := iam.New(sess).GetRolePolicyWithContext(context.Background(), &iam.GetRolePolicyInput{
		RoleName:   aws.String(roleName),
		PolicyName: aws.String(roleName + "-eks-discovery"),
	})
	require.NoError(t, err)
	policyDocument, err := url.QueryUnescape(aws.StringValue(policyResult.PolicyDocument))
	require.NoError(t, err)
	require.Contains(t, policyDocument, "eks:ListClusters")
	require.Contains(t, policyDocument, "eks:DescribeCluster")
	require.Contains(t, policyDocument, clusterARN)

	var assumed *sts.AssumeRoleOutput
	require.Eventually(t, func() bool {
		assumed, err = sts.New(sess).AssumeRoleWithContext(context.Background(), &sts.AssumeRoleInput{
			RoleArn:         aws.String(roleARN),
			RoleSessionName: aws.String("unrealops-terratest"),
		})
		return err == nil
	}, 2*time.Minute, 5*time.Second, "assume the bootstrapped administrator role")

	assumedSession, err := session.NewSession(&aws.Config{
		Region: aws.String(region),
		Credentials: credentials.NewStaticCredentials(
			aws.StringValue(assumed.Credentials.AccessKeyId),
			aws.StringValue(assumed.Credentials.SecretAccessKey),
			aws.StringValue(assumed.Credentials.SessionToken),
		),
	})
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		_, listErr := eks.New(assumedSession).ListClustersWithContext(context.Background(), &eks.ListClustersInput{})
		return listErr == nil
	}, time.Minute, 5*time.Second, "list EKS clusters using the bootstrapped role")
}
