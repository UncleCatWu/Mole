//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/sys/unix"
)

const trashTimeout = 30 * time.Second

// trashBinary is Apple's own trash(8). It moves paths to the user Trash without
// involving Finder, which is what makes deletion work over SSH: the Finder
// AppleScript path raises a dialog on the physical machine that a remote user
// cannot answer, so the delete only ever times out (discussion #474).
//
// Invoked by absolute path rather than a PATH lookup so a "trash" shadowed
// earlier in the user's PATH can never receive a delete request. Arguments are
// always absolute paths, so no "--" separator is needed; passing one would make
// trash(8) report a missing file named "--" and exit non-zero even though it
// still trashed the real target, which would trigger a duplicate delete via the
// Finder fallback.
const trashBinary = "/usr/bin/trash"

var errTrashBinaryUnavailable = errors.New("trash binary unavailable")
var errTrashFilesystemUnavailable = errors.New("filesystem Trash unavailable")
var errTrashOutcomeUnknown = errors.New("trash command outcome unknown")

var trashBinaryProbe = func() error {
	_, err := os.Stat(trashBinary)
	return err
}

var trashBinaryRunner = func(ctx context.Context, path string) ([]byte, error) {
	return exec.CommandContext(ctx, trashBinary, path).CombinedOutput()
}
var trashFinderRunner = func(ctx context.Context, script string) ([]byte, error) {
	return exec.CommandContext(ctx, "osascript", "-e", script).CombinedOutput()
}
var trashFilesystemRunner = moveToTrashViaFilesystem

func deleteContext(contexts []context.Context) context.Context {
	if len(contexts) > 0 && contexts[0] != nil {
		return contexts[0]
	}
	return context.Background()
}

type deleteRequest struct {
	id         int64
	parentPath string
	ctx        context.Context
}

func deletePathCmd(path string, counter *int64, audit *deleteAudit, requests ...deleteRequest) tea.Cmd {
	var request deleteRequest
	if len(requests) > 0 {
		request = requests[0]
	}
	return func() tea.Msg {
		if err := deleteContext([]context.Context{request.ctx}).Err(); err != nil {
			return deleteProgressMsg{operationID: request.id, parentPath: request.parentPath, done: true, path: path, err: err}
		}
		audit.begin()
		count, err := trashPathWithProgress(path, counter, request.ctx)
		audit.record(path, err)
		audit.end()
		return deleteProgressMsg{
			operationID: request.id,
			parentPath:  request.parentPath,
			done:        true,
			err:         err,
			count:       count,
			path:        path,
			logWarning:  audit.warning(),
		}
	}
}

// deleteMultiplePathsCmd moves paths to Trash and aggregates results.
func deleteMultiplePathsCmd(paths []string, counter *int64, audit *deleteAudit, requests ...deleteRequest) tea.Cmd {
	var request deleteRequest
	if len(requests) > 0 {
		request = requests[0]
	}
	ctx := deleteContext([]context.Context{request.ctx})
	return func() tea.Msg {
		var totalCount int64
		var errors []string
		var removedPaths []string
		var stopErr error
		if err := ctx.Err(); err != nil {
			return deleteProgressMsg{operationID: request.id, parentPath: request.parentPath, done: true, err: err}
		}
		audit.begin()

		// Process deeper paths first to avoid parent/child conflicts.
		pathsToDelete := append([]string(nil), paths...)
		sort.Slice(pathsToDelete, func(i, j int) bool {
			return strings.Count(pathsToDelete[i], string(filepath.Separator)) > strings.Count(pathsToDelete[j], string(filepath.Separator))
		})

		for _, path := range pathsToDelete {
			if err := ctx.Err(); err != nil {
				stopErr = err
				break
			}
			count, err := trashPathWithProgress(path, counter, request.ctx)
			audit.record(path, err)
			totalCount += count
			if err != nil {
				if os.IsNotExist(err) {
					removedPaths = append(removedPaths, path)
					continue
				}
				errors = append(errors, err.Error())
				if isTerminalDeleteError(err) {
					stopErr = err
					break
				}
				continue
			}
			removedPaths = append(removedPaths, path)
		}

		var resultErr error
		if len(errors) > 0 {
			resultErr = &multiDeleteError{errors: errors}
		}
		if stopErr != nil {
			resultErr = stopErr
		}
		audit.end()

		return deleteProgressMsg{
			operationID:  request.id,
			parentPath:   request.parentPath,
			done:         true,
			err:          resultErr,
			count:        totalCount,
			path:         "",
			removedPaths: removedPaths,
			logWarning:   audit.warning(),
		}
	}
}

