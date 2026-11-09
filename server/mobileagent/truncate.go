package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// truncateRequestV1 names the cut by exactly one of KeepUserTurns and
// DropUserTurns. Both count the questions the transcript itself holds, which
// are not always the ones the shell shows: a long transcript loses its oldest
// turns, and a question that failed, or was stopped before anything came
// back, was never recorded. DropUserTurns counts from the end, so trimming
// the front does not move it; the shell passes how many recorded questions
// there are from the one it regenerates or edits to the last.
type truncateRequestV1 struct {
	Version    int    `json:"version"`
	Transcript string `json:"transcript"`
	// KeepUserTurns is how many of the first questions stay, with all the
	// model and tools did for each.
	KeepUserTurns *int `json:"keepUserTurns,omitempty"`
	// DropUserTurns is how many of the last questions go, with everything
	// after the first of them.
	DropUserTurns *int `json:"dropUserTurns,omitempty"`
}

type truncateResponseV1 struct {
	Version    int    `json:"version"`
	OK         bool   `json:"ok"`
	Transcript string `json:"transcript,omitempty"`
	// UserTurns is how many questions the given transcript holds, also when
	// the cut asked for more than that.
	UserTurns int    `json:"userTurns"`
	Error     string `json:"error,omitempty"`
}

// TruncateTranscriptJSON cuts a transcript back to a number of whole
// questions, for the shell to regenerate an answer or ask an edited
// question: it keeps the system message and everything up to the next
// question, so a tool call never loses its result. The prompts the loop adds
// on its own are part of the turn they follow, not questions, and so is the
// summary a compaction put in place of older turns: it stays with the first
// question after it, and also when every question is cut, since it stands
// for questions the shell can no longer cut. A cut past the questions the
// transcript holds fails rather than keep a turn the shell meant to drop.
func TruncateTranscriptJSON(requestJSON string) string {
	response, err := truncateTranscript(requestJSON)
	if err != nil {
		return encode(truncateResponseV1{Version: 1, UserTurns: response.UserTurns, Error: err.Error()})
	}
	return encode(response)
}

func truncateTranscript(requestJSON string) (truncateResponseV1, error) {
	decoder := json.NewDecoder(strings.NewReader(requestJSON))
	decoder.DisallowUnknownFields()
	var request truncateRequestV1
	if err := decoder.Decode(&request); err != nil {
		return truncateResponseV1{}, fmt.Errorf("invalid truncate request: %w", err)
	}
	if request.Version != 1 {
		return truncateResponseV1{}, errors.New("supported truncate request version is 1")
	}
	if (request.KeepUserTurns == nil) == (request.DropUserTurns == nil) {
		return truncateResponseV1{}, errors.New("give exactly one of keepUserTurns and dropUserTurns")
	}
	if (request.KeepUserTurns != nil && *request.KeepUserTurns < 0) || (request.DropUserTurns != nil && *request.DropUserTurns < 0) {
		return truncateResponseV1{}, errors.New("keepUserTurns and dropUserTurns must not be negative")
	}
	messages, err := decodeTranscript(request.Transcript)
	if err != nil {
		return truncateResponseV1{}, fmt.Errorf("invalid transcript: %w", err)
	}
	head := 0
	for head < len(messages) && messages[head].System != nil {
		head++
	}
	var starts []int
	for index := head; index < len(messages); index++ {
		if isUserTurn(messages[index]) {
			starts = append(starts, index)
		}
	}
	turns := len(starts)
	keep := turns
	if request.KeepUserTurns != nil {
		keep = *request.KeepUserTurns
	} else {
		keep = turns - *request.DropUserTurns
	}
	if keep < 0 || keep > turns {
		return truncateResponseV1{UserTurns: turns}, fmt.Errorf("the transcript holds %d user turns", turns)
	}
	response := truncateResponseV1{Version: 1, OK: true, UserTurns: turns, Transcript: request.Transcript}
	if keep == turns {
		return response, nil
	}
	cut := compactionEnd(messages, head)
	if keep > 0 {
		cut = starts[keep]
	}
	if response.Transcript, err = encodeTranscript(messages[:cut]); err != nil {
		return truncateResponseV1{}, err
	}
	return response, nil
}

// isUserTurn reports a question of the user's, as opposed to a prompt the
// loop added or the summary of a compaction (see compactionMarker). A system
// note the shell puts before a question is part of it. Truncation and
// compaction count questions with it.
func isUserTurn(message agent.AgentMessage) bool {
	if message.User == nil {
		return false
	}
	text := strings.TrimSpace(userText(message.User.Content))
	return text != nudgeEmptyReply && text != nudgeToolBudget && !strings.HasPrefix(text, compactionMarker)
}

func userText(content ai.UserContent) string {
	switch content := content.(type) {
	case ai.UserText:
		return string(content)
	case ai.UserContentBlocks:
		var parts []string
		for _, block := range content {
			if text, ok := block.(ai.TextContent); ok {
				parts = append(parts, text.Text)
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}
