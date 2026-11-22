import type { ReactNode } from 'react';
import type { ControlSurface } from './controls';
import { parseInlineMarkdown, parseMarkdownBlocks, type InlineSpan, type MarkdownBlock } from './lightMarkdown';

/**
 * Light markdown — the subset a spoken assistant actually uses — on smoked glass (replies) or on a window surface
 * (Activity reports). Links never navigate the window: they go to `onOpenLink`, which opens the browser.
 */
export function MarkdownView(props: { markdownText: string; surface: ControlSurface; onOpenLink: (url: string) => void }) {
  const blocks = parseMarkdownBlocks(props.markdownText);
  return (
    <div className={`markdown-view surface-${props.surface}`}>
      {blocks.map((block, blockIndex) => (
        <MarkdownBlockView key={blockIndex} block={block} onOpenLink={props.onOpenLink} />
      ))}
    </div>
  );
}

function MarkdownBlockView(props: { block: MarkdownBlock; onOpenLink: (url: string) => void }) {
  const { block, onOpenLink } = props;
  switch (block.kind) {
    case 'paragraph':
      return <p className="markdown-paragraph">{renderInlineSpans(parseInlineMarkdown(block.text), onOpenLink)}</p>;
    case 'heading':
      return <p className="markdown-heading">{renderInlineSpans(parseInlineMarkdown(block.text), onOpenLink)}</p>;
    case 'listItem':
      return (
        <div className="markdown-list-item">
          <span className="markdown-list-marker">{block.marker}</span>
          <span className="markdown-list-text">{renderInlineSpans(parseInlineMarkdown(block.text), onOpenLink)}</span>
        </div>
      );
    case 'codeBlock':
      return <pre className="markdown-code-block">{block.text}</pre>;
  }
}

function renderInlineSpans(spans: InlineSpan[], onOpenLink: (url: string) => void): ReactNode[] {
  return spans.map((span, spanIndex) => {
    switch (span.kind) {
      case 'text':
        return span.text;
      case 'strong':
        return <strong key={spanIndex}>{renderInlineSpans(span.children, onOpenLink)}</strong>;
      case 'emphasis':
        return <em key={spanIndex}>{renderInlineSpans(span.children, onOpenLink)}</em>;
      case 'code':
        return (
          <code key={spanIndex} className="markdown-inline-code">
            {span.text}
          </code>
        );
      case 'link':
        return (
          <a
            key={spanIndex}
            className="markdown-link"
            href={span.href}
            title={span.href}
            onClick={(event) => {
              event.preventDefault();
              onOpenLink(span.href);
            }}
          >
            {renderInlineSpans(span.children, onOpenLink)}
          </a>
        );
    }
  });
}
