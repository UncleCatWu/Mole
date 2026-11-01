//go:build darwin

package main

import (
	"bufio"
	"context"
	"errors"
	tea "github.com/charmbracelet/bubbletea"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

type exitLifecycleModel struct {
	model
	started, finished chan struct{}
	exit              tea.Msg
}

func (m exitLifecycleModel) Init() tea.Cmd {
	return tea.Batch(m.trackDelete(func() tea.Msg {
		close(m.started)
		<-m.lifetimeContext().Done()
		// Cleanup must wait for the active mutation to acknowledge cancellation.
		time.Sleep(10 * time.Millisecond)
		close(m.finished)
		return nil
	}), func() tea.Msg { <-m.started; return m.exit })
}
func (m exitLifecycleModel) Update(tea.Msg) (tea.Model, tea.Cmd) { return m, nil }
func (m exitLifecycleModel) View() string                        { return "" }

func TestAnalyzerProgramExitCancelsAndWaits(t *testing.T) {
	for _, msg := range []tea.Msg{tea.QuitMsg{}, tea.InterruptMsg{}} {
		l := newAnalyzerLifecycle()
		scanCtx, scanCancel := context.WithCancel(l.ctx)
		pubCtx, pubCancel := context.WithCancel(scanCtx)
		publication := newScanPublication(pubCtx, pubCancel)
		m := exitLifecycleModel{model: model{lifecycle: l, scanRequestContext: scanCtx, scanRequestCancel: scanCancel, cacheSavePublication: publication}, started: make(chan struct{}), finished: make(chan struct{}), exit: msg}
		p := tea.NewProgram(m, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(), tea.WithFilter(analyzerExitFilter))
		_, err := p.Run()
		if _, interrupted := msg.(tea.InterruptMsg); interrupted && !errors.Is(err, tea.ErrInterrupted) {
			t.Fatalf("interrupt: %v", err)
		}
		select {
		case <-m.finished:
		default:
			t.Fatal("program returned before active mutation finished")
		}
		if l.ctx.Err() == nil || scanCtx.Err() == nil {
			t.Fatal("exit retained a live context")
		}
		if err := publication.commit(func() error { t.Fatal("late cache publication"); return nil }); !errors.Is(err, context.Canceled) {
			t.Fatalf("publication: %v", err)
		}
		called := false
		m.trackDelete(func() tea.Msg { called = true; return nil })()
		if called {
			t.Fatal("next queued target began after program exit")
		}
	}
}

func TestAnalyzerRunErrorCancelsLifetime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	m := newModel(t.TempDir(), false)
	// An already canceled program context returns without Init or real probes.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := runAnalyzerProgram(m, tea.WithContext(ctx), tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer())
	if err == nil {
		t.Fatal("positive control: program did not report its canceled startup")
	}
	if m.lifecycle.ctx.Err() == nil || m.scanRequestContext.Err() == nil {
		t.Fatal("Run error did not revoke lifetime")
	}
}

func TestAnalyzerSnapshotInheritsExitContext(t *testing.T) {
	l := newAnalyzerLifecycle()
	started := make(chan struct{})
	finished := make(chan struct{})
	m := model{lifecycle: l, snapshotRunner: func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		close(started)
		<-ctx.Done()
		time.Sleep(10 * time.Millisecond)
		close(finished)
		return nil, ctx.Err()
	}}
	result := make(chan tea.Msg, 1)
	go func() { result <- m.detectLocalSnapshotsCmd()() }()
	<-started
	l.stop()
	select {
	case <-finished:
	default:
		t.Fatal("exit did not wait for snapshot command cleanup")
	}
	select {
	case msg := <-result:
		if !errors.Is(msg.(localSnapshotMsg).err, context.Canceled) {
			t.Fatalf("snapshot: %+v", msg)
		}
	case <-time.After(time.Second):
		t.Fatal("snapshot ignored lifetime cancellation")
	}
}

// A private subprocess exercises Bubble Tea's native signal handler without
// sending a signal to the test runner or any process outside this fixture.
type signalLifecycleModel struct{ model }

