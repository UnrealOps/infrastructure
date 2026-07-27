package tests

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
)

const (
	maxTestRunIDLength     = 16
	processStopGracePeriod = 5 * time.Second
)

var testRunIDPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`)

type managedProcess struct {
	command  *exec.Cmd
	done     chan struct{}
	waitErr  error
	stopOnce sync.Once
	stopErr  error
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("determine repository root")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(filename), "..", ".."))
}

func requireAcc(t *testing.T) (region string) {
	t.Helper()
	if os.Getenv("TF_ACC") != "1" {
		t.Skip("set TF_ACC=1 to run billable AWS acceptance tests")
	}

	runID := os.Getenv("TEST_RUN_ID")
	if err := validateTestRunID(runID); err != nil {
		t.Fatalf("invalid TEST_RUN_ID: %v", err)
	}

	expectedAccount := os.Getenv("TEST_AWS_ACCOUNT_ID")
	if expectedAccount == "" {
		t.Fatal("TEST_AWS_ACCOUNT_ID is required to guard against deploying into the wrong account")
	}

	region = os.Getenv("AWS_REGION")
	if region == "" {
		t.Fatal("AWS_REGION is required; acceptance tests never infer a region")
	}
	if defaultRegion := os.Getenv("AWS_DEFAULT_REGION"); defaultRegion == "" {
		t.Fatal("AWS_DEFAULT_REGION is required and must match AWS_REGION")
	} else if defaultRegion != region {
		t.Fatalf("AWS_DEFAULT_REGION %q must match AWS_REGION %q", defaultRegion, region)
	}

	sess, err := session.NewSession(&aws.Config{Region: aws.String(region)})
	if err != nil {
		t.Fatalf("create AWS session: %v", err)
	}
	identity, err := sts.New(sess).GetCallerIdentityWithContext(context.Background(), &sts.GetCallerIdentityInput{})
	if err != nil {
		t.Fatalf("read AWS caller identity: %v", err)
	}
	if identity.Account == nil || *identity.Account != expectedAccount {
		actual := "unknown"
		if identity.Account != nil {
			actual = *identity.Account
		}
		t.Fatalf("refusing acceptance test in AWS account %s; expected %s", actual, expectedAccount)
	}
	return region
}

func requiredEnv(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if value == "" {
		t.Fatalf("%s is required", name)
	}
	return value
}

func terraformBinary() string {
	if binary := os.Getenv("TERRAFORM_BINARY"); binary != "" {
		return binary
	}
	return "tofu"
}

func testName(prefix string) string {
	runID := os.Getenv("TEST_RUN_ID")
	if err := validateTestRunID(runID); err != nil {
		panic(fmt.Sprintf("testName called without a valid TEST_RUN_ID: %v", err))
	}
	return fmt.Sprintf("%s-%s", prefix, runID)
}

func validateTestRunID(value string) error {
	if value == "" {
		return errors.New("must be set for acceptance tests")
	}
	if len(value) > maxTestRunIDLength {
		return fmt.Errorf("must be at most %d characters", maxTestRunIDLength)
	}
	if !testRunIDPattern.MatchString(value) {
		return errors.New("must contain only lowercase letters, digits, or hyphens and cannot start or end with a hyphen")
	}
	return nil
}

func startManagedProcess(command *exec.Cmd) (*managedProcess, error) {
	if err := command.Start(); err != nil {
		return nil, err
	}

	process := &managedProcess{
		command: command,
		done:    make(chan struct{}),
	}
	go func() {
		process.waitErr = command.Wait()
		close(process.done)
	}()
	return process, nil
}

func (process *managedProcess) Done() <-chan struct{} {
	return process.done
}

func (process *managedProcess) WaitErr() error {
	<-process.done
	return process.waitErr
}

func (process *managedProcess) Stop(gracePeriod time.Duration) error {
	process.stopOnce.Do(func() {
		select {
		case <-process.done:
			return
		default:
		}

		if err := process.command.Process.Signal(os.Interrupt); err != nil {
			if errors.Is(err, os.ErrProcessDone) {
				<-process.done
				return
			}
			process.stopErr = process.killAndWait()
			return
		}

		timer := time.NewTimer(gracePeriod)
		defer timer.Stop()
		select {
		case <-process.done:
			return
		case <-timer.C:
			process.stopErr = process.killAndWait()
		}
	})
	return process.stopErr
}

func (process *managedProcess) killAndWait() error {
	if err := process.command.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return fmt.Errorf("kill process: %w", err)
	}
	<-process.done
	return nil
}

func registerProcessCleanup(t *testing.T, process *managedProcess, description string) func() {
	t.Helper()
	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			if err := process.Stop(processStopGracePeriod); err != nil {
				t.Errorf("stop %s: %v", description, err)
			}
		})
	}
	t.Cleanup(cleanup)
	return cleanup
}
