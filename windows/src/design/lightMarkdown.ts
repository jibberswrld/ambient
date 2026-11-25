// Light markdown: the subset a spoken assistant actually uses, split into blocks and inline spans for React to draw.
//
// `parseMarkdownBlocks` is a port of `AmbientLightMarkdownParser.blocks` in
// Packages/AmbientKit/Sources/AmbientUI/FlowBar/AmbientLightMarkdown.swift. Swift then hands each block's text to
// `AttributedString(markdown:)` with inline-only syntax; there is no such parser in the browser, so
// `parseInlineMarkdown` tokenises the inline syntax that Swift view styles (strong, emphasis, code, links) itself.
// `plainTextFromMarkdown` is `FlowBarTaskRow.plainText(fromMarkdown:)` from FlowBarTasks.swift.
//
// Everything here must tolerate text that is still streaming in: half-written markup is shown as the literal
// characters typed so far and never throws.

export type MarkdownBlock =
  | { kind: 'paragraph'; text: string }
  | { kind: 'heading'; text: string }
  /** `marker` is "•" for bullets or "3." for numbered items. */
  | { kind: 'listItem'; marker: string; text: string }
  | { kind: 'codeBlock'; text: string };

export type InlineSpan =
  | { kind: 'text'; text: string }
  | { kind: 'strong'; children: InlineSpan[] }
  | { kind: 'emphasis'; children: InlineSpan[] }
  | { kind: 'code'; text: string }
  | { kind: 'link'; href: string; children: InlineSpan[] };

// Blocks --------------------------------------------------------------------------------------------------------------

/** Swift's `CharacterSet.whitespaces`: spaces (Unicode Zs) and tab, but not line breaks. */
const leadingOrTrailingWhitespace = /^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu;

function trimWhitespace(text: string): string {
  return text.replace(leadingOrTrailingWhitespace, '');
}

/** Splits text into blocks. Tolerates text that is still streaming: an unclosed code fence is shown as code. */
export function parseMarkdownBlocks(markdownText: string): MarkdownBlock[] {
  const parsedBlocks: MarkdownBlock[] = [];
  let paragraphLines: string[] = [];
  let codeLines: string[] = [];
  let isInsideCodeFence = false;

  const flushParagraph = () => {
    const paragraphText = trimWhitespace(paragraphLines.join(' '));
    if (paragraphText.length > 0) parsedBlocks.push({ kind: 'paragraph', text: paragraphText });
    paragraphLines = [];
  };

  // Splitting on an optional carriage return as well as the newline keeps Windows line endings out of the text.
  for (const rawLine of markdownText.split(/\r?\n/)) {
    const trimmedLine = trimWhitespace(rawLine);
    if (trimmedLine.startsWith('```')) {
      if (isInsideCodeFence) {
        parsedBlocks.push({ kind: 'codeBlock', text: codeLines.join('\n') });
        codeLines = [];
      } else {
        flushParagraph();
      }
      isInsideCodeFence = !isInsideCodeFence;
      continue;
    }
    if (isInsideCodeFence) {
      codeLines.push(rawLine);
      continue;
    }
    if (trimmedLine.length === 0) {
      flushParagraph();
      continue;
    }
    const heading = headingText(trimmedLine);
    const bullet = heading === null ? bulletText(trimmedLine) : null;
    const numbered = heading === null && bullet === null ? numberedItem(trimmedLine) : null;
    if (heading !== null) {
      flushParagraph();
      parsedBlocks.push({ kind: 'heading', text: heading });
    } else if (bullet !== null) {
      flushParagraph();
      parsedBlocks.push({ kind: 'listItem', marker: '•', text: bullet });
    } else if (numbered !== null) {
      flushParagraph();
      parsedBlocks.push({ kind: 'listItem', marker: numbered.marker, text: numbered.text });
    } else {
      paragraphLines.push(trimmedLine);
    }
  }
  if (isInsideCodeFence && codeLines.length > 0) parsedBlocks.push({ kind: 'codeBlock', text: codeLines.join('\n') });
  flushParagraph();
  return parsedBlocks;
}

