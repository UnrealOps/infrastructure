package tests

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type openVPNConnectProfile struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type openVPNConnectImportResult struct {
	Message struct {
		ID string `json:"id"`
	} `json:"message"`
	Status string `json:"status"`
}

type openVPNConnectVersion struct {
	Version string `json:"version"`
}

type openVPNConnectCleanupState struct {
	once              sync.Once
	tunnelMayBeActive bool
	profileMayExist   bool
	appMayBeRunning   bool
	profileID         string
}

// startOpenVPNConnectTunnel uses OpenVPN Connect's installed privileged helper
// on macOS hosts where an unprivileged openvpn process cannot create a utun
// interface. It refuses to disrupt an already-running Connect session. The
// imported profile is removed and the connection is stopped on cleanup.
func startOpenVPNConnectTunnel(t *testing.T, connectCLI, profile, endpoint string) func() {
	t.Helper()
	require.Equal(t, "darwin", runtime.GOOS, "TEST_OPENVPN_CONNECT_CLI is supported only on macOS")
	resolvedCLI, err := filepath.EvalSymlinks(connectCLI)
	require.NoError(t, err, "resolve TEST_OPENVPN_CONNECT_CLI")
	info, err := os.Stat(resolvedCLI)
	require.NoError(t, err, "stat TEST_OPENVPN_CONNECT_CLI")
	require.False(t, info.IsDir(), "TEST_OPENVPN_CONNECT_CLI must name the OpenVPN Connect executable")
	connectCLI = resolvedCLI

	appPath := filepath.Clean(filepath.Join(filepath.Dir(connectCLI), "..", ".."))
	require.Equal(t, ".app", filepath.Ext(appPath), "TEST_OPENVPN_CONNECT_CLI must be inside a macOS .app bundle")
	_, err = os.Stat(filepath.Join(appPath, "Contents", "Info.plist"))
	require.NoError(t, err, "validate OpenVPN Connect application bundle")
	running, err := openVPNConnectIsRunning()
	require.NoError(t, err)
	require.False(t, running, "refusing to interrupt an already-running OpenVPN Connect session")
	requireSupportedOpenVPNConnect(t, connectCLI)

	profilesBefore := listOpenVPNConnectProfiles(t, connectCLI)
	profileName := fmt.Sprintf("unrealops-acceptance-%s", os.Getenv("TEST_RUN_ID"))
	beforeIDs := make(map[string]struct{}, len(profilesBefore))
	for _, existing := range profilesBefore {
		require.NotEqual(t, profileName, existing.Name, "temporary OpenVPN Connect profile name already exists")
		beforeIDs[existing.ID] = struct{}{}
	}
	running, err = openVPNConnectIsRunning()
	require.NoError(t, err)
	require.False(t, running, "refusing to interrupt an OpenVPN Connect session started during preflight")

	state := &openVPNConnectCleanupState{}
	cleanup := func() {
		state.once.Do(func() {
			if state.tunnelMayBeActive && runOpenVPNConnectCleanupCommand(t, connectCLI, "--disconnect-shortcut") {
				state.tunnelMayBeActive = false
			}

			appStopped := true
			if state.appMayBeRunning {
				running, runningErr := openVPNConnectIsRunning()
				if runningErr != nil {
					t.Errorf("inspect OpenVPN Connect process during cleanup: %v", runningErr)
					appStopped = false
				} else if running {
					_ = runOpenVPNConnectCleanupCommand(t, connectCLI, "--quit")
					appStopped = waitForOpenVPNConnectToStop(t, 30*time.Second)
				}
				if appStopped {
					state.appMayBeRunning = false
				}
			}

			if state.profileMayExist {
				if !appStopped {
					t.Errorf("refusing to remove temporary OpenVPN Connect profile while the app may still be running")
				} else if removeImportedOpenVPNConnectProfile(
					t,
					connectCLI,
					state.profileID,
					profileName,
					beforeIDs,
				) {
					state.profileMayExist = false
				}
			}
		})
	}
	t.Cleanup(cleanup)
	returned := false
	defer func() {
		if !returned {
			cleanup()
		}
	}()

	profile = profileWithRemote(t, profile, endpoint)
	state.profileMayExist = true
	importOutput := runCommand(t, nil, connectCLI, "--import-profile="+profile, "--name="+profileName)
	var imported openVPNConnectImportResult
	require.NoError(t, json.Unmarshal([]byte(importOutput), &imported), "parse OpenVPN Connect import result: %s", importOutput)
	require.Equal(t, "success", imported.Status, "OpenVPN Connect profile import failed: %s", importOutput)
	require.NotEmpty(t, imported.Message.ID, "OpenVPN Connect did not return an imported profile ID: %s", importOutput)

	profilesAfter := listOpenVPNConnectProfiles(t, connectCLI)
	newProfiles := make([]openVPNConnectProfile, 0, 1)
	for _, candidate := range profilesAfter {
		if _, existed := beforeIDs[candidate.ID]; !existed {
			newProfiles = append(newProfiles, candidate)
		}
	}
	require.Equal(t, []openVPNConnectProfile{{ID: imported.Message.ID, Name: profileName}}, newProfiles,
		"the acceptance profile must be the only newly imported and therefore latest profile")
	state.profileID = imported.Message.ID

	state.appMayBeRunning = true
	runCommand(t, nil, "open", "-a", appPath, "--args", "--minimize")
	waitForOpenVPNConnectToStart(t, 30*time.Second)

	state.tunnelMayBeActive = true
	// A cold shortcut CLI host exits after dispatch and tears down its utun.
	// Launch the app first, then send the profile-specific desktop-shortcut
	// command to its warm IPC server. This does not mutate launch-options.
	runCommand(t, nil, connectCLI, "--connect-shortcut="+imported.Message.ID)
	returned = true
	return cleanup
}

