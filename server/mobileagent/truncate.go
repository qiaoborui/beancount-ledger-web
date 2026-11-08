package mobileagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

type truncateRequestV1 struct {
	Version    int    `json:"version"`
	Transcript string `json:"transcript"`
	// KeepUserTurns is how many of the user's questions stay, with all the
	// model and tools did for each.
	KeepUserTurns int `json:"keepUserTurns"`
}

type truncateResponseV1 struct {
	Version    int    `json:"version"`
	OK         bool   `json:"ok"`
	Transcript string `json:"transcript,omitempty"`
	// UserTurns is how many questions the given transcript holds.
	UserTurns int    `json:"userTurns"`
	Error     string `json:"error,omitempty"`
}

// TruncateTranscriptJSON cuts a transcript back to its first keepUserTurns
// questions, for the shell to regenerate an answer or ask an edited
// question: it keeps the system message and everything up to the next
// question, so a tool call never loses its result. The prompts the loop adds
// on its own are part of the turn they follow, not questions.
func TruncateTranscriptJSON(requestJSON string) string {
	response, err := truncateTranscript(requestJSON)
	if err != nil {
		return encode(truncateResponseV1{Version: 1, Error: err.Error()})
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
	if request.KeepUserTurns < 0 {
		return truncateResponseV1{}, errors.New("keepUserTurns must not be negative")
	}
	messages, err := decodeTranscript(request.Transcript)
	if err != nil {
		return truncateResponseV1{}, fmt.Errorf("invalid transcript: %w", err)
	}
	head := 0
	for head < len(messages) && messages[head].System != nil {
		head++
	}
	cut, turns := len(messages), 0
	for index := head; index < len(messages); index++ {
		if !isUserTurn(messages[index]) {
			continue
		}
		if turns == request.KeepUserTurns && cut == len(messages) {
			cut = index
		}
		turns++
	}
	if request.KeepUserTurns == 0 {
		cut = head
	}
	response := truncateResponseV1{Version: 1, OK: true, UserTurns: turns, Transcript: request.Transcript}
	if cut == len(messages) {
		return response, nil
	}
	if response.Transcript, err = encodeTranscript(messages[:cut]); err != nil {
		return truncateResponseV1{}, err
	}
	return response, nil
}

// isUserTurn reports a question of the user's, as opposed to a prompt the
// loop added. A system note the shell puts before a question is part of it.
func isUserTurn(message agent.AgentMessage) bool {
	if message.User == nil {
		return false
	}
	text := strings.TrimSpace(userText(message.User.Content))
	return text != nudgeEmptyReply && text != nudgeToolBudget
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