/** "## Title" gives "Title". The hashes must be followed by a space, so "#hashtag" stays a paragraph. */
function headingText(line: string): string | null {
  if (!line.startsWith('#')) return null;
  const withoutHashes = line.replace(/^#+/, '');
  if (!withoutHashes.startsWith(' ')) return null;
  return trimWhitespace(withoutHashes);
}

function bulletText(line: string): string | null {
  for (const bulletPrefix of ['- ', '* ', '• ']) {
    if (line.startsWith(bulletPrefix)) return line.slice(bulletPrefix.length);
  }
  return null;
}

/** "3. Text" or "3) Text", with at most three digits so a year at the start of a sentence is not a list. */
function numberedItem(line: string): { marker: string; text: string } | null {
  const leadingDigits = /^\p{N}+/u.exec(line)?.[0] ?? '';
  const digitCount = Array.from(leadingDigits).length;
  if (digitCount === 0 || digitCount > 3) return null;
  const remainder = line.slice(leadingDigits.length);
  if (!remainder.startsWith('. ') && !remainder.startsWith(') ')) return null;
  return { marker: `${leadingDigits}.`, text: remainder.slice(2) };
}

// Inline spans --------------------------------------------------------------------------------------------------------

/** Characters a backslash can escape, as in CommonMark: any ASCII punctuation. */
const escapablePunctuation = /[!-/:-@[-`{-~]/;
const letterOrDigit = /[\p{L}\p{N}]/u;
const whitespaceCharacter = /\s/u;

/**
 * Splits one block's text into styled spans: **strong** and __strong__, *emphasis* and _emphasis_, `code`, and
 * [label](url) links. An underscore only opens or closes at a word boundary, so snake_case stays text. Markers without
 * a partner stay as the literal characters.
 */
export function parseInlineMarkdown(text: string): InlineSpan[] {
  return new InlineMarkdownParser(text).parseSpans(0, text.length);
}

class InlineMarkdownParser {
  private readonly text: string;
  // Closer searches look ahead and skip nested spans, so the same opener is examined many times. Remembering each
  // answer keeps a long reply, or a pathological one full of unmatched markers, from going exponential.
  // Keys combine the opener index and the end of the range searched (see `searchKey`).
  private readonly emphasisMatchBySearch = new Map<number, EmphasisMatch | null>();
  private readonly codeSpanMatchBySearch = new Map<number, CodeSpanMatch | null>();

  constructor(text: string) {
    this.text = text;
  }

  /** One number per (opener index, end of searched range) pair; nested spans search shorter ranges than their parent. */
  private searchKey(openerIndex: number, endIndex: number): number {
    return openerIndex * (this.text.length + 1) + endIndex;
  }

  parseSpans(startIndex: number, endIndex: number): InlineSpan[] {
    const spans: InlineSpan[] = [];
    const appendText = (literalText: string) => {
      const lastSpan = spans[spans.length - 1];
      if (lastSpan !== undefined && lastSpan.kind === 'text') lastSpan.text += literalText;
      else spans.push({ kind: 'text', text: literalText });
    };

    let index = startIndex;
    while (index < endIndex) {
      const character = this.text[index];
      if (character === '\\' && index + 1 < endIndex && escapablePunctuation.test(this.text[index + 1])) {
        appendText(this.text[index + 1]);
        index += 2;
        continue;
      }
      if (character === '`') {
        const codeSpan = this.matchCodeSpan(index, endIndex);
        if (codeSpan !== null) {
          spans.push({ kind: 'code', text: codeSpan.content });
          index = codeSpan.endIndex;
        } else {
          // An unmatched run of backticks is literal as a whole, so "``" never half-opens a shorter span later.
          const runLength = this.runLength(index, endIndex);
          appendText(this.text.slice(index, index + runLength));
          index += runLength;
        }
        continue;
      }
      if (character === '[') {
        const link = this.matchLink(index, endIndex);
        if (link !== null) {
          spans.push({ kind: 'link', href: link.href, children: this.parseSpans(link.labelStartIndex, link.labelEndIndex) });
          index = link.endIndex;
          continue;
        }
      }
      if (character === '*' || character === '_') {
        const emphasis = this.matchEmphasis(index, endIndex);
        if (emphasis !== null) {
          const children = this.parseSpans(index + emphasis.delimiterLength, emphasis.closerIndex);
          spans.push(emphasis.delimiterLength === 2 ? { kind: 'strong', children } : { kind: 'emphasis', children });
          index = emphasis.closerIndex + emphasis.delimiterLength;
          continue;
        }
      }
      appendText(character);
      index += 1;
    }
    return spans;
  }

  // Code spans ------------------------------------------------------------------------------------------------------

  /** A run of N backticks closed by the next run of exactly N. One space just inside each end is padding, not content. */
  private matchCodeSpan(openerIndex: number, endIndex: number): CodeSpanMatch | null {
    const cacheKey = this.searchKey(openerIndex, endIndex);
    if (this.codeSpanMatchBySearch.has(cacheKey)) return this.codeSpanMatchBySearch.get(cacheKey) ?? null;
    const match = this.findCodeSpan(openerIndex, endIndex);
    this.codeSpanMatchBySearch.set(cacheKey, match);
    return match;
  }

  private findCodeSpan(openerIndex: number, endIndex: number): CodeSpanMatch | null {
    const openerLength = this.runLength(openerIndex, endIndex);
    let searchIndex = openerIndex + openerLength;
    while (searchIndex < endIndex) {
      if (this.text[searchIndex] !== '`') {
        searchIndex += 1;
        continue;
      }
      const closerLength = this.runLength(searchIndex, endIndex);
      if (closerLength === openerLength) {
        let content = this.text.slice(openerIndex + openerLength, searchIndex).replace(/\r?\n/g, ' ');
        if (content.length >= 2 && content.startsWith(' ') && content.endsWith(' ') && content.trim().length > 0) {
          content = content.slice(1, -1);
        }
        return { content, endIndex: searchIndex + closerLength };
      }
      searchIndex += closerLength;
    }
    return null;
  }

  // Links -----------------------------------------------------------------------------------------------------------

  /** `[label](destination)` or `[label](destination "title")`; the title is dropped. Brackets and parentheses may nest. */
  private matchLink(
    openerIndex: number,
    endIndex: number,
  ): { labelStartIndex: number; labelEndIndex: number; href: string; endIndex: number } | null {
    const labelEndIndex = this.findClosingBracket(openerIndex, endIndex, '[', ']');
    if (labelEndIndex === null || this.text[labelEndIndex + 1] !== '(') return null;
    const destinationStartIndex = labelEndIndex + 1;
    const destinationEndIndex = this.findClosingBracket(destinationStartIndex, endIndex, '(', ')');
    if (destinationEndIndex === null) return null;
    let destination = this.text.slice(destinationStartIndex + 1, destinationEndIndex).trim();
    if (destination.startsWith('<')) {
      const closingAngleIndex = destination.indexOf('>');
      destination = closingAngleIndex >= 0 ? destination.slice(1, closingAngleIndex) : destination;
    } else {
      destination = destination.split(/\s+/)[0] ?? '';
    }
    if (destination.length === 0) return null;
    return { labelStartIndex: openerIndex + 1, labelEndIndex, href: destination, endIndex: destinationEndIndex + 1 };
  }

  private findClosingBracket(openerIndex: number, endIndex: number, openingCharacter: string, closingCharacter: string): number | null {
    let nestingDepth = 0;
    let index = openerIndex;
    while (index < endIndex) {
      const character = this.text[index];
      if (character === '\\') {
        index += 2;
        continue;
      }
      if (character === '`') {
        // Brackets inside code are just code.
        const codeSpan = this.matchCodeSpan(index, endIndex);
        index = codeSpan !== null ? codeSpan.endIndex : index + this.runLength(index, endIndex);
        continue;
      }
      if (character === openingCharacter) nestingDepth += 1;
      if (character === closingCharacter) {
        nestingDepth -= 1;
        if (nestingDepth === 0) return index;
      }
      index += 1;
    }
    return null;
  }

  // Emphasis --------------------------------------------------------------------------------------------------------

  /**
   * Strong (a doubled delimiter) is tried before emphasis (a single one), so "**bold**" is strong and "***both***" is
   * strong around emphasis.
   */
  private matchEmphasis(openerIndex: number, endIndex: number): EmphasisMatch | null {
    const cacheKey = this.searchKey(openerIndex, endIndex);
    if (this.emphasisMatchBySearch.has(cacheKey)) return this.emphasisMatchBySearch.get(cacheKey) ?? null;
    const delimiterCharacter = this.text[openerIndex];
    let match: EmphasisMatch | null = null;
    if (this.canOpenEmphasis(openerIndex, endIndex)) {
      const runLength = this.runLength(openerIndex, endIndex);
      for (const delimiterLength of runLength >= 2 ? [2, 1] : [1]) {
        const closerIndex = this.findEmphasisCloser(openerIndex + delimiterLength, endIndex, delimiterCharacter, delimiterLength);
        if (closerIndex !== null) {
          match = { delimiterLength, closerIndex };
          break;
        }
      }
    }
    this.emphasisMatchBySearch.set(cacheKey, match);
    return match;
  }

  /** The index of the closing delimiter for an emphasis whose content starts at `contentStartIndex`, or null. */
  private findEmphasisCloser(contentStartIndex: number, endIndex: number, delimiterCharacter: string, delimiterLength: number): number | null {
    let index = contentStartIndex;
    while (index < endIndex) {
      const character = this.text[index];
      if (character === '\\') {
        index += 2;
        continue;
      }
      if (character === '`') {
        // Markers inside code never close emphasis outside it.
        const codeSpan = this.matchCodeSpan(index, endIndex);
        index = codeSpan !== null ? codeSpan.endIndex : index + this.runLength(index, endIndex);
        continue;
      }
      if (character !== '*' && character !== '_') {
        index += 1;
        continue;
      }
      const runLength = this.runLength(index, endIndex);
      const isOurCloser =
        character === delimiterCharacter &&
        index > contentStartIndex &&
        runLength >= delimiterLength &&
        // A pair closing a single marker would really be the end of something strong, not of this emphasis.
        !(delimiterLength === 1 && runLength === 2) &&
        this.canCloseEmphasis(index, runLength, endIndex);
      if (isOurCloser) return index;
      // A marker that opens something nested is skipped as a whole, so its closer is not mistaken for ours.
      const nestedEmphasis = this.matchEmphasis(index, endIndex);
      index = nestedEmphasis !== null ? nestedEmphasis.closerIndex + nestedEmphasis.delimiterLength : index + runLength;
    }
    return null;
  }

  /** Followed by something other than whitespace and, for an underscore, not inside a word. */
  private canOpenEmphasis(openerIndex: number, endIndex: number): boolean {
    const runLength = this.runLength(openerIndex, endIndex);
    const characterAfterRun = openerIndex + runLength < endIndex ? this.text[openerIndex + runLength] : undefined;
    if (characterAfterRun === undefined || whitespaceCharacter.test(characterAfterRun)) return false;
    if (this.text[openerIndex] === '_') {
      const characterBefore = this.text[openerIndex - 1];
      if (characterBefore !== undefined && letterOrDigit.test(characterBefore)) return false;
    }
    return true;
  }

  /** Preceded by something other than whitespace and, for an underscore, not followed by a letter or digit. */
  private canCloseEmphasis(closerIndex: number, runLength: number, endIndex: number): boolean {
    const characterBefore = this.text[closerIndex - 1];
    if (characterBefore === undefined || whitespaceCharacter.test(characterBefore)) return false;
    if (this.text[closerIndex] === '_') {
      const characterAfterRun = closerIndex + runLength < endIndex ? this.text[closerIndex + runLength] : undefined;
      if (characterAfterRun !== undefined && letterOrDigit.test(characterAfterRun)) return false;
    }
    return true;
  }

  /** How many copies of the character at `index` follow one another from there. */
  private runLength(index: number, endIndex: number): number {
    let runEndIndex = index;
    while (runEndIndex < endIndex && this.text[runEndIndex] === this.text[index]) runEndIndex += 1;
    return runEndIndex - index;
  }
}

