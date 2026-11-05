package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"aurora/edge-agent/internal/relay"
)

const usage = "usage: aurora-relay-agent <run|sync> [--config /etc/aurora-relay/target-agent.json]"

type commandRunner struct{}

func (commandRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 64
	}
	switch args[0] {
	case "run":
		return runDaemon(args[1:], stderr)
	case "sync":
		return runSync(args[1:], stdout, stderr)
	default:
		fmt.Fprintln(stderr, usage)
		return 64
	}
}

func runDaemon(args []string, stderr io.Writer) int {
	configPath, code := parseConfigArgs("run", args, stderr)
	if code != 0 {
		return code
	}
	agent, err := loadAgent(configPath)
	if err != nil {
		fmt.Fprintf(stderr, "relay-agent start failed category=%s\n", relay.Category(err))
		return 1
	}
	agent.SetLogger(log.New(stderr, "aurora-relay-agent ", log.LstdFlags|log.LUTC))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	agent.Run(ctx)
	return 0
}

func runSync(args []string, stdout io.Writer, stderr io.Writer) int {
	configPath, code := parseConfigArgs("sync", args, stderr)
	if code != 0 {
		return code
	}
	agent, err := loadAgent(configPath)
	if err != nil {
		fmt.Fprintf(stderr, "relay-agent sync failed category=%s\n", relay.Category(err))
		return 1
	}
	if err := agent.Tick(context.Background()); err != nil {
		fmt.Fprintf(stderr, "relay-agent sync failed category=%s\n", relay.Category(err))
		return 1
	}
	fmt.Fprintln(stdout, "[OK] relay household target synchronized")
	return 0
}

func parseConfigArgs(command string, args []string, stderr io.Writer) (string, int) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "/etc/aurora-relay/target-agent.json", "root-managed configuration path")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(stderr, usage)
		return "", 64
	}
	return *configPath, 0
}

func loadAgent(configPath string) (*relay.Agent, error) {
	config, err := relay.LoadConfig(configPath)
	if err != nil {
		return nil, err
	}
	return relay.NewAgent(
		config,
		&http.Client{},
		net.DefaultResolver,
		commandRunner{},
		nil,
	)
}
