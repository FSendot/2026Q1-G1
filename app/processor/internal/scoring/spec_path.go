package scoring

import (
	"fmt"
	"os"
	"path/filepath"
)

const (
	runtimeSpecEnvVar   = "FRAUD_RUNTIME_SPEC_PATH"
	runtimeSpecFilename = "runtime_spec.json"
)

// ResolveRuntimeSpecPath locates the ML runtime spec used by the SQS worker.
func ResolveRuntimeSpecPath() (string, error) {
	if envPath := os.Getenv(runtimeSpecEnvVar); envPath != "" {
		if _, err := os.Stat(envPath); err != nil {
			return "", fmt.Errorf("%s points to an unreadable file: %w", runtimeSpecEnvVar, err)
		}
		return filepath.Abs(envPath)
	}

	candidates := append([]string{}, candidateRuntimeSpecPaths()...)
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, runtimeSpecPathsFromRoot(cwd)...)
	}

	for _, candidate := range candidates {
		absPath, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		if _, err := os.Stat(absPath); err == nil {
			return absPath, nil
		}
	}

	return "", fmt.Errorf("runtime spec not found; set %s or place runtime_spec.json in a standard repo path", runtimeSpecEnvVar)
}

func candidateRuntimeSpecPaths() []string {
	return []string{
		filepath.Join("model", runtimeSpecFilename),
		filepath.Join("processor", "model", runtimeSpecFilename),
		filepath.Join("..", "net", "outputs", "go_runtime", "model_v1", runtimeSpecFilename),
		filepath.Join("net", "outputs", "go_runtime", "model_v1", runtimeSpecFilename),
	}
}

func runtimeSpecPathsFromRoot(start string) []string {
	var candidates []string
	current := start
	for {
		candidates = append(candidates, filepath.Join(current, "model", runtimeSpecFilename))
		candidates = append(candidates, filepath.Join(current, "processor", "model", runtimeSpecFilename))
		candidates = append(candidates, filepath.Join(current, "net", "outputs", "go_runtime", "model_v1", runtimeSpecFilename))
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		current = parent
	}
	return candidates
}
