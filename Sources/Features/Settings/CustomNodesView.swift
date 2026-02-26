//
//  CustomNodesView.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-09.
//  Custom node management - add IPv4, IPv6, and .onion peers
//
//  "The computer can be used as a tool to liberate and protect people,
//   rather than to control them." - Hal Finney
//

import SwiftUI

// MARK: - Custom Nodes View

struct CustomNodesView: View {
    @ObservedObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var showEditSheet = false
    @State private var selectedNode: UserCustomNode?
    @State private var nodeToDelete: UserCustomNode?
    @State private var showDeleteConfirm = false

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with Done button
            toolbarView

            // Header
            headerView

            // Node list
            if networkManager.customNodes.isEmpty {
                emptyStateView
            } else {
                nodeListView
            }
        }
        .background(theme.backgroundColor)
        .sheet(isPresented: $showAddSheet) {
            AddNodeSheet(isPresented: $showAddSheet)
                .environmentObject(themeManager)
        }
        .sheet(isPresented: $showEditSheet) {
            if let node = selectedNode {
                EditNodeSheet(node: node, isPresented: $showEditSheet)
                    .environmentObject(themeManager)
            }
        }
        .alert("Delete Node?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let node = nodeToDelete {
                    _ = networkManager.deleteCustomNode(id: node.id)
                }
            }
        } message: {
            if let node = nodeToDelete {
                Text("Remove \(node.label) from your custom nodes?")
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack {
            Text("Custom Nodes")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surfaceColor)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your own IPv4, IPv6, or .onion peers")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add")
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.primaryColor.opacity(0.15))
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.backgroundColor)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundColor(theme.textSecondary.opacity(0.5))

            Text("No Custom Nodes")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text("Add your own trusted nodes for\nenhanced privacy and reliability")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: { showAddSheet = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add First Node")
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(theme.primaryColor)
                .cornerRadius(8)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    // MARK: - Node List

    private var nodeListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(networkManager.customNodes) { node in
                    NodeRowView(
                        node: node,
                        onToggle: {
                            _ = networkManager.toggleCustomNode(id: node.id)
                        },
                        onEdit: {
                            selectedNode = node
                            showEditSheet = true
                        },
                        onDelete: {
                            nodeToDelete = node
                            showDeleteConfirm = true
                        }
                    )
                    .environmentObject(themeManager)
                }
            }
            .padding()
        }
    }
}

// MARK: - Node Row View

struct NodeRowView: View {
    let node: UserCustomNode
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: node.addressType.icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(node.label)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)

                Text("\(node.host):\(node.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)

                // Stats
                if node.connectionAttempts > 0 {
                    HStack(spacing: 8) {
                        Text("\(Int(node.successRate))% success")
                            .foregroundColor(node.successRate > 50 ? .green : .orange)
                        Text("\(node.connectionAttempts) attempts")
                            .foregroundColor(theme.textSecondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { node.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .scaleEffect(0.8)

            // Actions menu
            Menu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .padding(12)
        .background(theme.surfaceColor)
        .cornerRadius(12)
        .opacity(node.isEnabled ? 1.0 : 0.6)
    }

    private var iconColor: Color {
        switch node.addressType {
        case .onion: return .purple
        case .ipv6: return .blue
        case .ipv4: return .green
        }
    }
}

// MARK: - Add Node Sheet

struct AddNodeSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var host: String = ""
    @State private var port: String = "8033"
    @State private var label: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
                Spacer()
                Text("Add Node")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Add") { addNode() }
                    .buttonStyle(.plain)
                    .foregroundColor(host.isEmpty ? theme.textSecondary : theme.accentColor)
                    .disabled(host.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(theme.borderColor)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NODE ADDRESS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    TextField("Address (IP or .onion)", text: $host)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                        .disableAutocorrection(true)

                    TextField("Port", text: $port)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))

                    TextField("Label (optional)", text: $label)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                }

                Text("Supports IPv4, IPv6, or Tor v3 onion addresses.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("EXAMPLES")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                    exampleRow("IPv4", example: "185.205.246.161")
                    exampleRow("IPv6", example: "2001:db8::1")
                    exampleRow(".onion", example: "xyz...abc.onion")
                }

                Spacer()
            }
            .padding(20)
        }
        .background(theme.backgroundColor)
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 520,
               minHeight: 340, idealHeight: 400, maxHeight: 480)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        #else
        NavigationView {
            Form {
                Section {
                    // FIX #1593: Paste button for iOS — SwiftUI TextField long-press paste
                    // is unreliable in Form/Sheet context. Explicit button guarantees paste works.
                    HStack {
                        TextField("Address (IP or .onion)", text: $host)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(action: {
                            if let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty {
                                host = clipboard
                            }
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("Port", text: $port)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numberPad)

                    TextField("Label (optional)", text: $label)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Node Address")
                } footer: {
                    Text("Supports IPv4 (192.168.1.1), IPv6 (::1), or Tor v3 onion addresses (xxx.onion)")
                        .font(.system(size: 11, design: .monospaced))
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        exampleRow("IPv4", example: "185.205.246.161")
                        exampleRow("IPv6", example: "2001:db8::1")
                        exampleRow(".onion", example: "xyz...abc.onion")
                    }
                } header: {
                    Text("Examples")
                }
            }
            .navigationTitle("Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addNode() }
                        .disabled(host.isEmpty)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
        .navigationViewStyle(.stack)
        #endif
    }

    private func exampleRow(_ type: String, example: String) -> some View {
        HStack {
            Text(type)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .frame(width: 50, alignment: .leading)
            Text(example)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textPrimary)
        }
    }

    private func addNode() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodePort = UInt16(port) ?? 8033

        if networkManager.addCustomNode(host: trimmedHost, port: nodePort, label: label) {
            isPresented = false
        } else {
            errorMessage = "Invalid address format or node already exists"
            showError = true
        }
    }
}

