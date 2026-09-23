package main

import (
	"bytes"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const debounceDelay = 5 * time.Second

type Builder struct {
	targetName string
	srcDir     string
	distDir    string
	outputFile string
	entryPoint string
	globalVars []string
	functions  map[string]string
}

func NewBuilder(target string) (*Builder, error) {
	targetName := strings.TrimSuffix(target, "/")
	srcDir := filepath.Join(targetName, "src")
	entryPoint := filepath.Join(srcDir, "main.sh")

	if _, err := os.Stat(entryPoint); os.IsNotExist(err) {
		return nil, fmt.Errorf("entry point not found at '%s'", entryPoint)
	}

	distDir := filepath.Join(targetName, "dist")
	outputFile := filepath.Join(distDir, targetName+"_setup.sh")

	return &Builder{
		targetName: targetName,
		srcDir:     srcDir,
		distDir:    distDir,
		outputFile: outputFile,
		entryPoint: entryPoint,
		globalVars: make([]string, 0),
		functions:  make(map[string]string),
	}, nil
}

func main() {
	watchFlag := flag.Bool("watch", false, "Enable watch mode for target directory")
	flag.Parse()

	args := flag.Args()
	if len(args) < 1 {
		fmt.Println("❌ Error: Missing target project directory (e.g. 'hub' or 'speaker')")
		fmt.Println("Usage: go run build.go [-watch] <target>")
		os.Exit(1)
	}

	target := args[0]
	builder, err := NewBuilder(target)
	if err != nil {
		fmt.Printf("❌ %v\n", err)
		os.Exit(1)
	}

	if err := runBuild(builder); err != nil {
		fmt.Printf("❌ Initial build failed: %v\n", err)
		if !*watchFlag {
			os.Exit(1)
		}
	}

	if *watchFlag {
		watchAndBuild(builder)
	}
}

func runBuild(b *Builder) error {
	fmt.Printf("🚀 Starting build process for target '%s'...\n", b.targetName)
	b.globalVars = make([]string, 0)
	b.functions = make(map[string]string)

	if err := os.MkdirAll(b.distDir, 0755); err != nil {
		return fmt.Errorf("create dist dir: %w", err)
	}

	rawContent, err := b.processIncludes(b.entryPoint)
	if err != nil {
		return fmt.Errorf("process includes: %w", err)
	}

	embeddedContent, err := b.processEmbeds(rawContent)
	if err != nil {
		return fmt.Errorf("process embeds: %w", err)
	}

	finalScript := b.refactorAndOptimize(embeddedContent)

	if err := validateBashSyntax(finalScript); err != nil {
		return fmt.Errorf("syntax validation: %w", err)
	}

	if err := os.WriteFile(b.outputFile, []byte(finalScript), 0755); err != nil {
		return fmt.Errorf("write output file: %w", err)
	}

	fmt.Printf("🎉 Output successfully generated: %s\n", b.outputFile)
	return nil
}

func (b *Builder) processIncludes(filePath string) (string, error) {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file %s: %w", filePath, err)
	}

	includeRegex := regexp.MustCompile(`#\s*@include\s+(.+)`)
	result := includeRegex.ReplaceAllStringFunc(string(content), func(match string) string {
		subMatches := includeRegex.FindStringSubmatch(match)
		if len(subMatches) < 2 {
			return match
		}
		targetPath := filepath.Join(b.srcDir, strings.TrimSpace(subMatches[1]))
		resolved, err := b.processIncludes(targetPath)
		if err != nil {
			fmt.Printf("⚠️ Warning: Failed to include %s: %v\n", targetPath, err)
			return ""
		}
		return resolved
	})

	return result, nil
}

