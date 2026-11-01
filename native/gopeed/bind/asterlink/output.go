package gopeed

import (
	"errors"
	"path/filepath"

	"github.com/GopeedLab/gopeed/internal/outputfile"
	"github.com/GopeedLab/gopeed/pkg/download"
)

const outputKeyLabel = outputfile.KeyLabel

func validateOutput(input request) error {
	if (input.OutputPath == "") != (input.OutputKey == "") {
		return errors.New("direct output path and key must be supplied together")
	}
	if input.OutputPath != "" && !filepath.IsAbs(input.OutputPath) {
		return errors.New("direct output path must be absolute")
	}
	return nil
}

func outputMatches(task *download.Task, input request) bool {
	return task.Meta != nil && task.Meta.Req != nil &&
		task.Meta.Req.Labels[outputKeyLabel] == input.OutputKey
}

func bindOutput(input request, logical string) error {
	if input.OutputPath == "" {
		outputfile.Remove(input.ID)
		return nil
	}
	return outputfile.Bind(input.ID, logical, input.OutputPath)
}

func snapshotOutputPath(task *download.Task, logical string) string {
	if task.Meta.Req.Labels[outputKeyLabel] == "" {
		return logical
	}
	if target, bound := outputfile.Path(logical); bound {
		return target
	}
	// A restored task has no live lease until Android supplies a new binding.
	return ""
}

// Capabilities lets Android distinguish this runtime from an older bundled AAR.
func Capabilities() string {
	return `{"directOutput":true,"directOutputFd":true,"taskCacheRoots":true,"sourceNetworkPolicy":true,"parserHttp2":true,"ed2k":true}`
}