func (m signalLifecycleModel) Init() tea.Cmd {
	return m.trackDelete(func() tea.Msg {
		println("ANALYZER_SIGNAL_READY")
		<-m.lifetimeContext().Done()
		time.Sleep(10 * time.Millisecond)
		println("ANALYZER_SIGNAL_FINISHED")
		return nil
	})
}
func (m signalLifecycleModel) Update(tea.Msg) (tea.Model, tea.Cmd) { return m, nil }
func (m signalLifecycleModel) View() string                        { return "" }

func TestAnalyzerNativeSignalChild(t *testing.T) {
	if os.Getenv("MOLE_TEST_ANALYZER_SIGNAL_CHILD") != "1" {
		return
	}
	// Guard only this test subprocess during Tea's asynchronous registration.
	// Re-deliver the controlled notification until Tea itself handles it; the
	// filter's observed native message is the readiness proof, never a sleep.
	bootSignals := make(chan os.Signal, 1)
	signal.Notify(bootSignals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(bootSignals)
	l := newAnalyzerLifecycle()
	defer l.stop()
	guardCtx, guardCancel := context.WithCancel(l.ctx)
	guardDone := make(chan struct{})
	defer func() { guardCancel(); <-guardDone }()
	go func() {
		defer close(guardDone)
		var notification os.Signal
		select {
		case notification = <-bootSignals:
		case <-guardCtx.Done():
			return
		}
		process, err := os.FindProcess(os.Getpid())
		if err != nil {
			return
		}
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-guardCtx.Done():
				return
			case <-ticker.C:
				_ = process.Signal(notification)
			}
		}
	}()
	m := signalLifecycleModel{model: model{lifecycle: l}}
	nativeFilter := func(current tea.Model, msg tea.Msg) tea.Msg {
		switch msg.(type) {
		case tea.QuitMsg, tea.InterruptMsg:
			println("ANALYZER_NATIVE_SIGNAL_HANDLED")
		}
		if os.Getenv("MOLE_TEST_ANALYZER_BYPASS_EXIT") == "1" {
			return msg
		}
		return analyzerExitFilter(current, msg)
	}
	_, err := tea.NewProgram(m, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(), tea.WithFilter(nativeFilter)).Run()
	if err != nil && !errors.Is(err, tea.ErrInterrupted) {
		t.Fatal(err)
	}
	if l.ctx.Err() == nil {
		println("ANALYZER_EXIT_BOUNDARY_MISSING")
		t.Fatal("signal retained active lifetime")
	}
	println("ANALYZER_SIGNAL_EXITED")
}

func TestAnalyzerNativeSignalsCancelAndWait(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM} {
		t.Run(sig.String(), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, executable, "-test.run=^TestAnalyzerNativeSignalChild$", "-test.timeout=8s")
			cmd.Env = append(os.Environ(), "MOLE_TEST_ANALYZER_SIGNAL_CHILD=1")
			pipe, err := cmd.StderrPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = cmd.Process.Kill() }()
			scanner := bufio.NewScanner(pipe)
			var lines []string
			ready := false
			for scanner.Scan() {
				line := scanner.Text()
				lines = append(lines, line)
				if line == "ANALYZER_SIGNAL_READY" {
					ready = true
					if err := cmd.Process.Signal(sig); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err := scanner.Err(); err != nil {
				t.Fatal(err)
			}
			if err := cmd.Wait(); err != nil {
				t.Fatalf("child: %v; %s", err, strings.Join(lines, "\n"))
			}
			output := strings.Join(lines, "\n")
			if !ready || !strings.Contains(output, "ANALYZER_NATIVE_SIGNAL_HANDLED") || !strings.Contains(output, "ANALYZER_SIGNAL_FINISHED\nANALYZER_SIGNAL_EXITED") {
				t.Fatalf("signal returned before active mutation completed: %s", output)
			}
		})
	}
}