interface EmphasisMatch {
  /** 2 for strong, 1 for emphasis. */
  delimiterLength: number;
  closerIndex: number;
}

interface CodeSpanMatch {
  content: string;
  /** Just past the closing backticks. */
  endIndex: number;
}

// Plain text ----------------------------------------------------------------------------------------------------------

/** The words of a list of spans, with every marker removed. */
export function plainTextFromInlineSpans(spans: InlineSpan[]): string {
  return spans
    .map((span) => {
      switch (span.kind) {
        case 'text':
        case 'code':
          return span.text;
        case 'strong':
        case 'emphasis':
        case 'link':
          return plainTextFromInlineSpans(span.children);
      }
    })
    .join('');
}

/**
 * Agents answer in markdown, and a task row has room for a few plain lines, so headings are skipped and links, emphasis
 * and list markers are reduced to their words instead of showing raw symbols. The first four blocks, joined by spaces.
 */
export function plainTextFromMarkdown(markdownText: string): string {
  const blockTexts: string[] = [];
  for (const block of parseMarkdownBlocks(markdownText)) {
    // Code blocks go through the inline parser too, exactly as Swift does.
    if (block.kind !== 'heading') blockTexts.push(plainTextFromInlineSpans(parseInlineMarkdown(block.text)));
  }
  if (blockTexts.length === 0) return plainTextFromInlineSpans(parseInlineMarkdown(markdownText));
  return blockTexts.slice(0, 4).join(' ');
}
