import AppKit
import PiOSCore

/// Small, native Markdown presentation. No HTML/webview, remote images, or executable links.
/// Original model text remains separate and is always used by Copy Answer.
@MainActor enum AnswerRenderer {
    static func render(_ source: String, scale: CGFloat = 1) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCode = false
        var blank = false
        for rawLine in source.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle(); blank = false
                continue
            }
            if rawLine.isEmpty && !inCode { blank = true; continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = inCode ? 0 : 8
            paragraph.paragraphSpacingBefore = blank ? 8 : 0
            paragraph.lineBreakMode = .byWordWrapping
            blank = false
            var font = NSFont.systemFont(ofSize: 15 * scale)
            var color = NSColor.labelColor
            var line = rawLine
            var code = false
            if inCode {
                font = .monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular)
                paragraph.firstLineHeadIndent = 12; paragraph.headIndent = 12
                paragraph.tailIndent = -12
                paragraph.lineSpacing = 5
                code = true
            } else if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let depth = line[heading].filter { $0 == "#" }.count
                line.removeSubrange(heading)
                font = .systemFont(ofSize: (depth == 1 ? 21 : depth == 2 ? 17 : 15) * scale, weight: .semibold)
                paragraph.paragraphSpacingBefore = result.length == 0 ? 0 : 14
                paragraph.paragraphSpacing = 9
            } else if let bullet = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                let indent = line.prefix(while: { $0 == " " }).count
                line.removeSubrange(bullet)
                line = "•\t" + line
                paragraph.firstLineHeadIndent = CGFloat(min(indent, 8)) * 4
                paragraph.headIndent = paragraph.firstLineHeadIndent + 18
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.paragraphSpacing = 6
            } else if let number = line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) {
                let marker = line[number].trimmingCharacters(in: .whitespaces)
                line.removeSubrange(number)
                line = marker + "\t" + line
                paragraph.headIndent = 24
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
            } else if line.hasPrefix("> ") {
                line = String(line.dropFirst(2))
                color = PanelStyle.secondaryInk
                paragraph.firstLineHeadIndent = 14; paragraph.headIndent = 14
            }
            let block = code ? NSMutableAttributedString(string: line) : inline(line, font: font, color: color, scale: scale)
            if code { block.addAttributes([.backgroundColor: NSColor.labelColor.withAlphaComponent(0.055)], range: NSRange(location: 0, length: block.length)) }
            let whole = NSRange(location: 0, length: block.length)
            block.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if code { block.addAttributes([.font: font, .foregroundColor: color], range: whole) }
            block.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            result.append(block)
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    private static func inline(_ source: String, font: NSFont, color: NSColor, scale: CGFloat) -> NSMutableAttributedString {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var styledFont = font
            if intent.contains(.code) { styledFont = .monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular) }
            else {
                if intent.contains(.stronglyEmphasized) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask) }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: styledFont, .foregroundColor: color]
            if intent.contains(.code) { attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link, safeLink(url) { attrs[.link] = url }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        return result
    }
    static func safeLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
    static func measuredHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

struct PanelMetrics {
    static let width: CGFloat = 480
    static let inputMin: CGFloat = 24
    static let inputMax: CGFloat = 104
    static func promptHeight(inputHeight: CGFloat) -> CGFloat { max(50, min(inputMax, max(inputMin, inputHeight)) + 22) }
    static func answerHeight(textHeight: CGFloat, question: Bool, availableHeight: CGFloat) -> CGFloat {
        min(max(1, availableHeight - 106), max(152, min(500, textHeight + (question ? 118 : 89))))
    }
}

struct FailurePresentation {
    let title: String
    let message: String
    let symbol: String
    let offersPermissions: Bool
    init(_ error: Error) {
        let domain = error as? DomainError
        offersPermissions = ["permission_denied", "accessibility_denied", "input_permission_denied", "control_disabled"].contains(domain?.code ?? "")
        switch domain?.code {
        case "permission_denied":
            title = "Let pi-os see this window"
            message = "Allow Screen Recording to ask about what’s on screen. pi-os captures only the window you choose."
            symbol = "macwindow.badge.plus"
        case "accessibility_denied", "input_permission_denied", "control_disabled":
            title = "Enable computer control"
            message = domain?.message ?? "Allow Accessibility for a stable signed pi-os installation, then try again."
            symbol = "cursorarrow"
        case "focus_failed", "focus_unknown":
            title = "Couldn’t safely target this window"
            message = "Bring the window forward and start a new question. No input was posted by this rejected action."
            symbol = "macwindow"
        case "file_deletion_blocked":
            title = "File deletion is blocked"
            message = "pi-os can help with normal actions here, but it won’t delete files, move them to Trash, or empty Trash."
            symbol = "trash.slash"
        case "credential_input_blocked":
            title = "This login field is blocked"
            message = "Ordinary typing and clicks still work. To allow this username/password field, enable ‘Allow input in username and password fields’ in pi-os Settings. No macOS security setting needs to be disabled."
            symbol = "lock.shield"
        case "secure_input", "policy_blocked", "target_elevated":
            title = "This input is protected"
            message = domain?.message ?? "Computer control is not allowed for this target."
            symbol = "lock.shield"
        case "capture_stale":
            title = "The window changed"
            message = "Capture the window again before using screenshot coordinates. No input was posted by this rejected action."
            symbol = "rectangle.dashed"
        case "input_failed":
            title = "Input was interrupted"
            message = "Some input may already have reached the window. Check it before starting another task; pi-os will not retry the action automatically."
            symbol = "exclamationmark.circle"
        case "no_target":
            title = "Choose a window first"
            message = "Bring a document or browser window to the front, then use the pi-os shortcut again."
            symbol = "macwindow"
        case "target_gone":
            title = "That window is no longer open"
            message = "Open the window you’d like to ask about and start a new question. Nothing else was captured."
            symbol = "macwindow"
        case "capture_failed":
            title = "Couldn’t see this window"
            message = "Make sure the window is visible and try again. If it keeps happening, check Screen Recording in Permissions."
            symbol = "rectangle.dashed"
        case "harness_unreachable":
            title = "The agent couldn’t connect"
            message = "Try your question again. If it keeps happening, open Diagnostics from the pi-os menu."
            symbol = "bolt.slash"
        case "timed_out":
            title = "This is taking too long"
            message = "The request reached its time limit. Try a shorter or more specific question."
            symbol = "clock"
        default:
            title = "Something interrupted your request"
            message = domain?.message ?? error.localizedDescription
            symbol = "exclamationmark.circle"
        }
    }
}
