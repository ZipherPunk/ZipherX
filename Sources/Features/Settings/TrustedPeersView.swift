//
//  TrustedPeersView.swift
//  ZipherX
//
//  Created by ZipherX Team on 2025-12-13.
//  FIX #229: Trusted peers management - verified Zclassic nodes for bootstrap
//
//  "We must defend our own privacy if we expect to have any."
//   - Eric Hughes, A Cypherpunk's Manifesto
//

import SwiftUI

// MARK: - Trusted Peers View

struct TrustedPeersView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var trustedPeers: [WalletDatabase.TrustedPeer] = []
    @State private var showAddSheet = false
    @State private var showEditSheet = false
    @State private var selectedPeer: WalletDatabase.TrustedPeer?
    @State private var peerToDelete: WalletDatabase.TrustedPeer?
    @State private var showDeleteConfirm = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with Done button
            toolbarView

            // Header
            headerView

            // Content
            if isLoading {
                loadingView
            } else if trustedPeers.isEmpty {
                emptyStateView
            } else {
                peerListView
            }
        }
        .background(theme.backgroundColor)
        .onAppear {
            loadTrustedPeers()
        }
        .sheet(isPresented: $showAddSheet) {
            AddTrustedPeerSheet(isPresented: $showAddSheet, onSave: loadTrustedPeers)
                .environmentObject(themeManager)
        }
        .sheet(isPresented: $showEditSheet) {
            if let peer = selectedPeer {
                EditTrustedPeerSheet(peer: peer, isPresented: $showEditSheet, onSave: loadTrustedPeers)
                    .environmentObject(themeManager)
            }
        }
        .alert("Delete Trusted Peer?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let peer = peerToDelete {
                    deletePeer(peer)
                }
            }
        } message: {
            if let peer = peerToDelete {
                Text("Remove \(peer.host):\(peer.port) from trusted peers?\n\nThis peer will no longer be used for bootstrap.")
            }
        }
    }

    // MARK: - Load Data

    private func loadTrustedPeers() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let db = WalletDatabase.shared
                let peers = try db.getTrustedPeers()
                await MainActor.run {
                    // FIX #1569: Sort by success rate (higher first)
                    self.trustedPeers = peers.sorted { a, b in
                        let totalA = a.successes + a.failures
                        let totalB = b.successes + b.failures
                        let rateA = totalA > 0 ? Double(a.successes) / Double(totalA) : 0
                        let rateB = totalB > 0 ? Double(b.successes) / Double(totalB) : 0
                        if rateA != rateB { return rateA > rateB }
                        return a.successes > b.successes  // Break ties by total successes
                    }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func deletePeer(_ peer: WalletDatabase.TrustedPeer) {
        do {
            try WalletDatabase.shared.removeTrustedPeer(host: peer.host, port: peer.port)
            loadTrustedPeers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack {
            Text("Trusted Peers")
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
                Text("Verified Zclassic nodes for bootstrap")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                Text("\(trustedPeers.count) peer\(trustedPeers.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary.opacity(0.7))
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

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading trusted peers...")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "shield.checkered")
                .font(.system(size: 48))
                .foregroundColor(theme.textSecondary.opacity(0.5))

            Text("No Trusted Peers")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.textPrimary)

            Text("Add verified Zclassic nodes for\nreliable P2P connections")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: { showAddSheet = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add First Peer")
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

    // MARK: - Peer List

    private var peerListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(trustedPeers, id: \.host) { peer in
                    TrustedPeerRowView(
                        peer: peer,
                        onEdit: {
                            selectedPeer = peer
                            showEditSheet = true
                        },
                        onDelete: {
                            peerToDelete = peer
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

// MARK: - Trusted Peer Row View

struct TrustedPeerRowView: View {
    let peer: WalletDatabase.TrustedPeer
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: peer.isOnion ? "network.badge.shield.half.filled" : "server.rack")
                .font(.system(size: 20))
                .foregroundColor(peer.isOnion ? .purple : .green)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(peer.host)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)

                    Text(":\(peer.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }

                if let notes = peer.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }

                // Stats
                HStack(spacing: 8) {
                    if peer.successes > 0 || peer.failures > 0 {
                        let total = peer.successes + peer.failures
                        let rate = total > 0 ? Double(peer.successes) / Double(total) * 100 : 0
                        Text("\(Int(rate))% success")
                            .foregroundColor(rate > 50 ? .green : .orange)
                    }

                    if let lastConnected = peer.lastConnected {
                        Text("Last: \(lastConnected, style: .relative) ago")
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }

            Spacer()

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
    }
}

// MARK: - Add Trusted Peer Sheet

struct AddTrustedPeerSheet: View {
    @Binding var isPresented: Bool
    var onSave: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var host: String = ""
    @State private var port: String = "8033"
    @State private var notes: String = ""
    @State private var isOnion: Bool = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Header bar with Cancel / Title / Add
            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
                Spacer()
                Text("Add Trusted Peer")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Add") { addPeer() }
                    .buttonStyle(.plain)
                    .foregroundColor(host.isEmpty ? theme.textSecondary : theme.accentColor)
                    .disabled(host.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(theme.borderColor)

            // Fields
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PEER ADDRESS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)

                    TextField("Host (IP or .onion)", text: $host)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                        .disableAutocorrection(true)
                        .onChange(of: host) { newValue in
                            isOnion = newValue.hasSuffix(".onion")
                        }

                    TextField("Port", text: $port)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))

                    TextField("Notes (optional)", text: $notes)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .foregroundColor(theme.textPrimary)
                        .padding(10)
                        .background(theme.surfaceColor)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                }

                Text("Add a verified Zclassic node for reliable bootstrap connections.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textSecondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("EXAMPLES")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                    exampleRow("IPv4", example: "140.174.189.17:8033")
                    exampleRow("IPv6", example: "[2001:db8::1]:8033")
                    exampleRow(".onion", example: "xyz...abc.onion:8033")
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
                    TextField("Host (IP or .onion)", text: $host)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: host) { newValue in
                            isOnion = newValue.hasSuffix(".onion")
                        }

                    TextField("Port", text: $port)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numberPad)

                    TextField("Notes (optional)", text: $notes)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Peer Address")
                } footer: {
                    Text("Add a verified Zclassic node. These peers will be used for reliable bootstrap connections.")
                        .font(.system(size: 11, design: .monospaced))
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        exampleRow("IPv4", example: "140.174.189.17:8033")
                        exampleRow("IPv6", example: "[2001:db8::1]:8033")
                        exampleRow(".onion", example: "xyz...abc.onion:8033")
                    }
                } header: {
                    Text("Examples")
                }
            }
            .navigationTitle("Add Trusted Peer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addPeer() }
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

    private func addPeer() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerPort = UInt16(port) ?? 8033

        guard !trimmedHost.isEmpty else {
            errorMessage = "Host address is required"
            showError = true
            return
        }

        do {
            try WalletDatabase.shared.addTrustedPeer(
                host: trimmedHost,
                port: peerPort,
                isOnion: isOnion,
                notes: notes.isEmpty ? nil : notes
            )
            onSave()
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Edit Trusted Peer Sheet

struct EditTrustedPeerSheet: View {
    let peer: WalletDatabase.TrustedPeer
    @Binding var isPresented: Bool
    var onSave: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var notes: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var theme: AppTheme { themeManager.currentTheme }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
                Spacer()
                Text("Edit Peer")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button("Save") { savePeer() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(theme.borderColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Peer info
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PEER INFORMATION")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.textSecondary)

                        infoRow("Host", value: peer.host)
                        infoRow("Port", value: "\(peer.port)")
                        infoRow("Type", value: peer.isOnion ? "Tor Hidden Service" : "IPv4/IPv6")

                        TextField("Notes", text: $notes)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.textPrimary)
                            .padding(10)
                            .background(theme.surfaceColor)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
                    }

                    // Statistics
                    VStack(alignment: .leading, spacing: 6) {
                        Text("STATISTICS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.textSecondary)

                        infoRow("Successes", value: "\(peer.successes)", color: .green)
                        infoRow("Failures", value: "\(peer.failures)", color: peer.failures > 0 ? .orange : theme.textSecondary)

                        if peer.successes > 0 || peer.failures > 0 {
                            let total = peer.successes + peer.failures
                            let rate = total > 0 ? Double(peer.successes) / Double(total) * 100 : 0
                            infoRow("Success Rate", value: "\(Int(rate))%", color: rate > 50 ? .green : .orange)
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
        .onAppear { notes = peer.notes ?? "" }
        #else
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Host")
                        Spacer()
                        Text(peer.host)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                    }
                    HStack {
                        Text("Port")
                        Spacer()
                        Text("\(peer.port)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                    }
                    TextField("Notes", text: $notes)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Peer Information")
                }

                Section {
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(peer.isOnion ? "Tor Hidden Service" : "IPv4/IPv6")
                            .foregroundColor(theme.textSecondary)
                    }
                    HStack {
                        Text("Successes")
                        Spacer()
                        Text("\(peer.successes)")
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Failures")
                        Spacer()
                        Text("\(peer.failures)")
                            .foregroundColor(peer.failures > 0 ? .orange : theme.textSecondary)
                    }
                    if peer.successes > 0 || peer.failures > 0 {
                        let total = peer.successes + peer.failures
                        let rate = total > 0 ? Double(peer.successes) / Double(total) * 100 : 0
                        HStack {
                            Text("Success Rate")
                            Spacer()
                            Text("\(Int(rate))%")
                                .foregroundColor(rate > 50 ? .green : .orange)
                        }
                    }
                    if let lastConnected = peer.lastConnected {
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
            .navigationTitle("Edit Peer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { savePeer() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .onAppear { notes = peer.notes ?? "" }
        }
        .navigationViewStyle(.stack)
        #endif
    }

    private func infoRow(_ label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(color ?? theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    private func savePeer() {
        // Currently only notes can be edited (host/port are immutable)
        do {
            try WalletDatabase.shared.addTrustedPeer(
                host: peer.host,
                port: peer.port,
                isOnion: peer.isOnion,
                notes: notes.isEmpty ? nil : notes
            )
            onSave()
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TrustedPeersView_Previews: PreviewProvider {
    static var previews: some View {
        TrustedPeersView()
            .environmentObject(ThemeManager.shared)
    }
}
#endif
