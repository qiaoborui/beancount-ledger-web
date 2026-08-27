import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(new URL("./LedgerEditorPage.tsx", import.meta.url), "utf8");
const ledgerAppSource = readFileSync(new URL("../LedgerApp.tsx", import.meta.url), "utf8");
const styles = readFileSync(new URL("../../app/globals.css", import.meta.url), "utf8");

describe("LedgerEditorPage", () => {
  it("uses CodeMirror instead of rebuilding a highlighted document over a textarea", () => {
    expect(source).toContain("<CodeMirror");
    expect(source).toContain("StreamLanguage.define");
    expect(source).toContain("syntaxHighlighting(beancountHighlightStyle)");
    expect(source).not.toContain("<textarea");
    expect(source).not.toContain("renderHighlightedLines");
    expect(source).not.toContain("handleEditorScroll");
  });

  it("only computes the working-copy diff while the diff view is active", () => {
    expect(source).toContain('mode === "diff" ? buildLineDiff(originalContent, editorValue) : []');
    expect(source).toContain("update.state.doc.lines");
    expect(source).toContain("update.state.doc.length");
  });

  it("keeps editing incremental and isolates undo history between loaded documents", () => {
    expect(source).toContain('key={`${selectedPath}:${editorGeneration}`}');
    expect(source).toContain("basicSetup={ledgerEditorBasicSetup}");
    expect(source).toContain("update.state.doc.eq(originalDocRef.current)");
    expect(source).toContain("originalDocRef.current = state.doc");
    expect(source).not.toContain("const nextContent = update.state.doc.toString()");
    expect(source).not.toContain("setContent(nextContent)");
  });

  it("does not let a stale save response overwrite later edits or another file", () => {
    expect(source).toContain("const savePath = selectedPath");
    expect(source).toContain("const saveGeneration = editorGenerationRef.current");
    expect(source).toContain("selectedPathRef.current === savePath && editorGenerationRef.current === saveGeneration");
    expect(source).toContain("updateDirty(currentDoc ? !currentDoc.eq(savedBaseline) : false)");
    expect(source).not.toContain("setEditorValue(nextContent)");
  });

  it("keeps file loads and saves mutually exclusive", () => {
    expect(source).toContain("if (!path || loadingFileRef.current || savingRef.current) return");
    expect(source).toContain("if (!selectedPath || loadingFileRef.current || savingRef.current) return");
  });

  it("owns the desktop workspace height and exposes editor status outside the toolbar", () => {
    expect(ledgerAppSource).toContain('page === "editor" ? "ledger-workspace-content-editor" : ""');
    expect(styles).toContain(".ledger-workspace-content-editor");
    expect(styles).toContain("height: 100dvh;");
    expect(source).toContain("ledger-editor-statusbar");
    expect(source).not.toContain("min-h-[calc(100dvh-13rem)]");
  });
});