func (b *Builder) processEmbeds(content string) (string, error) {
	embedRegex := regexp.MustCompile(`#\s*@embed_file\s+(\S+)\s+(.+)`)
	var embedErr error

	result := embedRegex.ReplaceAllStringFunc(content, func(match string) string {
		subMatches := embedRegex.FindStringSubmatch(match)
		if len(subMatches) < 3 {
			return match
		}

		sourceRelPath := strings.TrimSpace(subMatches[1])
		targetPath := strings.Trim(strings.TrimSpace(subMatches[2]), "\"'")
		fullSourcePath := filepath.Join(b.srcDir, sourceRelPath)

		code, err := os.ReadFile(fullSourcePath)
		if err != nil {
			embedErr = fmt.Errorf("embedded file missing: %s", fullSourcePath)
			return match
		}

		ext := strings.ToLower(filepath.Ext(fullSourcePath))
		if ext == ".wav" || ext == ".mp3" || ext == ".bin" {
			encoded := base64.StdEncoding.EncodeToString(code)
			return fmt.Sprintf("base64 -d > %q <<'EOF'\n%s\nEOF", targetPath, encoded)
		}

		textContent := string(code)
		if !strings.HasSuffix(textContent, "\n") {
			textContent += "\n"
		}

		return fmt.Sprintf("cat > %q <<'EOF'\n%sEOF", targetPath, textContent)
	})

	return result, embedErr
}

func (b *Builder) refactorAndOptimize(content string) string {
	heredocRegex := regexp.MustCompile(`(?s)# __HEREDOC_START__.*?# __HEREDOC_END__`)
	heredocs := heredocRegex.FindAllString(content, -1)

	maskedContent := heredocRegex.ReplaceAllStringFunc(content, func(match string) string {
		return fmt.Sprintf("__HEREDOC_PLACEHOLDER_%d__", len(heredocs)-1)
	})

	lines := strings.Split(maskedContent, "\n")
	var mainBody []string
	shebang := "#!/bin/bash"

	funcHeaderRegex := regexp.MustCompile(`^(?:function\s+)?([a-zA-Z0-9_]+)\s*\(\)\s*\{`)
	varNameRegex := regexp.MustCompile(`^([A-Z0-9_]+)=([^\n]+)$`)
	commandSubstitutionRegex := regexp.MustCompile(`=\$\(`)

	inFunction := false
	currentFuncName := ""
	var currentFuncBody []string
	braceDepth := 0

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if strings.HasPrefix(trimmed, "#!") {
			continue
		}

		if !inFunction && funcHeaderRegex.MatchString(trimmed) {
			matches := funcHeaderRegex.FindStringSubmatch(trimmed)
			inFunction = true
			currentFuncName = matches[1]
			currentFuncBody = []string{}

			// Pull preceding comments and blank lines attached to this function out of mainBody
			var commentStack []string
			for len(mainBody) > 0 {
				lastIdx := len(mainBody) - 1
				lastLine := strings.TrimSpace(mainBody[lastIdx])
				if strings.HasPrefix(lastLine, "#") || lastLine == "" {
					if strings.HasPrefix(lastLine, "#") {
						commentStack = append([]string{mainBody[lastIdx]}, commentStack...)
					}
					mainBody = mainBody[:lastIdx]
				} else {
					break
				}
			}
			currentFuncBody = append(currentFuncBody, commentStack...)
			currentFuncBody = append(currentFuncBody, line)

			braceDepth = strings.Count(trimmed, "{") - strings.Count(trimmed, "}")
			if braceDepth <= 0 {
				b.functions[currentFuncName] = strings.Join(currentFuncBody, "\n")
				inFunction = false
			}
			continue
		}

		if inFunction {
			currentFuncBody = append(currentFuncBody, line)
			braceDepth += strings.Count(trimmed, "{") - strings.Count(trimmed, "}")
			if braceDepth <= 0 {
				b.functions[currentFuncName] = strings.Join(currentFuncBody, "\n")
				inFunction = false
			}
			continue
		}

		if varNameRegex.MatchString(trimmed) && !strings.HasPrefix(line, " ") && !commandSubstitutionRegex.MatchString(trimmed) {
			if !contains(b.globalVars, trimmed) {
				b.globalVars = append(b.globalVars, trimmed)
			}
			continue
		}

		mainBody = append(mainBody, line)
	}

	var builder strings.Builder
	builder.WriteString(shebang + "\nset -euo pipefail\n\n")

	if len(b.globalVars) > 0 {
		builder.WriteString("# ===========================================================================\n")
		builder.WriteString("# GLOBAL CONFIGURATION & CONSTANTS (Auto-Hoisted)\n")
		builder.WriteString("# ===========================================================================\n")
		for _, v := range b.globalVars {
			builder.WriteString(v + "\n")
		}
		builder.WriteString("\n")
	}

	if len(b.functions) > 0 {
		builder.WriteString("# ===========================================================================\n")
		builder.WriteString("# HELPER FUNCTIONS (Alphabetically Sorted)\n")
		builder.WriteString("# ===========================================================================\n")

		var funcNames []string
		for name := range b.functions {
			funcNames = append(funcNames, name)
		}
		sort.Strings(funcNames)

		for _, name := range funcNames {
			builder.WriteString(b.functions[name] + "\n\n")
		}
	}

	builder.WriteString("# ===========================================================================\n")
	builder.WriteString("# MAIN EXECUTION FLOW\n")
	builder.WriteString("# ===========================================================================\n")
	builder.WriteString(strings.Join(mainBody, "\n"))

	result := builder.String()

	// Restore embedded heredocs
	for i, hdoc := range heredocs {
		cleanHdoc := regexp.MustCompile(`(?m)^# __HEREDOC_(START|END)__\r?\n?`).ReplaceAllString(hdoc, "")
		result = strings.Replace(result, fmt.Sprintf("__HEREDOC_PLACEHOLDER_%d__", i), cleanHdoc, 1)
	}

	// Collapse 3 or more consecutive newlines down to 2 (single empty line)
	multiNewlineRegex := regexp.MustCompile(`\n{3,}`)
	result = multiNewlineRegex.ReplaceAllString(result, "\n\n")

	return result
}

