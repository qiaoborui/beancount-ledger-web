package agentmemory

import "strings"

// Merge is the three-way merge of a memory folder, per file, against base,
// the folder both sides last agreed on:
//   - changed on one side only: that side wins, a deletion included;
//   - deleted on one side and changed on the other: the change is kept;
//   - changed on both: the file is merged line by line (MergeLines).
func Merge(base, local, remote Snapshot) Snapshot {
	merged := Snapshot{}
	paths := map[string]bool{}
	for _, side := range []Snapshot{base, local, remote} {
		for path := range side {
			paths[path] = true
		}
	}
	for path := range paths {
		b, inBase := base[path]
		l, inLocal := local[path]
		r, inRemote := remote[path]
		switch {
		case inLocal == inRemote && l == r:
			if inLocal {
				merged[path] = l
			}
		case inLocal == inBase && l == b:
			if inRemote {
				merged[path] = r
			}
		case inRemote == inBase && r == b:
			if inLocal {
				merged[path] = l
			}
		case !inLocal:
			merged[path] = r
		case !inRemote:
			merged[path] = l
		default:
			merged[path] = MergeLines(b, l, r)
		}
	}
	return merged
}

// MergeLines merges one file, one fact per line: lines the remote side
// removed go, lines it added are kept next to the line they followed there
// (or at the end), and the local side's own edits stay as they are. It is
// the rule the iCloud sync of the app uses for the same files.
func MergeLines(base, local, remote string) string {
	lines := func(text string) []string {
		parts := strings.Split(strings.ReplaceAll(text, "\r", ""), "\n")
		for index, part := range parts {
			parts[index] = strings.TrimRight(part, " \t")
		}
		return parts
	}
	baseLines, remoteLines := lines(base), lines(remote)
	inBase := map[string]bool{}
	for _, line := range baseLines {
		inBase[line] = true
	}
	inRemote := map[string]bool{}
	for _, line := range remoteLines {
		inRemote[line] = true
	}
	var result []string
	for _, line := range lines(local) {
		// A line the remote side removed goes; structural lines such as the
		// front matter fences stay.
		if line != "" && inBase[line] && !inRemote[line] && !structural(line) {
			continue
		}
		result = append(result, line)
	}
	contains := func(line string) int {
		for index := len(result) - 1; index >= 0; index-- {
			if result[index] == line {
				return index
			}
		}
		return -1
	}
	for index, line := range remoteLines {
		if line == "" || inBase[line] || contains(line) >= 0 {
			continue
		}
		insertAt := len(result)
		for previous := index - 1; previous >= 0; previous-- {
			if remoteLines[previous] == "" {
				continue
			}
			if found := nth(result, remoteLines[previous], occurrence(remoteLines[:previous+1], remoteLines[previous])); found >= 0 {
				insertAt = found + 1
				break
			}
		}
		// Keep a trailing blank line after the text, not before the line.
		if insertAt == len(result) {
			for insertAt > 0 && result[insertAt-1] == "" {
				insertAt--
			}
		}
		result = append(result, "")
		copy(result[insertAt+1:], result[insertAt:])
		result[insertAt] = line
	}
	for len(result) > 0 && result[len(result)-1] == "" {
		result = result[:len(result)-1]
	}
	for len(result) > 0 && result[0] == "" {
		result = result[1:]
	}
	if len(result) == 0 {
		return ""
	}
	return strings.Join(result, "\n") + "\n"
}

// occurrence is which occurrence of line the last element of lines is,
// counted from 1, so a repeated anchor such as "---" finds its own copy.
func occurrence(lines []string, line string) int {
	count := 0
	for _, each := range lines {
		if each == line {
			count++
		}
	}
	return count
}

// nth is the index of the n-th occurrence of line, else its last one.
func nth(lines []string, line string, n int) int {
	last := -1
	for index, each := range lines {
		if each == line {
			last = index
			if n--; n == 0 {
				return index
			}
		}
	}
	return last
}

func structural(line string) bool {
	return line == "---"
}