// multiDeleteError holds multiple deletion errors.
type multiDeleteError struct {
	errors []string
}

func (e *multiDeleteError) Error() string {
	if len(e.errors) == 1 {
		return e.errors[0]
	}
	return strings.Join(e.errors[:min(3, len(e.errors))], "; ")
}

// trashPathWithProgress moves one selected path to Trash and reports completion.
func trashPathWithProgress(root string, counter *int64, contexts ...context.Context) (int64, error) {
	ctx := deleteContext(contexts)
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	// Verify path exists (use Lstat to handle broken symlinks).
	_, err := os.Lstat(root)
	if err != nil {
		return 0, err
	}

	// Trash moves one selected path as a unit. Recursively counting every file
	// first made large directory deletes appear hung before the move began.
	const count int64 = 1

	// Move through a headless Trash route, with Finder as the last compatibility fallback.
	if err := moveToTrash(root, ctx); err != nil {
		return 0, err
	}
	if counter != nil {
		atomic.AddInt64(counter, count)
	}

	return count, nil
}

// moveToTrash moves a file/directory to the user Trash. macOS 15+ ships
// trash(8); older supported systems use an atomic, no-overwrite move into the
// correct per-volume Trash. Finder is only the final compatibility fallback.
func moveToTrash(path string, contexts ...context.Context) error {
	ctx := deleteContext(contexts)
	if err := ctx.Err(); err != nil {
		return err
	}
	// Validate raw input before Abs resolves ".." components away.
	if err := validateTrashTarget(path); err != nil {
		return err
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("failed to resolve path: %w", err)
	}

	// Validate resolved path as well (defense-in-depth).
	if err := validateTrashTarget(absPath); err != nil {
		return err
	}

	trashErr := moveToTrashViaBinary(absPath, ctx)
	if trashErr == nil {
		return nil
	}
	// A launched command's failure may mean it moved the item before failing.
	// Only absence of the binary proves that no first mutation was attempted.
	if !errors.Is(trashErr, errTrashBinaryUnavailable) {
		return trashErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	filesystemErr := trashFilesystemRunner(absPath, ctx)
	if filesystemErr == nil {
		return nil
	}
	if !errors.Is(filesystemErr, errTrashFilesystemUnavailable) {
		return filesystemErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	return moveToTrashViaFinder(absPath, ctx)
}

func isTerminalDeleteError(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, errTrashOutcomeUnknown)
}

// moveToTrashViaBinary moves absPath to Trash using trash(8). Returns an error
// when the binary is missing so callers fall back to Finder.
func moveToTrashViaBinary(absPath string, contexts ...context.Context) error {
	if err := trashBinaryProbe(); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%w: %v", errTrashBinaryUnavailable, err)
		}
		return err
	}

	ctx, cancel := context.WithTimeout(deleteContext(contexts), trashTimeout)
	defer cancel()

	output, err := trashBinaryRunner(ctx, absPath)
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("moving to Trash stopped: %w", ctx.Err())
		}
		return fmt.Errorf("%w: %s: %w", errTrashOutcomeUnknown, strings.TrimSpace(string(output)), err)
	}

	return nil
}

// moveToTrashViaFilesystem provides a headless path for macOS versions before
// trash(8). It uses renameatx_np(RENAME_EXCL), so a concurrent name collision
// can never overwrite an existing Trash item.
func moveToTrashViaFilesystem(absPath string, contexts ...context.Context) error {
	ctx := deleteContext(contexts)
	if err := ctx.Err(); err != nil {
		return err
	}
	trashDir, err := trashDirectoryForPath(absPath)
	if err != nil {
		return err
	}

	base := filepath.Base(absPath)
	if base == "." || base == string(filepath.Separator) || base == "" {
		return fmt.Errorf("invalid Trash item name")
	}

	stamp := time.Now().UnixNano()
	for attempt := range 100 {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := base
		if attempt > 0 {
			name = fmt.Sprintf("%s.%d.%d.%d", base, stamp, os.Getpid(), attempt)
		}
		dest := filepath.Join(trashDir, name)
		err = unix.RenameatxNp(unix.AT_FDCWD, absPath, unix.AT_FDCWD, dest, unix.RENAME_EXCL)
		if err == nil {
			return nil
		}
		if err != syscall.EEXIST {
			if err == syscall.EXDEV || err == syscall.ENOTSUP {
				return fmt.Errorf("%w: %v", errTrashFilesystemUnavailable, err)
			}
			return fmt.Errorf("failed to move to Trash: %w", err)
		}
	}

	return fmt.Errorf("failed to choose unique Trash destination for %s", absPath)
}

