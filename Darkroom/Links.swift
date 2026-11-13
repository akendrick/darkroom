import SwiftUI

/// What an item was made from (a tissue from a glop batch and a sensitizer, a
/// material from other materials), or what a print layer also used (a mask
/// negative, a second tissue). The server keeps both: item_link and
/// photo_layer_item in darkroom-api.php.
struct LinkRow: Identifiable, Equatable {
    let id = UUID()
    var kind: String
    var itemId: Int?
    var role = ""
    var amount = ""
    var unit = ""
    /// Shown on the row until the list of choices has it.
    var label: String?
    /// Kept as they were: parts of a mix, notes (edited on the website).
    var keep: [String: JSON] = [:]

    static let names = ["chemistry": "Batch", "carbon_tissue": "Carbon tissue", "support_paper": "Support paper",
                        "negative": "Negative", "material": "Material", "paper": "Paper", "pigment": "Pigment"]
    /// What can be made from, and what a layer can also use.
    static let madeKinds = ["chemistry", "material", "paper", "pigment", "carbon_tissue", "support_paper", "negative"]
    static let layerKinds = ["negative", "carbon_tissue", "chemistry", "support_paper", "material"]

    init(kind: String) { self.kind = kind }

    /// A made-from link as the server sends it.
    init(link j: JSON) {
        kind = j["parent_type"].string ?? "chemistry"; itemId = j["parent_id"].int
        role = j["role"].string ?? ""; amount = j["amount"].double.map(Amount.format) ?? ""
        unit = j["unit"].string ?? ""; label = j["parent_label"].string
        keep = ["parts": j["parts"], "notes": j["notes"]]
    }
    /// A layer's extra item as the server sends it.
    init(item j: JSON) {
        kind = j["item_type"].string ?? "negative"; itemId = j["item_id"].int
        role = j["role"].string ?? ""; label = j["item_label"].string
        keep = ["notes": j["notes"]]
    }

    private var roleOrNull: JSON { .from(role.trimmingCharacters(in: .whitespaces).isEmpty ? nil : role.trimmingCharacters(in: .whitespaces)) }

    var asLink: JSON? {
        guard let itemId else { return nil }
        let a = amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let u = unit.trimmingCharacters(in: .whitespaces)
        return .object(keep.merging(["parent_type": .string(kind), "parent_id": .from(itemId), "role": roleOrNull,
                                     "amount": .from(Double(a)), "unit": .from(u.isEmpty ? nil : u)]) { _, n in n })
    }
    var asItem: JSON? {
        guard let itemId else { return nil }
        return .object(keep.merging(["item_type": .string(kind), "item_id": .from(itemId), "role": roleOrNull]) { _, n in n })
    }

    /// "Glop A 20 mL (Sensitizer)".
    static func summary(_ links: [JSON], item: Bool = false) -> String? {
        let s = links.map { j -> String in
            let name = j[item ? "item_label" : "parent_label"].string ?? "#\(j[item ? "item_id" : "parent_id"].int ?? 0)"
            let amt = j["amount"].double.map { Amount.format($0) + (j["unit"].string.map { " " + $0 } ?? "") }
            return [item ? j["role"].string.map { $0 + ":" } : nil, name, amt, item ? nil : j["role"].string.map { "(\($0))" }]
                .compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }
}

extension Snapshot {
    /// Everything of a kind that can be chosen, named as the website names it.
    func linkChoices(_ kind: String) -> [(id: Int, name: String)] {
        let rows: [JSON]
        switch kind {
        case "chemistry": rows = raw["chemistry"].array
        case "carbon_tissue": rows = raw["carbon_tissues"].array
        case "support_paper": rows = raw["support_papers"].array
        case "negative": rows = raw["negatives"].array
        case "material": rows = raw["materials"].array
        case "paper": rows = raw["papers"].array
        case "pigment": rows = raw["pigments"].array
        default: rows = []
        }
        return rows.filter { !$0["archived"].flag }.compactMap { j in
            guard let id = j["id"].int else { return nil }
            let name: String
            switch kind {
            case "chemistry": name = Batch(j).label
            case "carbon_tissue": name = Material(what: .carbon_tissue, row: j).label
            case "support_paper": name = Material(what: .support_paper, row: j).label
            case "negative": name = Material(what: .negative, row: j).label
            case "material": name = [kindName(j["kind_id"].int), j["label"].string].compactMap { $0 }.joined(separator: ": ")
            case "paper": name = Paper(j).name
            default: name = j["name"].string ?? "#\(id)"
            }
            return (id, name)
        }
    }
}

/// Rows of kind, item, what it was used as and (made from only) how much.
struct LinksEditor: View {
    @Binding var rows: [LinkRow]
    /// A layer's extra items: no amounts.
    var layer = false
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($rows) { $r in row($r) }
            Menu {
                ForEach(layer ? LinkRow.layerKinds : LinkRow.madeKinds, id: \.self) { k in
                    Button(LinkRow.names[k] ?? k) { rows.append(LinkRow(kind: k)) }
                }
            } label: {
                Label(layer ? "Negative, tissue or batch" : "Made from", systemImage: "plus")
                    .font(Theme.body.weight(.bold)).foregroundStyle(Theme.red)
            }
        }
    }

    private func row(_ r: Binding<LinkRow>) -> some View {
        let choices = store.snapshot?.linkChoices(r.wrappedValue.kind) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((LinkRow.names[r.wrappedValue.kind] ?? r.wrappedValue.kind).uppercased())
                    .font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                Spacer()
                Button(role: .destructive) { rows.removeAll { $0.id == r.wrappedValue.id } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                }.accessibilityLabel("Remove")
            }
            Picker("Item", selection: r.itemId) {
                Text("—").tag(Int?.none)
                // One no longer offered (hidden) still shows by its saved name.
                if let id = r.wrappedValue.itemId, !choices.contains(where: { $0.id == id }) {
                    Text(r.wrappedValue.label ?? "#\(id)").tag(Optional(id))
                }
                ForEach(choices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu).labelsHidden()
            .font(Theme.body.weight(.bold)).tint(.black)
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.box, in: .rect(cornerRadius: 8))
            HStack(spacing: 8) {
                Field(label: "Used as") { TextField(layer ? "Mask, separation" : "Glop, sizing", text: r.role) }
                if !layer {
                    Field(label: "Amount") { TextField("", text: r.amount).keyboardType(.decimalPad) }.frame(width: 84)
                    Field(label: "Unit") { TextField("", text: r.unit).autocorrectionDisabled().textInputAutocapitalization(.never) }.frame(width: 96)
                }
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}
