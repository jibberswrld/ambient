import AmbientContracts
import SwiftUI

private let cardContentMaximumWidth = AmbientDesign.Metrics.cardMaximumWidth - AmbientDesign.Metrics.cardPadding * 2

// MARK: - Reply

/// The answer. Grows away from the docked edge as text streams in, hugs short answers, scrolls long ones.
struct FlowBarReplyCard: View {
    var model: FlowBarModel

    var body: some View {
        let isStreaming = model.isReplyStillStreaming
        let showsFooter = isStreaming || model.showsReplyActions
        FlowBarCardStack(maximumWidth: cardContentMaximumWidth, minimumWidth: showsFooter ? 236 : 0, spacing: 10) {
            FlowBarReplyBody(markdownText: model.displayedReplyText, isStreaming: isStreaming)
            if showsFooter {
                footer(isStreaming: isStreaming)
                    .stretchesToCardWidth()
            }
        }
        .padding(AmbientDesign.Metrics.cardPadding)
        .padding(.bottom, showsFooter ? -5 : 0)
        .environment(\.openURL, OpenURLAction { url in
            model.onOpenURL(url)
            return .handled
        })
    }

    @ViewBuilder
    private func footer(isStreaming: Bool) -> some View {
        HStack(spacing: 6) {
            if isStreaming {
                AmbientEmberIndicator(activity: model.currentActivityLine == nil ? .thinking : .working, diameter: 12)
                if let activityLine = model.currentActivityLine {
                    Text(activityLine)
                        .font(.system(size: 12))
                        .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                AmbientCapsuleButton(title: "Stop", systemImageName: "stop.fill", prominence: .quiet, isCompact: true) { model.cancelCurrentTurn() }
            } else {
                if !model.toolCallsThisTurn.isEmpty {
                    Text(model.toolCallsThisTurn.count == 1 ? "1 step" : "\(model.toolCallsThisTurn.count) steps")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                        .fixedSize()
                }
                Spacer(minLength: 12)
                AmbientGlassIconButton(systemImageName: "doc.on.doc", accessibilityLabelText: "Copy", diameter: 26, symbolPointSize: 11) { model.copyReplyToPasteboard() }
                AmbientCapsuleButton(title: "Reply", systemImageName: "arrowshape.turn.up.left", prominence: .quiet, isCompact: true) { model.continueConversation() }
                AmbientGlassIconButton(systemImageName: "xmark", accessibilityLabelText: "Dismiss", diameter: 26, symbolPointSize: 10) { model.dismissReplyOrError() }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, -6)
    }
}

/// The reply text. Short replies size to the text; long ones stop at the maximum height and scroll, following the
/// stream to the bottom while it is still arriving.
struct FlowBarReplyBody: View {
    var markdownText: String
    var isStreaming: Bool

    var body: some View {
        AmbientProposalLimit(maximumHeight: AmbientDesign.Metrics.cardMaximumTextHeight) {
            ViewThatFits(in: .vertical) {
                textContent
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            textContent
                            Color.clear.frame(height: 1).id("end-of-reply")
                        }
                    }
                    .scrollIndicators(.automatic)
                    .mask(scrollEdgeFade(fadesTopEdge: isStreaming))
                    .onChange(of: markdownText) {
                        if isStreaming { scrollProxy.scrollTo("end-of-reply", anchor: .bottom) }
                    }
                    .onAppear { if isStreaming { scrollProxy.scrollTo("end-of-reply", anchor: .bottom) } }
                }
            }
        }
    }

    private var textContent: some View {
        AmbientLightMarkdownView(markdownText: markdownText.isEmpty ? " " : markdownText)
            .textSelection(.enabled)
    }

    /// Text dissolves at the edge where more of it is hidden instead of being cut by a hard line: the top while
    /// streaming (the view follows the newest line), the bottom once finished (more to read below).
    private func scrollEdgeFade(fadesTopEdge: Bool) -> some View {
        AmbientScrollEdgeFade(fadesTopEdge: fadesTopEdge, fadesBottomEdge: !fadesTopEdge)
    }
}

// MARK: - Error

struct FlowBarErrorCard: View {
    var model: FlowBarModel

    var body: some View {
        let notice = model.currentErrorNotice ?? FlowBarErrorNotice(message: "Something went wrong.")
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AmbientDesign.Palette.alert)
                .padding(.top, 1)
            AmbientProposalLimit(maximumWidth: 270) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(notice.message)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let link = notice.link {
                        AmbientCapsuleButton(title: link.title, systemImageName: link.destination == .settings ? nil : "arrow.up.right", prominence: .primary, isCompact: true) {
                            model.followErrorLink(link)
                        }
                    }
                }
            }
            AmbientGlassIconButton(systemImageName: "xmark", accessibilityLabelText: "Dismiss", diameter: 22, symbolPointSize: 9.5) { model.dismissReplyOrError() }
                .padding(.top, -3)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Approval

struct FlowBarApprovalCard: View {
    var model: FlowBarModel

    var body: some View {
        let request = model.pendingApproval ?? FlowBarApprovalRequest(title: "", detail: "", kind: .other)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: request.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmbientDesign.Palette.ember)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(AmbientDesign.Palette.ember.opacity(0.16)))
                Text(request.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AmbientProposalLimit(maximumHeight: 150) {
                ViewThatFits(in: .vertical) {
                    detailText(request)
                    ScrollView(.vertical) { detailText(request) }
                }
            }
            .background(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).fill(Color.black.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 0.75))
            HStack(spacing: 8) {
                Text(request.kind == .shellCommand ? "Runs on this Mac" : "Runs in the background")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                Spacer(minLength: 8)
                AmbientCapsuleButton(title: "Deny", prominence: .secondary, isCompact: true) { model.answerPendingApproval(isAllowed: false) }
                AmbientCapsuleButton(title: "Allow", prominence: .primary, isCompact: true) { model.answerPendingApproval(isAllowed: true) }
            }
        }
        .padding(AmbientDesign.Metrics.cardPadding)
        .frame(width: AmbientDesign.Metrics.cardMaximumWidth)
    }

    private func detailText(_ request: FlowBarApprovalRequest) -> some View {
        Text(request.detail)
            .font(request.kind == .shellCommand ? AmbientDesign.Typeface.monospacedDetail : .system(size: 12.5))
            .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
    }

    private func iconName(for kind: FlowBarApprovalRequest.Kind) -> String {
        switch kind {
        case .shellCommand: return "terminal"
        case .backgroundAgent: return "cpu"
        case .other: return "hand.raised"
        }
    }
}

/// A mask that fades content out over a short distance at the top, the bottom, or both.
struct AmbientScrollEdgeFade: View {
    var fadesTopEdge: Bool
    var fadesBottomEdge: Bool
    var fadeLength: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            if fadesTopEdge {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fadeLength)
            }
            Color.black
            if fadesBottomEdge {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fadeLength)
            }
        }
    }
}