func requireSupportedOpenVPNConnect(t *testing.T, connectCLI string) {
	t.Helper()
	output := runCommand(t, nil, connectCLI, "--version")
	var version openVPNConnectVersion
	require.NoError(t, json.Unmarshal([]byte(output), &version), "parse OpenVPN Connect version: %s", output)
	parts := strings.SplitN(version.Version, ".", 3)
	require.Len(t, parts, 3, "parse OpenVPN Connect semantic version %q", version.Version)
	major, err := strconv.Atoi(parts[0])
	require.NoError(t, err, "parse OpenVPN Connect major version %q", version.Version)
	minor, err := strconv.Atoi(parts[1])
	require.NoError(t, err, "parse OpenVPN Connect minor version %q", version.Version)
	require.True(t, major == 3 && minor >= 6,
		"OpenVPN Connect 3.6 or newer in the 3.x line is required; found %q", version.Version)
}

func listOpenVPNConnectProfiles(t *testing.T, connectCLI string) []openVPNConnectProfile {
	t.Helper()
	output := runCommand(t, nil, connectCLI, "--list-profiles")
	var profiles []openVPNConnectProfile
	require.NoError(t, json.Unmarshal([]byte(output), &profiles), "parse OpenVPN Connect profiles: %s", output)
	return profiles
}

func removeImportedOpenVPNConnectProfile(
	t *testing.T,
	connectCLI string,
	profileID string,
	profileName string,
	beforeIDs map[string]struct{},
) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := runCommandE(ctx, nil, connectCLI, "--list-profiles")
	if err != nil {
		t.Errorf("list OpenVPN Connect profiles during cleanup: %v: %s", err, strings.TrimSpace(output))
		return false
	}
	var profiles []openVPNConnectProfile
	if err := json.Unmarshal([]byte(output), &profiles); err != nil {
		t.Errorf("parse OpenVPN Connect profiles during cleanup: %v: %s", err, strings.TrimSpace(output))
		return false
	}

	if profileID != "" {
		for _, candidate := range profiles {
			if candidate.ID == profileID {
				return runOpenVPNConnectCleanupCommand(t, connectCLI, "--remove-profile="+profileID)
			}
		}
		return true
	}

	candidates := make([]openVPNConnectProfile, 0, 1)
	for _, candidate := range profiles {
		_, existed := beforeIDs[candidate.ID]
		if !existed && candidate.Name == profileName {
			candidates = append(candidates, candidate)
		}
	}
	if len(candidates) == 0 {
		return true
	}
	if len(candidates) != 1 {
		t.Errorf("refusing broad OpenVPN Connect cleanup: found %d new profiles named %q without a verified import ID", len(candidates), profileName)
		return false
	}
	return runOpenVPNConnectCleanupCommand(t, connectCLI, "--remove-profile="+candidates[0].ID)
}

func openVPNConnectIsRunning() (bool, error) {
	command := exec.Command("pgrep", "-x", "OpenVPN Connect")
	err := command.Run()
	if err == nil {
		return true, nil
	}
	if exitError, ok := err.(*exec.ExitError); ok && exitError.ExitCode() == 1 {
		return false, nil
	}
	return false, fmt.Errorf("pgrep OpenVPN Connect: %w", err)
}

func waitForOpenVPNConnectToStart(t *testing.T, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		running, err := openVPNConnectIsRunning()
		require.NoError(t, err, "inspect OpenVPN Connect process after launch")
		if running {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("OpenVPN Connect did not start within %s", timeout)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func waitForOpenVPNConnectToStop(t *testing.T, timeout time.Duration) bool {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		running, err := openVPNConnectIsRunning()
		if err != nil {
			t.Errorf("inspect OpenVPN Connect process after quit: %v", err)
			return false
		}
		if !running {
			return true
		}
		if time.Now().After(deadline) {
			t.Errorf("OpenVPN Connect did not quit within %s", timeout)
			return false
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func profileWithRemote(t *testing.T, profile, endpoint string) string {
	t.Helper()
	profile = profileWithoutRemote(t, profile)
	contents, err := os.ReadFile(profile)
	require.NoError(t, err)

	path := filepath.Join(t.TempDir(), "openvpn-connect-client.ovpn")
	contents = append(contents, []byte(fmt.Sprintf("\nremote %s 1194\n", endpoint))...)
	require.NoError(t, os.WriteFile(path, contents, 0o600))
	return path
}

func runOpenVPNConnectCleanupCommand(t *testing.T, connectCLI string, args ...string) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := runCommandE(ctx, nil, connectCLI, args...)
	if err != nil {
		t.Errorf("OpenVPN Connect cleanup failed: %s %s: %v: %s", connectCLI, strings.Join(args, " "), err, strings.TrimSpace(output))
		return false
	}
	return true
}
