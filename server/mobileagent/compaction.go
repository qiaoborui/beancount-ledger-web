package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// A transcript that nears the model's context window has its older turns
// replaced by a summary before the turn's first request. The summary is one
// user message that starts with compactionMarker; it is not a question, so
// truncation does not count it (see isUserTurn).
const (
	compactionMarker = "（系统提示：以下是之前对话的摘要，较早的消息已压缩）"
	// compactionNote follows the marker: the amounts in a summary were true
	// when they were read, not necessarily now.
	compactionNote = "摘要里的金额和余额是当时查询的结果，再用到之前请重新查询账本确认。"
	// compactionThreshold is the share of the context window the transcript
	// may fill before it is compacted.
	compactionThreshold = 0.75
	// assumedContextWindow is the window of a model nobody describes.
	assumedContextWindow = 128_000
	// A transcript needs compactionMinTurns questions before it is compacted;
	// the last compactionKeepTurns stay verbatim.
	compactionMinTurns  = 6
	compactionKeepTurns = 4
	// The summary is asked for in about 1500 characters; a reply longer than
	// maxSummaryRunes is cut.
	maxSummaryRunes = 2000
	// What the summary request is sent of the older turns: each piece is
	// bounded, and the whole keeps the first piece (an earlier summary, when
	// there is one) and as many of the latest as fit.
	maxSummarySourceBytes = 120_000
	maxSummaryToolArgs    = 300
	maxSummaryToolResult  = 800
)

// compactionTimeout bounds the summary request inside the turn; a summary
// that takes longer is given up for the byte trim. Tests shorten it.
var compactionTimeout = 60 * time.Second

const compactionPrompt = `你在为记账 App 里「账本助手」的一段长对话写摘要。摘要会替换掉较早的消息，助手之后只能靠它记起前面发生过什么，所以要准确、具体。

要求：
- 依次写清（没有的就省略）：
  1. 用户的目标和要办的事；
  2. 已经做出的决定和用户表达过的偏好（分类习惯、账户用法、叫法等）；
  3. 提到过的账户、分类、商户、日期范围和金额；
  4. 改账的情况：起草了哪些改动，哪些已经写入账本，哪些被放弃；
  5. 还没解决的问题和接下来要做的事。
- 金额照原样记下，并写明这些只是当时查询的结果，之后要用到时必须重新查询账本确认，不能直接引用。
- 只写对话里出现过的事实，不要编造，不要评论。
- 用中文分条列出，总共不超过 1500 个字。只输出摘要本身。`

// compactor summarizes the older turns of a transcript with the turn's own
// model, network and key.
type compactor struct {
	network *turnHTTP
	model   *ai.Model
	assumed bool
	key     string
	feed    *eventFeed
}

// compact returns messages with their older turns summarized and how many
// questions the summary replaced. Below the threshold, with too few
// questions, or when the summary fails, it returns messages unchanged and
// zero, so the prompt cache keeps its prefix and the byte trim takes over.
// The only error is the turn being stopped or out of time.
func (c compactor) compact(ctx context.Context, messages []agent.AgentMessage) ([]agent.AgentMessage, int, error) {
	if contextEstimate(messages) < int(float64(contextWindow(c.model, c.assumed))*compactionThreshold) {
		return messages, 0, nil
	}
	head, cut, turns, ok := compactionCut(messages)
	if !ok {
		return messages, 0, nil
	}
	c.feed.send(turnEventV1{Kind: "compaction_start"})
	summary, err := c.summarize(ctx, messages[head:cut])
	if ctx.Err() != nil {
		c.feed.send(turnEventV1{Kind: "compaction_end"})
		return messages, 0, ctx.Err()
	}
	if err != nil {
		// No summarizedTurns: the shell shows nothing was compacted.
		c.feed.send(turnEventV1{Kind: "compaction_end"})
		return messages, 0, nil
	}
	c.feed.send(turnEventV1{Kind: "compaction_end", SummarizedTurns: turns})
	return compactedMessages(messages, head, cut, summary), turns, nil
}

func (c compactor) summarize(ctx context.Context, older []agent.AgentMessage) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, compactionTimeout)
	defer cancel()
	reply, err := complete(ctx, c.network, c.model, c.assumed, c.key, compactionPrompt, summarySource(older))
	if err != nil {
		return "", err
	}
	summary := strings.TrimSpace(truncateRunes(strings.TrimSpace(reply), maxSummaryRunes))
	if summary == "" {
		return "", errors.New("模型没有写出摘要")
	}
	return summary, nil
}

// contextWindow is the window the threshold is a share of. A model whose
// abilities are assumed may have any window, so it gets a common one.
func contextWindow(model *ai.Model, assumed bool) int {
	if assumed || model.Capabilities.ContextWindow <= 0 {
		return assumedContextWindow
	}
	return model.Capabilities.ContextWindow
}