func trashDirectoryForPath(absPath string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to resolve home directory: %w", err)
	}

	var pathFS, homeFS unix.Statfs_t
	if err := unix.Statfs(absPath, &pathFS); err != nil {
		return "", fmt.Errorf("failed to inspect target volume: %w", err)
	}
	if err := unix.Statfs(home, &homeFS); err != nil {
		return "", fmt.Errorf("failed to inspect home volume: %w", err)
	}

	if pathFS.Fsid == homeFS.Fsid {
		trashDir := filepath.Join(home, ".Trash")
		if err := ensureOwnedTrashDirectory(trashDir, true); err != nil {
			return "", err
		}
		return trashDir, nil
	}

	mountPoint := strings.TrimRight(string(pathFS.Mntonname[:]), "\x00")
	if mountPoint == "" {
		return "", fmt.Errorf("target volume has no mount point")
	}
	trashRoot := filepath.Join(mountPoint, ".Trashes")
	rootInfo, err := os.Lstat(trashRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("%w: %v", errTrashFilesystemUnavailable, err)
		}
		return "", fmt.Errorf("volume Trash is unavailable: %w", err)
	}
	if rootInfo.Mode()&os.ModeSymlink != 0 || !rootInfo.IsDir() {
		return "", fmt.Errorf("volume Trash is not a normal directory")
	}

	trashDir := filepath.Join(trashRoot, fmt.Sprintf("%d", os.Getuid()))
	if err := ensureOwnedTrashDirectory(trashDir, true); err != nil {
		return "", err
	}
	return trashDir, nil
}

func ensureOwnedTrashDirectory(path string, create bool) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) && create {
		if err := os.Mkdir(path, 0o700); err != nil {
			return fmt.Errorf("failed to create Trash directory: %w", err)
		}
		info, err = os.Lstat(path)
	}
	if err != nil {
		return fmt.Errorf("failed to inspect Trash directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("trash path is not a normal directory")
	}

	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("trash directory is not owned by the current user")
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("trash directory is writable by another user")
	}
	return nil
}

// moveToTrashViaFinder remains as a last fallback for unusual volume layouts.
func moveToTrashViaFinder(absPath string, contexts ...context.Context) error {
	// Escape path for AppleScript (handle quotes and backslashes).
	escapedPath := strings.ReplaceAll(absPath, "\\", "\\\\")
	escapedPath = strings.ReplaceAll(escapedPath, "\"", "\\\"")

	script := fmt.Sprintf(`tell application "Finder" to delete POSIX file "%s"`, escapedPath)

	ctx, cancel := context.WithTimeout(deleteContext(contexts), trashTimeout)
	defer cancel()

	output, err := trashFinderRunner(ctx, script)
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("moving to Trash stopped: %w", ctx.Err())
		}
		return fmt.Errorf("%w: %s: %w", errTrashOutcomeUnknown, strings.TrimSpace(string(output)), err)
	}

	return nil
}

func validateTrashTarget(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	if isProtectedAnalyzeDeletePath(path) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	if resolvedPath, err := filepath.EvalSymlinks(path); err == nil && isProtectedAnalyzeDeletePath(resolvedPath) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	return nil
}