// MARK: - Edit Node Sheet

struct EditNodeSheet: View {
    let node: UserCustomNode
    @Binding var isPresented: Bool
    @ObservedObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var label: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
                Spacer()
                Text("Edit Node")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Save") { saveNode() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(theme.borderColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NODE ADDRESS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.textSecondary)

                        TextField("Address", text: $host)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.textPrimary)
                            .padding(10)
                            .background(theme.surfaceColor)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                            .disableAutocorrection(true)

                        TextField("Port", text: $port)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.textPrimary)
                            .padding(10)
                            .background(theme.surfaceColor)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))

                        TextField("Label", text: $label)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.textPrimary)
                            .padding(10)
                            .background(theme.surfaceColor)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("STATISTICS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.textSecondary)

                        editInfoRow("Type", value: node.addressType.rawValue)

                        if node.connectionAttempts > 0 {
                            editInfoRow("Success Rate", value: "\(Int(node.successRate))%", color: node.successRate > 50 ? .green : .orange)
                            editInfoRow("Attempts", value: "\(node.connectionAttempts)")
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }
        }
        .background(theme.backgroundColor)
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 520,
               minHeight: 340, idealHeight: 400, maxHeight: 480)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            host = node.host
            port = String(node.port)
            label = node.label
        }
        #else
        NavigationView {
            Form {
                Section {
                    // FIX #1593: Paste button for iOS
                    HStack {
                        TextField("Address", text: $host)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(action: {
                            if let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty {
                                host = clipboard
                            }
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("Port", text: $port)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numberPad)

                    TextField("Label", text: $label)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Edit Node")
                }

                Section {
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(node.addressType.rawValue)
                            .foregroundColor(theme.textSecondary)
                    }
                    if node.connectionAttempts > 0 {
                        HStack {
                            Text("Success Rate")
                            Spacer()
                            Text("\(Int(node.successRate))%")
                                .foregroundColor(node.successRate > 50 ? .green : .orange)
                        }
                        HStack {
                            Text("Attempts")
                            Spacer()
                            Text("\(node.connectionAttempts)")
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                    if let lastConnected = node.lastConnected {
                        HStack {
                            Text("Last Connected")
                            Spacer()
                            Text(lastConnected, style: .relative)
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                } header: {
                    Text("Statistics")
                }
            }
            .navigationTitle("Edit Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveNode() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                host = node.host
                port = String(node.port)
                label = node.label
            }
        }
        .navigationViewStyle(.stack)
        #endif
    }

    private func editInfoRow(_ label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(color ?? theme.textPrimary)
        }
        .padding(.vertical, 4)
    }

    private func saveNode() {
        var updatedNode = node
        updatedNode.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedNode.port = UInt16(port) ?? 8033
        updatedNode.label = label.isEmpty ? updatedNode.host : label

        if updatedNode.isValid {
            _ = networkManager.updateCustomNode(updatedNode)
            isPresented = false
        } else {
            errorMessage = "Invalid address format"
            showError = true
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CustomNodesView_Previews: PreviewProvider {
    static var previews: some View {
        CustomNodesView()
            .environmentObject(ThemeManager.shared)
    }
}
#endif
