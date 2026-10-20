package ledgercore

import "strings"

// SourceSegments is ParseLines with transaction bodies left unparsed. Every
// other directive is parsed exactly as ParseLines parses it. A transaction
// entry carries only its source locator (Kind, File, Line, Date, Flag) and its
// exact RawLines; Deferred recovers the full parse on demand.
type SourceSegments struct {
	Entries  []BeanEntry
	Deferred []DeferredTransaction
}

// DeferredTransaction is one transaction block whose full parse was skipped.
// Index is its position in SourceSegments.Entries (and in ParseLines output).
type DeferredTransaction struct {
	Index    int
	File     string
	Line     int
	RawLines []string
	scope    *segmentScope
}

// segmentScope is an immutable copy of the pushtag/pushmeta state active at a
// transaction, so a deferred parse applies exactly what ParseLines applied.
type segmentScope struct {
	tags []string
	meta map[string]MetadataValue
}

// SegmentLines walks lines with the same block rules as ParseLines. Parse
// errors are not reported: callers use it on already validated sources.
func SegmentLines(lines []BeanLine) SourceSegments {
	p := beanLineParser{lines: lines, activeMeta: map[string]MetadataValue{}}
	var scope *segmentScope
	result := SourceSegments{Entries: []BeanEntry{}}
	for i := 0; i < len(lines); {
		line := lines[i]
		trimmed := strings.TrimSpace(line.Text)
		if trimmed == "" || strings.HasPrefix(trimmed, ";") || isIndentedBeanLine(line.Text) {
			i++
			continue
		}
		tokens := scanBeanLine(trimmed)
		if len(tokens) == 0 {
			i++
			continue
		}
		if !isBeanDateToken(tokens[0].Value) {
			if entry, ok := p.parseGlobalDirective(line, tokens); ok {
				result.Entries = append(result.Entries, entry)
				switch entry.Kind {
				case "pushtag", "poptag", "pushmeta", "popmeta":
					scope = snapshotSegmentScope(&p)
				}
			}
			i++
			continue
		}
		if len(tokens) < 2 {
			i++
			continue
		}
		blockEnd := i + 1
		for blockEnd < len(lines) {
			next := lines[blockEnd]
			nextTrimmed := strings.TrimSpace(next.Text)
			if nextTrimmed == "" || strings.HasPrefix(nextTrimmed, ";") || isIndentedBeanLine(next.Text) {
				blockEnd++
				continue
			}
			break
		}
		if isTransactionFlag(tokens[1].Value) {
			// parseEntry accepts every transaction header, so the locator below is
			// exactly the entry ParseLines would emit at this position.
			flag := tokens[1].Value
			if flag == "txn" {
				flag = "*"
			}
			raw := beanLineTexts(lines[i:blockEnd])
			result.Deferred = append(result.Deferred, DeferredTransaction{
				Index: len(result.Entries), File: line.File, Line: line.Line, RawLines: raw, scope: scope,
			})
			result.Entries = append(result.Entries, BeanEntry{
				Kind: "transaction", Date: normalizeBeanDate(tokens[0].Value), Flag: flag,
				File: line.File, Line: line.Line, RawLines: raw,
			})
		} else if entry, ok := p.parseEntry(linesBlock(lines[i:blockEnd])); ok {
			p.applyActiveScopes(&entry)
			result.Entries = append(result.Entries, entry)
		}
		i = blockEnd
	}
	return result
}

func snapshotSegmentScope(p *beanLineParser) *segmentScope {
	if len(p.activeTags) == 0 && len(p.activeMeta) == 0 {
		return nil
	}
	scope := &segmentScope{tags: append([]string(nil), p.activeTags...), meta: make(map[string]MetadataValue, len(p.activeMeta))}
	for key, value := range p.activeMeta {
		scope.meta[key] = value
	}
	return scope
}

// Parse returns the entry ParseLines produced for this transaction. Body line
// numbers only label parse errors, so the block is rebuilt from the header
// line even when the raw block spans an include boundary.
func (d DeferredTransaction) Parse() BeanEntry {
	block := make([]BeanLine, len(d.RawLines))
	for i, text := range d.RawLines {
		block[i] = BeanLine{File: d.File, Line: d.Line + i, Text: text}
	}
	p := beanLineParser{activeMeta: map[string]MetadataValue{}}
	if d.scope != nil {
		p.activeTags = d.scope.tags
		p.activeMeta = d.scope.meta
	}
	entry, _ := p.parseEntry(block)
	p.applyActiveScopes(&entry)
	entry.RawLines = d.RawLines
	return entry
}