func isProtectedAnalyzeDeletePath(path string) bool {
	if path == "" {
		return false
	}

	cleanPath := filepath.Clean(path)

	// EDR / Darwin-cache protection is based on the absolute path and does not
	// depend on HOME, so check it first: an unset HOME must not let a Falcon
	// cache slip through (e.g. `env -u HOME mo analyze`).
	if isEndpointSecurityCachePath(cleanPath) {
		return true
	}
	if isCriticalAnalyzeDeletePath(cleanPath) {
		return true
	}

	homeRoots := protectedAnalyzeHomeRoots()
	if len(homeRoots) == 0 {
		return false
	}

	for _, homeRoot := range homeRoots {
		if cleanPath == homeRoot || isSameExistingPath(cleanPath, homeRoot) {
			return true
		}

		dockerDesktopState := filepath.Join(homeRoot, "Library", "Containers", "com.docker.docker")
		if cleanPath == dockerDesktopState || strings.HasPrefix(cleanPath, dockerDesktopState+string(filepath.Separator)) {
			return true
		}
		if isPathWithinExistingRoot(cleanPath, dockerDesktopState) ||
			containsProtectedRoot(cleanPath, dockerDesktopState) {
			return true
		}

		orbstackState := filepath.Join(homeRoot, ".orbstack")
		if cleanPath == orbstackState || strings.HasPrefix(cleanPath, orbstackState+string(filepath.Separator)) {
			return true
		}
		if isPathWithinExistingRoot(cleanPath, orbstackState) ||
			containsProtectedRoot(cleanPath, orbstackState) {
			return true
		}

		groupContainers := filepath.Join(homeRoot, "Library", "Group Containers")
		if entries, err := os.ReadDir(groupContainers); err == nil {
			for _, entry := range entries {
				if !strings.HasSuffix(strings.ToLower(entry.Name()), "dev.orbstack") {
					continue
				}
				stateRoot := filepath.Join(groupContainers, entry.Name())
				if isPathWithinExistingRoot(cleanPath, stateRoot) ||
					containsProtectedRoot(cleanPath, stateRoot) {
					return true
				}
			}
		}

		rel, err := filepath.Rel(strings.ToLower(groupContainers), strings.ToLower(cleanPath))
		if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}

		containerName := rel
		if idx := strings.Index(containerName, string(filepath.Separator)); idx >= 0 {
			containerName = containerName[:idx]
		}
		if strings.HasSuffix(strings.ToLower(containerName), "dev.orbstack") {
			return true
		}
	}
	return false
}

func isCriticalAnalyzeDeletePath(path string) bool {
	criticalRoots := []string{
		"/",
		"/Applications",
		"/Applications/Finder.app",
		"/Applications/Safari.app",
		"/Library",
		"/Library/Apple",
		"/Library/Application Support",
		"/Library/Extensions",
		"/Library/Keychains",
		"/System",
		"/Users",
		"/Volumes",
		"/Network",
		"/cores",
		"/dev",
		"/etc",
		"/home",
		"/net",
		"/tmp",
		"/var",
		"/private",
		"/private/etc",
		"/private/tmp",
		"/private/var",
		"/private/var/audit",
		"/private/var/db",
		"/private/var/root",
		"/private/var/tmp",
		"/private/var/folders",
		"/bin",
		"/sbin",
		"/usr",
		"/opt",
		"/opt/homebrew",
	}
	for _, root := range criticalRoots {
		if path == root || isSameExistingPath(path, root) {
			return true
		}
	}

	// A child directly under /Users is another account's home root, not an
	// ordinary directory. Protect every account root while keeping its
	// descendants available to the owning user.
	if isDirectChildOfExistingRoot(path, "/Users") {
		return true
	}

	// These system-owned trees are never an Analyze cleanup surface, even when
	// a caller starts inside one instead of selecting its top-level row.
	protectedTrees := []string{
		"/System",
		"/bin",
		"/sbin",
		"/usr",
		"/private/etc",
		"/private/var/audit",
		"/private/var/db",
		"/private/var/root",
		"/Library/Apple",
		"/Library/Extensions",
		"/Library/Keychains",
		"/Applications/Finder.app",
		"/Applications/Safari.app",
		"/dev",
	}
	for _, root := range protectedTrees {
		if strings.HasPrefix(path, root+string(filepath.Separator)) ||
			isPathWithinExistingRoot(path, root) {
			return true
		}
	}
	return false
}

func protectedAnalyzeHomeRoots() []string {
	var homeRoots []string
	seenHomeRoots := make(map[string]bool)
	addHomeRoot := func(home string) {
		if home == "" {
			return
		}
		cleanHome := filepath.Clean(home)
		if !seenHomeRoots[cleanHome] {
			homeRoots = append(homeRoots, cleanHome)
			seenHomeRoots[cleanHome] = true
		}
		if resolvedHome, err := filepath.EvalSymlinks(cleanHome); err == nil && !seenHomeRoots[resolvedHome] {
			homeRoots = append(homeRoots, resolvedHome)
			seenHomeRoots[resolvedHome] = true
		}
	}

	addHomeRoot(os.Getenv("HOME"))
	if currentUser, err := user.Current(); err == nil {
		addHomeRoot(currentUser.HomeDir)
	}
	return homeRoots
}

