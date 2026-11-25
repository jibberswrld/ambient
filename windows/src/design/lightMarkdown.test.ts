import { describe, expect, it } from 'vitest';
import { parseInlineMarkdown, parseMarkdownBlocks, plainTextFromMarkdown, type InlineSpan } from './lightMarkdown';

// The block tests port AmbientLightMarkdownParserTests from Packages/AmbientKit/Tests/AmbientUITests/FlowBarModelTests.swift.

function text(literalText: string): InlineSpan {
  return { kind: 'text', text: literalText };
}

describe('parseMarkdownBlocks', () => {
  it('parses paragraphs, lists, headings and code', () => {
    const blocks = parseMarkdownBlocks(
      ['# Today', 'You have **three** meetings.', '', '- Standup at 9', '- Lunch with *Sam*', '2. Review `main`', '```', 'git pull', '```'].join('\n'),
    );
    expect(blocks).toEqual([
      { kind: 'heading', text: 'Today' },
      { kind: 'paragraph', text: 'You have **three** meetings.' },
      { kind: 'listItem', marker: '•', text: 'Standup at 9' },
      { kind: 'listItem', marker: '•', text: 'Lunch with *Sam*' },
      { kind: 'listItem', marker: '2.', text: 'Review `main`' },
      { kind: 'codeBlock', text: 'git pull' },
    ]);
  });

  it('still shows code while an unclosed fence is streaming', () => {
    expect(parseMarkdownBlocks('Run this:\n```\nnpm test')).toEqual([
      { kind: 'paragraph', text: 'Run this:' },
      { kind: 'codeBlock', text: 'npm test' },
    ]);
    // A fence just opened, with nothing inside yet, shows nothing rather than an empty box.
    expect(parseMarkdownBlocks('Run this:\n```')).toEqual([{ kind: 'paragraph', text: 'Run this:' }]);
  });

  it('joins wrapped lines into one paragraph and splits on blank lines', () => {
    expect(parseMarkdownBlocks('  First line\nsecond line  \n\n\tThird')).toEqual([
      { kind: 'paragraph', text: 'First line second line' },
      { kind: 'paragraph', text: 'Third' },
    ]);
  });

  it('keeps code exactly as written, indentation included', () => {
    expect(parseMarkdownBlocks('```swift\n  let x = 1\n\n  print(x)\n```')).toEqual([{ kind: 'codeBlock', text: '  let x = 1\n\n  print(x)' }]);
  });

  it('turns every bullet style into •', () => {
    expect(parseMarkdownBlocks('- one\n* two\n• three').map((block) => block)).toEqual([
      { kind: 'listItem', marker: '•', text: 'one' },
      { kind: 'listItem', marker: '•', text: 'two' },
      { kind: 'listItem', marker: '•', text: 'three' },
    ]);
    // Without the space it is not a bullet.
    expect(parseMarkdownBlocks('-not a bullet')).toEqual([{ kind: 'paragraph', text: '-not a bullet' }]);
  });

  it('reads numbered items with a dot or a parenthesis, up to three digits', () => {
    expect(parseMarkdownBlocks('3. Third\n4) Fourth\n120. Many')).toEqual([
      { kind: 'listItem', marker: '3.', text: 'Third' },
      { kind: 'listItem', marker: '4.', text: 'Fourth' },
      { kind: 'listItem', marker: '120.', text: 'Many' },
    ]);
    // Four digits is a year, not a list number; no space after the dot is not a list either.
    expect(parseMarkdownBlocks('2024. A year')).toEqual([{ kind: 'paragraph', text: '2024. A year' }]);
    expect(parseMarkdownBlocks('3.14 is pi')).toEqual([{ kind: 'paragraph', text: '3.14 is pi' }]);
  });

  it('needs a space after the hashes for a heading', () => {
    expect(parseMarkdownBlocks('### Deep  ')).toEqual([{ kind: 'heading', text: 'Deep' }]);
    expect(parseMarkdownBlocks('#hashtag')).toEqual([{ kind: 'paragraph', text: '#hashtag' }]);
  });

  it('ignores Windows line endings', () => {
    expect(parseMarkdownBlocks('# Title\r\nBody\r\n- item\r\n')).toEqual([
      { kind: 'heading', text: 'Title' },
      { kind: 'paragraph', text: 'Body' },
      { kind: 'listItem', marker: '•', text: 'item' },
    ]);
  });

  it('gives nothing for empty text', () => {
    expect(parseMarkdownBlocks('')).toEqual([]);
    expect(parseMarkdownBlocks('\n  \n')).toEqual([]);
  });
});