func TestOverviewPublicationRevokesWriterQueuedOnStoreLock(t *testing.T) {
	for _, action := range []string{"cancel", "refresh", "exit"} {
		t.Run(action, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			resetOverviewSnapshotForTest()
			m := newModel(t.TempDir(), false)
			defer m.lifecycle.stop()
			ctx := m.scanRequestContext
			overviewSnapshotMu.Lock()
			started := make(chan struct{})
			result := make(chan error, 1)
			if !startAnalyzerWork(ctx, func() { close(started); result <- storeOverviewSizeWithContext(ctx, m.path, 41) }) {
				t.Fatal("writer was not admitted")
			}
			<-started
			stopped := make(chan struct{})
			go func() {
				switch action {
				case "cancel":
					m.scanRequestPublication.cancel()
				case "refresh":
					m.cancelLiveScan()
				case "exit":
					m.stopForExit()
				}
				close(stopped)
			}()
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
				overviewSnapshotMu.Unlock()
				t.Fatal("cancellation blocked behind store lock")
			}
			overviewSnapshotMu.Unlock()
			if err := <-result; !errors.Is(err, context.Canceled) {
				t.Fatalf("queued writer: %v", err)
			}
			<-stopped
			if _, err := loadStoredOverviewSize(m.path); err == nil {
				t.Fatal("revoked writer populated memory")
			}
			store, err := getOverviewSizeStorePath()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(store); !os.IsNotExist(err) {
				t.Fatalf("revoked writer populated disk: %v", err)
			}
			fresh := newModel(m.path, false)
			defer fresh.lifecycle.stop()
			if err := storeOverviewSizeWithContext(fresh.scanRequestContext, fresh.path, 93); err != nil {
				t.Fatal(err)
			}
			if size, err := loadStoredOverviewSize(fresh.path); err != nil || size != 93 {
				t.Fatalf("live positive control: %d %v", size, err)
			}
			if _, err := os.Stat(store); err != nil {
				t.Fatalf("live positive control did not persist: %v", err)
			}
		})
	}
}

func TestAnalyzerExitWaitsForLiveScanDuReapAndRejectsQueuedWork(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "node_modules"), 0700); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	pidPath := filepath.Join(home, "du.pid")
	t.Setenv("MOLE_TEST_DU_PID", pidPath)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(`#!/bin/sh
printf '%s' "$$" > "$MOLE_TEST_DU_PID"
exec /bin/sleep 30
`), 0700); err != nil {
		t.Fatal(err)
	}
	m := newModel(root, false)
	defer m.lifecycle.stop()
	queued := m.scanFreshCmd(root)
	msg := queued().(liveScanStartMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	m.liveScanCancel = msg.cancel
	var pid int
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(pidPath); err == nil {
			pid, _ = strconv.Atoi(string(data))
			if pid > 0 {
				break
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("positive control: private du did not start")
	}
	m.stopForExit()
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("private du remained after exit: %v", err)
	}
	if msg := queued(); msg != nil {
		t.Fatalf("queued scan started after exit: %T", msg)
	}
	ran := false
	if startAnalyzerWork(m.lifetimeContext(), func() { ran = true }) || ran {
		t.Fatal("queued cache work started after exit")
	}
}

func TestAnalyzerNativeSignalNegativeControl(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestAnalyzerNativeSignalChild$", "-test.timeout=8s")
	cmd.Env = append(os.Environ(), "MOLE_TEST_ANALYZER_SIGNAL_CHILD=1", "MOLE_TEST_ANALYZER_BYPASS_EXIT=1")
	pipe, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill() }()
	scanner := bufio.NewScanner(pipe)
	var lines []string
	for scanner.Scan() {
		line := scanner.Text()
		lines = append(lines, line)
		if line == "ANALYZER_SIGNAL_READY" {
			if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err == nil {
		t.Fatal("negative control did not fail without the exit boundary")
	}
	output := strings.Join(lines, "\n")
	if !strings.Contains(output, "ANALYZER_NATIVE_SIGNAL_HANDLED") || !strings.Contains(output, "ANALYZER_EXIT_BOUNDARY_MISSING") {
		t.Fatalf("negative control missed native signal: %s", output)
	}
}