// contextEstimate is how many tokens the transcript holds: what the
// provider reported for its last model message, prompt and answer, or when
// that message has no usage, about a token per three encoded bytes.
func contextEstimate(messages []agent.AgentMessage) int {
	if assistant := lastAssistant(messages); assistant != nil && assistant.Usage != nil {
		usage := assistant.Usage
		if held := usage.Input + usage.CacheRead + usage.CacheWrite + usage.Output; held > 0 {
			return held
		}
	}
	raw, err := json.Marshal(messages)
	if err != nil {
		return 0
	}
	return len(raw) / 3
}

// compactionCut finds what a compaction replaces: messages[head:cut], from
// the end of the opening system messages to the first of the questions that
// stay. The cut is at a question, so a tool call never loses its result.
// turns is how many questions the replaced part holds; ok is false when the
// transcript has too few to compact.
func compactionCut(messages []agent.AgentMessage) (head, cut, turns int, ok bool) {
	for head < len(messages) && messages[head].System != nil {
		head++
	}
	var starts []int
	for index := head; index < len(messages); index++ {
		if isUserTurn(messages[index]) {
			starts = append(starts, index)
		}
	}
	if len(starts) < compactionMinTurns {
		return head, head, 0, false
	}
	turns = len(starts) - compactionKeepTurns
	return head, starts[turns], turns, true
}

// compactedMessages replaces messages[head:cut] with the summary. System
// messages in the replaced part carry tool declarations, which PiG replays
// from every system message in order, so they stay, ahead of the summary.
func compactedMessages(messages []agent.AgentMessage, head, cut int, summary string) []agent.AgentMessage {
	out := slices.Clone(messages[:head])
	for _, message := range messages[head:cut] {
		if message.System != nil {
			out = append(out, message)
		}
	}
	text := compactionMarker + "\n" + compactionNote + "\n\n" + summary
	out = append(out, agent.AgentMessage{User: &agent.UserMessage{Role: "user", Content: ai.UserText(text), Timestamp: time.Now().UnixMilli()}})
	return append(out, messages[cut:]...)
}

// isCompactionSummary reports the message a compaction left in place of the
// older turns.
func isCompactionSummary(message agent.AgentMessage) bool {
	return message.User != nil && strings.HasPrefix(strings.TrimSpace(userText(message.User.Content)), compactionMarker)
}

// summarySource is the older turns as text for the summary request: what
// the user and the model said, each tool call and the start of its result.
// Reasoning and the prompts the loop added are left out.
func summarySource(older []agent.AgentMessage) string {
	var pieces []string
	for _, message := range older {
		switch {
		case isCompactionSummary(message):
			text := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(userText(message.User.Content)), compactionMarker))
			text = strings.TrimSpace(strings.TrimPrefix(text, compactionNote))
			pieces = append(pieces, "更早对话的摘要：\n"+truncateRunes(text, maxSummaryRunes))
		case message.User != nil:
			if isUserTurn(message) {
				if text := strings.TrimSpace(userText(message.User.Content)); text != "" {
					pieces = append(pieces, "用户："+truncateRunes(text, maxAssistMessage))
				}
			}
		case message.Assistant != nil:
			if text := strings.TrimSpace(assistantText(message.Assistant.Content)); text != "" {
				pieces = append(pieces, "助手："+truncateRunes(text, maxAssistMessage))
			}
			for _, block := range message.Assistant.Content {
				if call, ok := block.(ai.ToolCall); ok {
					arguments, _ := json.Marshal(call.Arguments)
					pieces = append(pieces, fmt.Sprintf("助手调用工具 %s：%s", call.Name, truncateRunes(string(arguments), maxSummaryToolArgs)))
				}
			}
		case message.ToolResult != nil:
			label := "工具结果"
			if message.ToolResult.IsError {
				label = "工具出错"
			}
			text := strings.TrimSpace(toolResultText(message.ToolResult.Content))
			pieces = append(pieces, fmt.Sprintf("%s（%s）：%s", label, message.ToolResult.ToolName, truncateRunes(text, maxSummaryToolResult)))
		}
	}
	if len(pieces) == 0 {
		return "对话：\n\n（没有内容）"
	}
	kept, size := []string{}, len(pieces[0])
	for index := len(pieces) - 1; index > 0; index-- {
		if size+len(pieces[index]) > maxSummarySourceBytes {
			kept = append([]string{"……（中间省略）"}, kept...)
			break
		}
		size += len(pieces[index])
		kept = append([]string{pieces[index]}, kept...)
	}
	return "请为下面这段较早的对话写摘要。\n\n对话：\n\n" + strings.Join(append([]string{pieces[0]}, kept...), "\n\n")
}