func validateBashSyntax(content string) error {
	cmd := exec.Command("bash", "-n")
	cmd.Stdin = bytes.NewBufferString(content)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%v: %s", err, stderr.String())
	}
	return nil
}

func watchAndBuild(builder *Builder) {
	fmt.Printf("👀 Watch mode active for '%s'. Monitoring '%s' for changes (5s debounce)...\n", builder.targetName, builder.srcDir)

	changeChan := make(chan struct{}, 1)

	go func() {
		lastSnapshot := getDirSnapshot(builder.srcDir)
		for {
			time.Sleep(500 * time.Millisecond)
			currentSnapshot := getDirSnapshot(builder.srcDir)
			if !snapshotsEqual(lastSnapshot, currentSnapshot) {
				lastSnapshot = currentSnapshot
				select {
				case changeChan <- struct{}{}:
				default:
				}
			}
		}
	}()

	var debounceTimer *time.Timer
	var mu sync.Mutex

	for range changeChan {
		fmt.Printf("⚡ Change detected in '%s'. Waiting 5 seconds before rebuilding...\n", builder.srcDir)
		mu.Lock()
		if debounceTimer != nil {
			debounceTimer.Stop()
		}
		debounceTimer = time.AfterFunc(debounceDelay, func() {
			fmt.Printf("🔄 Triggering automatic rebuild for '%s'...\n", builder.targetName)
			if err := runBuild(builder); err != nil {
				fmt.Printf("❌ Rebuild failed: %v\n", err)
			}
		})
		mu.Unlock()
	}
}

func getDirSnapshot(dir string) map[string]time.Time {
	snapshot := make(map[string]time.Time)
	_ = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			snapshot[path] = info.ModTime()
		}
		return nil
	})
	return snapshot
}

func snapshotsEqual(a, b map[string]time.Time) bool {
	if len(a) != len(b) {
		return false
	}
	for k, vA := range a {
		vB, ok := b[k]
		if !ok || !vA.Equal(vB) {
			return false
		}
	}
	return true
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