func containsProtectedRoot(path, protectedRoot string) bool {
	// An absent runtime must not make an otherwise empty container directory
	// undeletable. Unknown visibility still keeps its structural ancestors.
	if _, err := os.Lstat(protectedRoot); os.IsNotExist(err) {
		return false
	}
	if resolved, err := filepath.EvalSymlinks(protectedRoot); err == nil &&
		isPathWithinExistingRoot(resolved, path) {
		return true
	}
	return isPathWithinExistingRoot(protectedRoot, path)
}

func isPathWithinExistingRoot(path, protectedRoot string) bool {
	protectedInfo, err := os.Stat(protectedRoot)
	if err != nil {
		return false
	}

	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		if currentInfo, err := os.Stat(current); err == nil && os.SameFile(currentInfo, protectedInfo) {
			return true
		}
		parent := filepath.Dir(current)
		if parent == current {
			return false
		}
	}
}

func isSameExistingPath(path, protectedPath string) bool {
	pathInfo, pathErr := os.Stat(path)
	protectedInfo, protectedErr := os.Stat(protectedPath)
	return pathErr == nil && protectedErr == nil && os.SameFile(pathInfo, protectedInfo)
}

func isDirectChildOfExistingRoot(path, protectedRoot string) bool {
	cleanPath := filepath.Clean(path)
	return cleanPath != filepath.Clean(protectedRoot) &&
		filepath.Dir(cleanPath) != cleanPath &&
		isSameExistingPath(filepath.Dir(cleanPath), protectedRoot)
}

// endpointSecurityBundlePrefixes mirrors ENDPOINT_SECURITY_BUNDLE_PREFIXES in
// lib/core/app_protection_data.sh. Deleting anything inside one of these EDR/MDM
// agents' per-user Darwin caches trips sensor tamper detection (e.g. CrowdStrike
// MacFalconSensorTamper, MITRE T1562.001), so analyze must never Trash them.
var endpointSecurityBundlePrefixes = []string{
	"com.crowdstrike.",
	"com.sentinelone.",
	"com.sentinel-labs.",
	"com.eset.",
	"com.jamf.",
	"com.jamfsoftware.",
	"com.paloaltonetworks.",
	"com.cisco.anyconnect",
	"com.cisco.secureclient",
	"com.alibaba.security.",
}

// isEndpointSecurityCachePath reports whether path is an endpoint-security / EDR
// agent file under the per-user Darwin folder (/private/var/folders or its
// /var/folders symlink form). Mirror of is_endpoint_security_cache_path() in
// lib/core/app_protection.sh.
func isEndpointSecurityCachePath(path string) bool {
	lowerPath := strings.ToLower(path)
	if !strings.HasPrefix(lowerPath, "/private/var/folders/") && !strings.HasPrefix(lowerPath, "/var/folders/") {
		return false
	}
	// A whole Darwin user/cache container also moves any protected agent
	// below it. Keep the structural ancestors; ordinary app cache leaves stay
	// eligible without an unbounded recursive scan of the shared container.
	rel := strings.TrimPrefix(strings.TrimPrefix(lowerPath, "/private"), "/var/folders/")
	if len(strings.Split(rel, string(filepath.Separator))) <= 3 {
		return true
	}
	for _, prefix := range endpointSecurityBundlePrefixes {
		if strings.Contains(lowerPath, prefix) {
			return true
		}
	}
	return false
}

// validatePath checks path safety for external commands.
// Returns error if path is empty, relative, contains null bytes, or has traversal.
func validatePath(path string) error {
	if path == "" {
		return fmt.Errorf("path is empty")
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("path must be absolute: %s", path)
	}
	if strings.Contains(path, "\x00") {
		return fmt.Errorf("path contains null bytes")
	}
	// Check for path traversal attempts (.. components).
	if slices.Contains(strings.Split(path, string(filepath.Separator)), "..") {
		return fmt.Errorf("path contains traversal components: %s", path)
	}
	return nil
}
