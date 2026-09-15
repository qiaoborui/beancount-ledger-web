package mobilecore

import (
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

const (
	maxActiveScopes        = 256
	maxInheritedFields     = 100_000
	maxInheritedBytes      = 8 << 20
	maxScopeComparisonWork = 1_000_000
)

// The parser copies active metadata and tags onto later entries. Bound that
// amplification before parsing: the request/output byte caps alone cannot bound
// map allocations or the parser's linear tag deduplication work.
func validateScopeLimits(lines []ledgercore.Line) *diagnosticV1 {
	metadata, tags := map[string]int{}, map[string]int{}
	scopeBytes, inheritedFields, inheritedBytes, comparisonWork := 0, 0, 0, 0
	for _, line := range lines {
		if ledgercore.IsIndentedBeanLine(line.Text) {
			continue
		}
		tokens := ledgercore.ScanBeanLine(line.Text)
		if len(tokens) == 0 {
			continue
		}
		switch tokens[0].Value {
		case "pushmeta":
			// Count conservatively from tokens without evaluating metadata's
			// numeric expressions during the resource preflight.
			if len(tokens) >= 3 && strings.HasSuffix(tokens[1].Value, ":") {
				key := strings.TrimSuffix(tokens[1].Value, ":")
				weight := len(line.Text) * 6 // JSON escaping upper bound.
				scopeBytes += weight - metadata[key]
				metadata[key] = weight
			}
		case "popmeta":
			if len(tokens) >= 2 && strings.HasSuffix(tokens[1].Value, ":") {
				key := strings.TrimSuffix(tokens[1].Value, ":")
				scopeBytes -= metadata[key]
				delete(metadata, key)
			}
		case "pushtag", "poptag":
			if len(tokens) >= 2 && tokens[1].Kind == ledgercore.TokenTag {
				key := tokens[1].Value
				comparisonWork += len(tags)
				weight := 0
				if tokens[0].Value == "pushtag" {
					weight = len(key) * 6
				}
				scopeBytes += weight - tags[key]
				if weight == 0 {
					delete(tags, key)
				} else {
					tags[key] = weight
				}
			}
		default:
			if ledgercore.IsBeanDateToken(tokens[0].Value) {
				inheritedFields += len(metadata) + len(tags)
				inheritedBytes += scopeBytes
				comparisonWork += len(tags) * (len(tags) + len(tokens))
			}
		}
		if len(metadata)+len(tags) > maxActiveScopes || inheritedFields > maxInheritedFields ||
			inheritedBytes > maxInheritedBytes || comparisonWork > maxScopeComparisonWork {
			return limitDiagnostic("request.scope_expansion_too_large", "active metadata or tag expansion exceeds the mobile resource budget", line.File, line.Line)
		}
	}
	return nil
}
