package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"aurora/edge-agent/internal/home"
	"aurora/edge-agent/internal/lease"
)

const usage = "usage: aurora-home-agent <run|check|keygen> [options]"

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
		return runDaemon(args[1:], stdout, stderr)
	case "check":
		return runCheck(args[1:], stdout, stderr)
	case "keygen":
		return runKeygen(args[1:], stdout, stderr)
	default:
		fmt.Fprintln(stderr, usage)
		return 64
	}
}

func runDaemon(args []string, _ io.Writer, stderr io.Writer) int {
	configPath, code := parseConfigArgs("run", args, stderr)
	if code != 0 {
		return code
	}
	agent, err := loadAgent(configPath)
	if err != nil {
		fmt.Fprintf(stderr, "home-agent start failed category=%s\n", home.Category(err))
		return 1
	}
	agent.SetLogger(log.New(stderr, "aurora-home-agent ", log.LstdFlags|log.LUTC))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	agent.Run(ctx)
	return 0
}

func runCheck(args []string, stdout io.Writer, stderr io.Writer) int {
	configPath, code := parseConfigArgs("check", args, stderr)
	if code != 0 {
		return code
	}
	agent, err := loadAgent(configPath)
	if err != nil {
		fmt.Fprintf(stderr, "home-agent check failed category=%s\n", home.Category(err))
		return 1
	}
	if err := agent.Check(context.Background()); err != nil {
		fmt.Fprintf(stderr, "home-agent check failed category=%s\n", home.Category(err))
		return 1
	}
	fmt.Fprintln(stdout, "[OK] home-agent config and DNS identity verified")
	return 0
}

func parseConfigArgs(command string, args []string, stderr io.Writer) (string, int) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", "/usr/local/etc/aurora/home-agent.json", "root-owned configuration path")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(stderr, usage)
		return "", 64
	}
	return *configPath, 0
}

func loadAgent(configPath string) (*home.Agent, error) {
	config, err := home.LoadConfig(configPath)
	if err != nil {
		return nil, err
	}
	privateKey, err := home.LoadPrivateKey(config.PrivateKeyPath)
	if err != nil {
		return nil, err
	}
	return home.NewAgent(config, privateKey, &http.Client{}, nil)
}

func runKeygen(args []string, stdout io.Writer, stderr io.Writer) int {
	flags := flag.NewFlagSet("keygen", flag.ContinueOnError)
	flags.SetOutput(stderr)
	privatePath := flags.String("private", "", "PKCS#8 private-key output")
	publicPath := flags.String("public", "", "public metadata output")
	keyID := flags.String("key-id", "", "lease key identifier")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 ||
		*privatePath == "" || *publicPath == "" || !validKeyID(*keyID) {
		fmt.Fprintln(stderr, usage)
		return 64
	}
	if !filepath.IsAbs(*privatePath) || !filepath.IsAbs(*publicPath) || *privatePath == *publicPath {
		fmt.Fprintln(stderr, "keygen failed category=key_path_invalid")
		return 1
	}
	if _, err := os.Lstat(*privatePath); !os.IsNotExist(err) {
		fmt.Fprintln(stderr, "keygen failed category=key_exists")
		return 1
	}
	if _, err := os.Lstat(*publicPath); !os.IsNotExist(err) {
		fmt.Fprintln(stderr, "keygen failed category=key_exists")
		return 1
	}
	privatePEM, publicKey, err := lease.GenerateKeyPair(rand.Reader)
	if err != nil {
		fmt.Fprintln(stderr, "keygen failed category=key_generation_failed")
		return 1
	}
	metadata, err := json.MarshalIndent(struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"key_id"`
		PublicKey string `json:"public_key"`
	}{
		Algorithm: "ed25519",
		KeyID:     *keyID,
		PublicKey: base64.StdEncoding.EncodeToString(ed25519.PublicKey(publicKey)),
	}, "", "  ")
	if err != nil {
		fmt.Fprintln(stderr, "keygen failed category=key_generation_failed")
		return 1
	}
	metadata = append(metadata, '\n')
	if err := writeExclusive(*privatePath, privatePEM, 0o600); err != nil {
		fmt.Fprintln(stderr, "keygen failed category=key_write_failed")
		return 1
	}
	if err := writeExclusive(*publicPath, metadata, 0o644); err != nil {
		_ = os.Remove(*privatePath)
		fmt.Fprintln(stderr, "keygen failed category=key_write_failed")
		return 1
	}
	fmt.Fprintln(stdout, "[OK] home-agent lease key generated")
	return 0
}

func writeExclusive(path string, content []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	cleanup := func() {
		file.Close()
		_ = os.Remove(path)
	}
	if _, err := file.Write(content); err != nil {
		cleanup()
		return err
	}
	if err := file.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

func validKeyID(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for index, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			(index > 0 && (character == '.' || character == '_' || character == '-')) {
			continue
		}
		return false
	}
	return true
}
