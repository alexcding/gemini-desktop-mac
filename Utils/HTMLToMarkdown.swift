//
//  HTMLToMarkdown.swift
//  GeminiDesktop
//
//  Converts HTML to Markdown using SwiftSoup for reliable HTML parsing.
//  This handles all common HTML structures from Gemini responses: headings, paragraphs,
//  lists, tables, code blocks, links, images, and more.
//

import Foundation
import SwiftSoup

enum HTMLToMarkdown {
    /// Converts HTML string to Markdown string
    /// - Parameter html: Raw HTML from the response element
    /// - Returns: Markdown representation of the HTML
    static func convert(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        do {
            let doc = try SwiftSoup.parse(html)
            // Parse the document body (or entire doc if no body)
            let root = (try? doc.body()) ?? doc
            return parseNode(root).trimmingCharacters(in: .whitespaces)
        } catch {
            // If parsing fails, return the HTML as-is (better than nothing)
            return html.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Recursively parse an Element node and convert to Markdown
    private static func parseNode(_ node: Element) -> String {
        var result = ""

        do {
            for child in try node.getChildNodes() {
                result += parseNode(child)
            }
        } catch {
            return ""
        }

        return result
    }

    /// Parse any node (Element or TextNode) and return Markdown
    private static func parseNode(_ node: Node) -> String {
        if let textNode = node as? TextNode {
            // Text nodes: trim whitespace but preserve content
            let text = textNode.getWholeText().trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "" : text
        }

        guard let element = node as? Element else { return "" }

        let tag = element.tagName().lowercased()
        let childMarkdown = getChildrenMarkdown(element)

        switch tag {
        // Headings
        case "h1": return "# \(childMarkdown)\n\n"
        case "h2": return "## \(childMarkdown)\n\n"
        case "h3": return "### \(childMarkdown)\n\n"
        case "h4": return "#### \(childMarkdown)\n\n"
        case "h5": return "##### \(childMarkdown)\n\n"
        case "h6": return "###### \(childMarkdown)\n\n"

        // Paragraphs and text formatting
        case "p": return "\(childMarkdown)\n\n"
        case "strong", "b": return "**\(childMarkdown)**"
        case "em", "i": return "_\(childMarkdown)_"
        case "code": return "`\(childMarkdown)`"

        // Code blocks
        case "pre":
            let code = extractCodeFromPre(element)
            return "```\n\(code)\n```\n\n"

        // Blockquotes
        case "blockquote":
            let quoted = childMarkdown.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            return "\(quoted)\n\n"

        // Lists
        case "ul": return handleUnorderedList(element)
        case "ol": return handleOrderedList(element)
        case "li": return childMarkdown

        // Links and images
        case "a":
            let href = try? element.attr("href")
            return "[\(childMarkdown)](\(href ?? ""))"

        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.attr("src")) ?? ""
            return alt.isEmpty ? "![Image](\(src))" : "![\(alt)](\(src))"

        // Tables
        case "table": return handleTable(element)
        case "tr", "th", "td": return childMarkdown

        // Line breaks
        case "br": return "\n"

        // Skip script, style, and other non-content elements
        case "script", "style", "noscript": return ""

        // SVG and other media fallback
        case "svg": return "[Chart/Diagram - not captured in Markdown]\n"

        // For all other tags, recurse into children
        default: return childMarkdown
        }
    }

    /// Get the Markdown representation of all child nodes
    private static func getChildrenMarkdown(_ element: Element) -> String {
        var result = ""
        do {
            for child in try element.getChildNodes() {
                result += parseNode(child)
            }
        } catch {
            return ""
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Extract code from <pre> blocks, preferring <code> content
    private static func extractCodeFromPre(_ element: Element) -> String {
        do {
            // Try to find a <code> element inside the <pre>
            if let codeElement = try element.select("code").first() {
                let code = try codeElement.text()
                return code.isEmpty ? (try element.text()) : code
            }
            // Fallback to pre's text content
            return try element.text()
        } catch {
            return ""
        }
    }

    /// Handle unordered lists (<ul>)
    private static func handleUnorderedList(_ element: Element) -> String {
        do {
            let items = try element.select(":scope > li")
            let markdownItems = items.map { li -> String in
                let content = getChildrenMarkdown(li)
                return "- \(content)"
            }
            return markdownItems.joined(separator: "\n") + "\n\n"
        } catch {
            return ""
        }
    }

    /// Handle ordered lists (<ol>)
    private static func handleOrderedList(_ element: Element) -> String {
        do {
            let items = try element.select(":scope > li")
            let markdownItems = items.enumerated().map { (index, li) -> String in
                let content = getChildrenMarkdown(li)
                return "\(index + 1). \(content)"
            }
            return markdownItems.joined(separator: "\n") + "\n\n"
        } catch {
            return ""
        }
    }

    /// Handle tables (<table>)
    private static func handleTable(_ element: Element) -> String {
        do {
            let rows = try element.select("tr")
            guard !rows.isEmpty else { return "" }

            var markdown: [String] = []

            for (rowIndex, row) in rows.enumerated() {
                let cells = try row.select("th, td")
                let cellTexts = cells.map { try? $0.text() }.compactMap { $0 }

                // Build row
                let rowMarkdown = "| " + cellTexts.joined(separator: " | ") + " |"
                markdown.append(rowMarkdown)

                // Add separator after header row
                if rowIndex == 0 {
                    let separator = "| " + cellTexts.map { _ in "---" }.joined(separator: " | ") + " |"
                    markdown.append(separator)
                }
            }

            return markdown.joined(separator: "\n") + "\n\n"
        } catch {
            return ""
        }
    }
}