describe('parseInlineMarkdown', () => {
  it('leaves plain text alone', () => {
    expect(parseInlineMarkdown('Just words.')).toEqual([text('Just words.')]);
    expect(parseInlineMarkdown('')).toEqual([]);
  });

  it('reads strong, emphasis and code', () => {
    expect(parseInlineMarkdown('You have **three** meetings, *one* at `9:00` and __two__ _later_.')).toEqual([
      text('You have '),
      { kind: 'strong', children: [text('three')] },
      text(' meetings, '),
      { kind: 'emphasis', children: [text('one')] },
      text(' at '),
      { kind: 'code', text: '9:00' },
      text(' and '),
      { kind: 'strong', children: [text('two')] },
      text(' '),
      { kind: 'emphasis', children: [text('later')] },
      text('.'),
    ]);
  });

  it('reads links with styled labels', () => {
    expect(parseInlineMarkdown('See [the **docs**](https://example.com/a_(b)) now')).toEqual([
      text('See '),
      { kind: 'link', href: 'https://example.com/a_(b)', children: [text('the '), { kind: 'strong', children: [text('docs')] }] },
      text(' now'),
    ]);
    expect(parseInlineMarkdown('[x](<https://example.com/a b> "Title")')).toEqual([
      { kind: 'link', href: 'https://example.com/a b', children: [text('x')] },
    ]);
  });

  it('nests emphasis', () => {
    expect(parseInlineMarkdown('*a **b** c*')).toEqual([
      { kind: 'emphasis', children: [text('a '), { kind: 'strong', children: [text('b')] }, text(' c')] },
    ]);
    expect(parseInlineMarkdown('***both***')).toEqual([{ kind: 'strong', children: [{ kind: 'emphasis', children: [text('both')] }] }]);
  });

  it('keeps snake_case and lone markers as text', () => {
    expect(parseInlineMarkdown('call snake_case_name now')).toEqual([text('call snake_case_name now')]);
    expect(parseInlineMarkdown('2 * 3 * 4')).toEqual([text('2 * 3 * 4')]);
    expect(parseInlineMarkdown('_a snake_case b_')).toEqual([{ kind: 'emphasis', children: [text('a snake_case b')] }]);
    // An asterisk works inside a word, unlike an underscore.
    expect(parseInlineMarkdown('un*frigging*believable')).toEqual([
      text('un'),
      { kind: 'emphasis', children: [text('frigging')] },
      text('believable'),
    ]);
  });

  it('does not look for markers inside code', () => {
    expect(parseInlineMarkdown('`**not bold**` and `` a ` b ``')).toEqual([
      { kind: 'code', text: '**not bold**' },
      text(' and '),
      { kind: 'code', text: 'a ` b' },
    ]);
    expect(parseInlineMarkdown('**a `**` b**')).toEqual([{ kind: 'strong', children: [text('a '), { kind: 'code', text: '**' }, text(' b')] }]);
  });

  it('honours backslash escapes', () => {
    expect(parseInlineMarkdown('\\*not em\\* and C:\\Users')).toEqual([text('*not em* and C:\\Users')]);
  });

  it('shows half-written markup while streaming, without throwing', () => {
    expect(parseInlineMarkdown('You have **thr')).toEqual([text('You have **thr')]);
    expect(parseInlineMarkdown('Run `npm te')).toEqual([text('Run `npm te')]);
    expect(parseInlineMarkdown('See [the docs](https://exa')).toEqual([text('See [the docs](https://exa')]);
    expect(parseInlineMarkdown('See [the docs')).toEqual([text('See [the docs')]);
    expect(parseInlineMarkdown('trailing \\')).toEqual([text('trailing \\')]);
    const streamedReply = 'You have **three** meetings, *one* at `9:00`, see [the docs](https://example.com) and __more__.';
    for (let prefixLength = 0; prefixLength <= streamedReply.length; prefixLength += 1) {
      expect(() => parseInlineMarkdown(streamedReply.slice(0, prefixLength))).not.toThrow();
    }
  });

  it('stays fast on text full of unmatched markers', () => {
    const startTime = performance.now();
    parseInlineMarkdown('*a _b `c [d '.repeat(400));
    expect(performance.now() - startTime).toBeLessThan(2000);
  });
});

describe('plainTextFromMarkdown', () => {
  it('skips headings and reduces markup to its words', () => {
    expect(plainTextFromMarkdown('# Report\nFixed **two** bugs in [the parser](https://example.com).\n\n- Ran `pnpm test`')).toBe(
      'Fixed two bugs in the parser. Ran pnpm test',
    );
  });

  it('keeps only the first four blocks', () => {
    expect(plainTextFromMarkdown('- one\n- two\n- three\n- four\n- five')).toBe('one two three four');
  });

  it('runs code blocks through the inline parser too, as Swift does', () => {
    expect(plainTextFromMarkdown('```\nrm *.tmp\n```')).toBe('rm *.tmp');
    expect(plainTextFromMarkdown('```\nsay *hi*\n```')).toBe('say hi');
  });

  it('falls back to the whole text when there are no blocks but headings', () => {
    expect(plainTextFromMarkdown('# Only a **heading**')).toBe('# Only a heading');
    expect(plainTextFromMarkdown('')).toBe('');
  });
});
