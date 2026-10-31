import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

struct SearchControl: Codable {
    let owner: String
    let context: String
    let kind: String
    let label: String
    let line: Int
    let anchors: [String]
}

struct SearchComponent: Codable {
    let name: String
    let file: String
    let calls: [String]
    let controls: [SearchControl]
    let anchors: [String]
    let anchorResolutions: [String: [String]]
    let registrations: [SearchRegistration]
}

struct SearchRegistration: Codable {
    let id: String
    let anchor: String
    let page: String
}

private final class SearchAnchorStrings: SyntaxVisitor {
    var values: [String] = []
    var references: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        values.append(node.trimmedDescription)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        references.insert(node.baseName.text)
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        references.insert(node.declName.baseName.text)
        return .visitChildren
    }
}

final class SearchInventory: SyntaxVisitor {
    private let file: String
    private let locations: SourceLocationConverter
    private var owners: [String] = []
    private var contexts: [String] = []
    private var functionOwners: [Bool] = []
    private var calls: [String: Set<String>] = [:]
    private var controls: [String: [SearchControl]] = [:]
    private var anchors: [String: Set<String>] = [:]
    private var registrations: [String: [SearchRegistration]] = [:]
    private var definitions: [String: [String: [Syntax]]] = [:]
    private var anchorExpressions: [String: [Syntax]] = [:]
    private var inputKinds: Set<String> = [
        "Toggle", "Picker", "Slider", "Stepper", "DatePicker", "ColorPicker",
        "TextField", "SecureField", "Button", "SettingsStepper", "FocusGatedSwitch",
        "SettingsCheckableRow", "Menu", "NavigationLink", "SettingsPageLink",
        "SettingsOptionPicker", "SettingsSegmentedPicker", "SettingsCompactOptionPicker",
        "MobileSubtitleSliderRow", "subtitleColorPicker", "numberRow", "choiceRow", "colorRow",
        "StyleRowSpec", "StreamingQualityPicker", "CollectionCoverLayoutPicker",
        "LiveTVGuideDaysPicker"
    ]

    init(file: String, tree: SourceFileSyntax, additionalInputs: Set<String>) {
        self.file = file
        locations = SourceLocationConverter(fileName: file, tree: tree)
        inputKinds.formUnion(additionalInputs)
        super.init(viewMode: .sourceAccurate)
    }

    var components: [SearchComponent] {
        calls.keys.sorted().map { owner in
            var resolved = anchors[owner, default: []]
            var resolutions: [String: [String]] = [:]
            for expression in anchorExpressions[owner, default: []] {
                let strings = resolveStrings(expression, owner: owner)
                resolved.formUnion(strings)
                resolutions[expression.trimmedDescription] = strings.sorted()
            }
            return SearchComponent(
                name: owner, file: file, calls: calls[owner, default: []].sorted(),
                controls: controls[owner, default: []],
                anchors: resolved.sorted(), anchorResolutions: resolutions,
                registrations: registrations[owner, default: []]
            )
        }
    }

