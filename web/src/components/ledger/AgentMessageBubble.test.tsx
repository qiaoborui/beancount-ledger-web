import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AgentMessageBubble } from "./AgentMessageBubble";

describe("AgentMessageBubble", () => {
  it("renders assistant Markdown through the shared Agent response component", () => {
    const html = renderToStaticMarkup(<AgentMessageBubble role="assistant" content={"**收入分类**\n\n- 工资\n- 红包"} />);

    expect(html).toContain('data-streamdown="strong"');
    expect(html).toContain('data-streamdown="unordered-list"');
    expect(html).toContain("工资");
  });

  it("keeps user messages as literal text", () => {
    const html = renderToStaticMarkup(<AgentMessageBubble role="user" content="**收入分类**" />);

    expect(html).toContain("**收入分类**");
    expect(html).not.toContain("<strong>");
  });
});
