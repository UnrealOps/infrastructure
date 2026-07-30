package tests

import (
	"path/filepath"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestNetwork(t *testing.T) {
	region := requireAcc(t)
	name := testName("unrealops-network")
	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    filepath.Join(repositoryRoot(t), "terraform/tests/fixtures/network"),
		TerraformBinary: terraformBinary(),
		NoColor:         true,
		Vars: map[string]interface{}{
			"name":   name,
			"region": region,
		},
	})

	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	require.Equal(t, "10.0.0.0/16", terraform.Output(t, opts, "vpc_cidr"))
	require.Len(t, terraform.OutputList(t, opts, "private_subnet_ids"), 3)
	require.Len(t, terraform.OutputList(t, opts, "public_subnet_ids"), 3)
	require.Len(t, terraform.OutputList(t, opts, "vpn_subnet_ids"), 3)
	require.Len(t, terraform.OutputList(t, opts, "nat_gateway_ids"), 3)
	require.NotEmpty(t, terraform.Output(t, opts, "vpn_source_prefix_list_id"))
	require.NotEmpty(t, terraform.Output(t, opts, "s3_gateway_endpoint_id"))
	require.NotEmpty(t, terraform.Output(t, opts, "dynamodb_gateway_endpoint_id"))
}