    private func resolveStrings(_ expression: Syntax, owner: String, seen: Set<String> = []) -> Set<String> {
        let visitor = SearchAnchorStrings()
        visitor.walk(expression)
        var values = Set(visitor.values)
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            var expansions = [""]
            for segment in literal.segments {
                let alternatives: [String]
                if let text = segment.as(StringSegmentSyntax.self) {
                    alternatives = [text.content.text]
                } else if let interpolation = segment.as(ExpressionSegmentSyntax.self),
                          let value = interpolation.expressions.first?.expression {
                    let constants = resolveStrings(Syntax(value), owner: owner, seen: seen)
                        .filter { $0.hasPrefix("\"") && $0.hasSuffix("\"") && !$0.contains("\\(") }
                        .map { String($0.dropFirst().dropLast()) }
                    alternatives = constants.isEmpty ? ["*"] : constants.sorted()
                } else { alternatives = ["*"] }
                guard expansions.count * alternatives.count <= 64 else { return values }
                expansions = expansions.flatMap { prefix in alternatives.map { prefix + $0 } }
            }
            values.formUnion(expansions.map { "\"\($0)\"" })
        }
        for reference in visitor.references.subtracting(seen) {
            guard let candidates = definitions[owner]?[reference], candidates.count == 1,
                  let definition = candidates.first else { continue }
            values.formUnion(resolveStrings(definition, owner: owner, seen: seen.union([reference])))
        }
        return values
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        calls[node.name.text, default: []] = calls[node.name.text, default: []]
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        calls[node.name.text, default: []] = calls[node.name.text, default: []]
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        calls[node.name.text, default: []] = calls[node.name.text, default: []]
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { owners.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let introducesOwner = owners.isEmpty
        functionOwners.append(introducesOwner)
        if introducesOwner {
            owners.append(node.name.text)
            calls[node.name.text, default: []] = calls[node.name.text, default: []]
        }
        if let owner = owners.last, let body = node.body {
            definitions[owner, default: [:]][node.name.text, default: []].append(Syntax(body))
        }
        contexts.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        contexts.removeLast()
        if functionOwners.removeLast() { owners.removeLast() }
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let owner = owners.last, let name = node.pattern.as(IdentifierPatternSyntax.self) {
            if let initializer = node.initializer {
                definitions[owner, default: [:]][name.identifier.text, default: []].append(Syntax(initializer.value))
            } else if let accessor = node.accessorBlock {
                definitions[owner, default: [:]][name.identifier.text, default: []].append(Syntax(accessor))
            }
        }
        contexts.append(node.pattern.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) { contexts.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let owner = owners.last else { return .visitChildren }
        let kind: String
        if let name = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            kind = name.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            kind = member.declName.baseName.text
        } else { return .visitChildren }
        calls[owner, default: []].insert(kind)
        if kind == "settingsSearchAnchor", let value = node.arguments.first?.expression {
            anchorExpressions[owner, default: []].append(Syntax(value))
            anchors[owner, default: []].insert(value.trimmedDescription)
            let strings = SearchAnchorStrings()
            strings.walk(value)
            if let fallback = node.arguments.first(where: { $0.label?.text == "fallbackFor" })?.expression {
                strings.walk(fallback)
                anchorExpressions[owner, default: []].append(Syntax(fallback))
            }
            anchors[owner, default: []].formUnion(strings.values)
        }
        if owner == "SettingsSearchCatalog", ["init", "SettingsSearchEntry"].contains(kind),
           let id = node.arguments.first?.expression,
           let page = node.arguments.first(where: { $0.label?.text == "page" })?.expression {
            let anchor = node.arguments.first(where: { $0.label?.text == "anchorID" })?.expression ?? id
            registrations[owner, default: []].append(.init(
                id: id.trimmedDescription, anchor: anchor.trimmedDescription, page: page.trimmedDescription
            ))
        }
        guard inputKinds.contains(kind) else { return .visitChildren }
        let title = node.arguments.first { ["title", "label"].contains($0.label?.text ?? "") }
            ?? node.arguments.first { $0.label == nil }
        let label = title?.expression.trimmedDescription ?? node.additionalTrailingClosures
            .first(where: { $0.label.text == "label" })?.closure.statements.trimmedDescription ?? "<dynamic>"
        var anchors: [String] = []
        for argument in node.arguments where ["searchAnchor", "searchAnchorID"].contains(argument.label?.text ?? "") {
            anchors.append(argument.expression.trimmedDescription)
            anchorExpressions[owner, default: []].append(Syntax(argument.expression))
        }
        if let fallback = node.arguments.first(where: { $0.label?.text == "searchFallbacks" }) {
            anchorExpressions[owner, default: []].append(Syntax(fallback.expression))
        }
        var ancestor: Syntax? = Syntax(node)
        while let current = ancestor, !current.is(CodeBlockItemSyntax.self),
              !current.is(PatternBindingSyntax.self) {
            if let call = current.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "settingsSearchAnchor",
               let value = call.arguments.first?.expression {
                anchors.append(value.trimmedDescription)
                if let fallback = call.arguments.first(where: { $0.label?.text == "fallbackFor" }) {
                    anchors.append(fallback.expression.trimmedDescription)
                }
            }
            ancestor = current.parent
        }
        controls[owner, default: []].append(SearchControl(
            owner: owner, context: contexts.joined(separator: "."), kind: kind, label: label,
            line: locations.location(for: node.positionAfterSkippingLeadingTrivia).line,
            anchors: anchors
        ))
        return .visitChildren
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let additionalInputs: Set<String>
if CommandLine.arguments.count > 2 {
    struct Policy: Decodable { let input_types: [String] }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let policy = try JSONDecoder().decode(Policy.self, from: data)
    additionalInputs = Set(policy.input_types)
} else {
    additionalInputs = []
}
let sources = root.appendingPathComponent("Sources")
guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]) else {
    fatalError("Cannot enumerate Sources")
}
var components: [SearchComponent] = []
for case let url as URL in files where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    let tree = Parser.parse(source: source)
    if tree.hasError {
        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        FileHandle.standardError.write(Data(DiagnosticsFormatter.annotatedSource(tree: tree, diags: diagnostics).utf8))
        exit(1)
    }
    let visitor = SearchInventory(
        file: String(url.path.dropFirst(root.path.count + 1)), tree: tree, additionalInputs: additionalInputs
    )
    visitor.walk(tree)
    components += visitor.components
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(components.sorted { ($0.file, $0.name) < ($1.file, $1.name) }))
