import SwiftUI

#if os(macOS)

/// Transaction history view for Full Node wallet.dat mode
/// FIX #286 v7: Loads ALL transactions with pagination
struct RPCTransactionHistoryView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var rpcWallet = RPCWalletOperations.shared

    @State private var transactions: [WalletTransaction] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTransaction: WalletTransaction?

    // FIX #286 v7: Pagination
    @State private var currentPage: Int = 0
    private let pageSize: Int = 50

    // FIX #286 v7: Filter tabs for z/t addresses
    @State private var selectedFilter: AddressFilter = .all

    // FIX #286 v15: Real rescan progress from debug.log
    @State private var debugLogRescanBlock: Int = 0
    @State private var debugLogRescanProgress: Double = 0

    enum AddressFilter: String, CaseIterable {
        case all = "All"
        case shielded = "Shielded (Z)"
        case transparent = "Transparent (T)"
    }

    private var theme: AppTheme { themeManager.currentTheme }

    // Filter transactions by address type
    private var filteredTransactions: [WalletTransaction] {
        switch selectedFilter {
        case .all:
            return transactions
        case .shielded:
            // FIX #1269: Also match "Shielded" address label (used for discovered z-sends)
            return transactions.filter { $0.address.hasPrefix("zs") || $0.address.hasPrefix("zc") || $0.address.isEmpty || $0.address == "Shielded" }
        case .transparent:
            return transactions.filter { $0.address.hasPrefix("t1") || $0.address.hasPrefix("t3") }
        }
    }

    // Computed properties for pagination
    private var totalPages: Int {
        max(1, (filteredTransactions.count + pageSize - 1) / pageSize)
    }

    private var currentPageTransactions: [WalletTransaction] {
        let start = currentPage * pageSize
        let end = min(start + pageSize, filteredTransactions.count)
        return start < filteredTransactions.count ? Array(filteredTransactions[start..<end]) : []
    }

    // Check if address is transparent (t-address)
    private func isTransparent(_ address: String) -> Bool {
        address.hasPrefix("t1") || address.hasPrefix("t3")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transaction History")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button(action: {
                    Task {
                        await loadTransactions()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(theme.primaryColor)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(theme.surfaceColor)

            // FIX #286 v7: Filter tabs for z/t addresses
            HStack(spacing: 0) {
                ForEach(AddressFilter.allCases, id: \.self) { filter in
                    Button(action: {
                        selectedFilter = filter
                        currentPage = 0  // Reset to first page on filter change
                    }) {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                if filter == .shielded {
                                    Image(systemName: "shield.fill")
                                        .font(.system(size: 10))
                                } else if filter == .transparent {
                                    Image(systemName: "eye.fill")
                                        .font(.system(size: 10))
                                }
                                Text(filter.rawValue)
                                    .font(theme.captionFont)
                            }
                            .foregroundColor(selectedFilter == filter ? theme.primaryColor : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            // Underline for selected filter
                            Rectangle()
                                .fill(selectedFilter == filter ? theme.primaryColor : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(theme.surfaceColor)

            Divider()
                .background(theme.borderColor)

            // Content
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading transactions...")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if let error = errorMessage {
                VStack {
                    Spacer()
                    // FIX #286 v15: Better UX for HTTP 500 with real progress from debug.log
                    if error.contains("HTTP 500") || error.contains("500") {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(statusBlue)

                        if debugLogRescanProgress > 0 {
                            // FIX #286 v16: Show real progress with 65% bug warning
                            if debugLogRescanProgress >= 0.60 {
                                Text("Finishing Rescan...")
                                    .font(theme.titleFont)
                                    .foregroundColor(statusBlue)
                                    .padding(.top, 8)

                                Text("~\(Int(debugLogRescanProgress * 100))%")
                                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                                    .foregroundColor(statusBlue)
                                    .padding(.top, 4)

                                // Warning about known bug
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.warningColor)
                                    Text("Known Zclassic bug: Progress stops at ~65%")
                                        .font(theme.captionFont)
                                        .foregroundColor(theme.warningColor)
                                }
                                .padding(.top, 8)

                                Text("Rescan is continuing in the background.")
                                    .font(theme.captionFont)
                                    .foregroundColor(theme.textSecondary)
                                    .padding(.top, 4)
                            } else {
                                Text("Rescanning Blockchain")
                                    .font(theme.titleFont)
                                    .foregroundColor(statusBlue)
                                    .padding(.top, 8)

                                Text("\(Int(debugLogRescanProgress * 100))%")
                                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                                    .foregroundColor(statusBlue)
                                    .padding(.top, 4)

                                // Progress bar
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(theme.borderColor)
                                            .frame(height: 12)
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(statusBlue)
                                            .frame(width: max(0, geometry.size.width * debugLogRescanProgress), height: 12)
                                    }
                                }
                                .frame(height: 12)
                                .padding(.horizontal, 60)
                                .padding(.top, 8)

                                Text("Block \(debugLogRescanBlock.formatted())")
                                    .font(theme.monoFont)
                                    .foregroundColor(theme.textSecondary)
                                    .padding(.top, 4)
                            }

                            Text("Transaction history will be available when complete.")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                                .padding(.top, 8)
                        } else {
                            Text("Daemon Busy")
                                .font(theme.titleFont)
                                .foregroundColor(statusBlue)
                                .padding(.top, 8)
                            Text("The daemon is likely rescanning the blockchain.")
                                .font(theme.bodyFont)
                                .foregroundColor(theme.textSecondary)
                                .padding(.top, 4)
                            Text("This can take several hours. Transaction history will be available when complete.")
                                .font(theme.captionFont)
                                .foregroundColor(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .padding(.top, 4)
                        }
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(theme.errorColor)
                        Text(error)
                            .font(theme.bodyFont)
                            .foregroundColor(theme.errorColor)
                            .padding(.top, 8)
                    }
                    Button("Retry") {
                        Task {
                            parseDebugLogForRescanProgress()
                            await loadTransactions()
                        }
                    }
                    .buttonStyle(System7ButtonStyle())
                    .padding(.top)
                    Spacer()
                }
                .onAppear {
                    // FIX #286 v15: Parse debug.log when error shown
                    if error.contains("HTTP 500") || error.contains("500") {
                        parseDebugLogForRescanProgress()
                    }
                }
            } else if transactions.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundColor(theme.textSecondary)
                    Text("No transactions yet")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // FIX #286 v7: Pagination controls at top
                    paginationControls
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(theme.surfaceColor)

                    Divider()
                        .background(theme.borderColor)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(currentPageTransactions) { tx in
                                transactionRow(tx)
                                    .onTapGesture {
                                        selectedTransaction = tx
                                    }
                            }
                        }
                        .padding()
                    }

                    // FIX #286 v7: Pagination controls at bottom too
                    Divider()
                        .background(theme.borderColor)

                    paginationControls
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(theme.surfaceColor)
                }
            }
        }
        .task {
            await loadTransactions()
        }
        .sheet(item: $selectedTransaction) { tx in
            transactionDetailSheet(tx)
        }
    }

    // MARK: - Transaction Row

    // FIX #286 v12: Darker amber for better visibility
    private let transparentAmber = Color(red: 0.8, green: 0.5, blue: 0.0)
    // FIX #286 v14: Blue for status messages (better visibility)
    private let statusBlue = Color(red: 0.2, green: 0.4, blue: 0.8)

    private func transactionRow(_ tx: WalletTransaction) -> some View {
        // FIX #286 v7: Different background colors for z vs t addresses
        let isTAddress = isTransparent(tx.address)
        let bgColor = isTAddress
            ? transparentAmber.opacity(0.08)  // Amber tint for transparent
            : theme.surfaceColor               // Normal for shielded

        // FIX #1275: Use explicit green/red — theme.successColor and theme.errorColor
        // are Color.black in System 7 theme, making the arrow backgrounds grey.
        let txGreen = Color(red: 0.1, green: 0.7, blue: 0.2)
        let txRed = Color(red: 0.85, green: 0.15, blue: 0.15)

        return HStack(spacing: 12) {
            // Direction icon + address type indicator
            ZStack {
                Circle()
                    .fill(tx.type == .received ? txGreen.opacity(0.2) : txRed.opacity(0.2))
                    .frame(width: 36, height: 36)

                Image(systemName: tx.type == .received ? "arrow.down" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(tx.type == .received ? txGreen : txRed)

                // FIX #286 v7: Address type badge
                if isTAddress {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 8))
                        .foregroundColor(transparentAmber)
                        .offset(x: 12, y: 12)
                } else if !tx.address.isEmpty {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 8))
                        .foregroundColor(theme.primaryColor)
                        .offset(x: 12, y: 12)
                }
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tx.type == .received ? "Received" : "Sent")
                        .font(theme.bodyFont)
                        .foregroundColor(theme.textPrimary)

                    // FIX #286 v7: Show address type badge
                    if isTAddress {
                        Text("T")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(transparentAmber)
                            .cornerRadius(3)
                    }

                    if tx.confirmations == 0 {
                        Text("Pending")
                            .font(theme.captionFont)
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.warningColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                Text(formatDate(tx.timestamp))
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            // Amount — FIX #1275: Use explicit green/red (theme colors are black in System 7)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(tx.type == .received ? "+" : "-")\(formatBalance(tx.amount))")
                    .font(theme.monoFont)
                    .foregroundColor(tx.type == .received ? txGreen : txRed)

                if tx.confirmations > 0 {
                    Text("\(tx.confirmations) conf")
                        .font(theme.captionFont)
                        .foregroundColor(theme.textSecondary)
                }
            }

            Image(systemName: "chevron.right")
                .foregroundColor(theme.textSecondary)
        }
        .padding()
        .background(bgColor)  // FIX #286 v7: Different bg for t-addresses
        .cornerRadius(theme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(isTAddress ? transparentAmber.opacity(0.3) : theme.borderColor, lineWidth: theme.borderWidth)
        )
    }

    // MARK: - Transaction Detail Sheet

    private func transactionDetailSheet(_ tx: WalletTransaction) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transaction Details")
                    .font(theme.titleFont)
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Button("Done") {
                    selectedTransaction = nil
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.primaryColor)
            }
            .padding()
            .background(theme.surfaceColor)

            Divider()
                .background(theme.borderColor)

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    // Amount — FIX #1275: Explicit green/red
                    let detailGreen = Color(red: 0.1, green: 0.7, blue: 0.2)
                    let detailRed = Color(red: 0.85, green: 0.15, blue: 0.15)
                    VStack(spacing: 4) {
                        Text("\(tx.type == .received ? "+" : "-")\(formatBalance(tx.amount))")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(tx.type == .received ? detailGreen : detailRed)

                        Text(tx.type == .received ? "Received" : "Sent")
                            .font(theme.bodyFont)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding()

                    // Details
                    VStack(spacing: 12) {
                        detailRow("Transaction ID", value: tx.txid, copyable: true)
                        detailRow("Date", value: formatDate(tx.timestamp))
                        detailRow("Confirmations", value: "\(tx.confirmations)")

                        if let height = tx.height {
                            detailRow("Block Height", value: "\(height)")
                        }

                        if !tx.address.isEmpty {
                            detailRow("Address", value: tx.address, copyable: true)
                        }

                        if tx.fee > 0 {
                            detailRow("Fee", value: formatBalance(tx.fee))
                        }

                        if let memo = tx.memo, !memo.isEmpty {
                            detailRow("Memo", value: memo)
                        }
                    }
                    .padding()
                    .background(theme.surfaceColor)
                    .cornerRadius(theme.cornerRadius)
                }
                .padding()
            }
        }
        .frame(minWidth: 550, idealWidth: 600, minHeight: 500)
        .background(theme.backgroundColor)
    }

    // FIX #1271: Improved detail row — horizontal scroll for long values, copy button on label line
    private func detailRow(_ label: String, value: String, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)

                Spacer()

                if copyable {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(theme.primaryColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if copyable {
                // FIX #1271: Horizontal scroll for long txids/addresses instead of wrapping
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(value)
                        .font(theme.monoFont)
                        .foregroundColor(theme.textPrimary)
                        .textSelection(.enabled)
                }
            } else {
                Text(value)
                    .font(theme.monoFont)
                    .foregroundColor(theme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pagination Controls

    private var paginationControls: some View {
        HStack {
            // Total count with filter info
            if selectedFilter == .all {
                Text("\(transactions.count) transactions")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            } else {
                Text("\(filteredTransactions.count) of \(transactions.count)")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            // Page navigation
            HStack(spacing: 8) {
                Button(action: { currentPage = 0 }) {
                    Image(systemName: "chevron.left.2")
                }
                .disabled(currentPage == 0)

                Button(action: { currentPage = max(0, currentPage - 1) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)

                Text("Page \(currentPage + 1) of \(totalPages)")
                    .font(theme.captionFont)
                    .foregroundColor(theme.textPrimary)

                Button(action: { currentPage = min(totalPages - 1, currentPage + 1) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)

                Button(action: { currentPage = totalPages - 1 }) {
                    Image(systemName: "chevron.right.2")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryColor)
        }
    }

    // MARK: - Data Loading

    private func loadTransactions() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            currentPage = 0
        }

        do {
            print("📜 FIX #286 v7: RPCTransactionHistoryView - loading ALL transactions...")

            // FIX #286 v7: Load ALL transactions (no limit)
            let txs = try await rpcWallet.getTransactionHistory(address: nil, limit: 10000)

            // FIX #286 v7: Log transaction summary
            let sentCount = txs.filter { $0.type == .sent }.count
            let receivedCount = txs.filter { $0.type == .received }.count
            let confirmedCount = txs.filter { $0.confirmations > 0 }.count
            let pendingCount = txs.filter { $0.confirmations == 0 }.count
            print("📜 FIX #286 v7: Loaded \(txs.count) transactions:")
            print("   - Sent: \(sentCount), Received: \(receivedCount)")
            print("   - Confirmed: \(confirmedCount), Pending: \(pendingCount)")

            if let first = txs.first {
                print("📜 FIX #286 v7: First TX: type=\(first.type.rawValue), amount=\(first.amount), conf=\(first.confirmations), height=\(first.height ?? 0)")
            }

            await MainActor.run {
                // Sort by timestamp descending (newest first)
                transactions = txs.sorted { $0.timestamp > $1.timestamp }
                isLoading = false
            }
        } catch is CancellationError {
            // FIX #854: Task cancellation is normal SwiftUI behavior (view dismissed/recreated)
            // Don't log as error or show error message
            await MainActor.run {
                isLoading = false
            }
        } catch {
            print("❌ FIX #286 v7: RPCTransactionHistoryView - error: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Helpers

    private func formatBalance(_ zatoshis: UInt64) -> String {
        let zcl = Double(zatoshis) / 100_000_000.0
        return String(format: "%.8f ZCL", zcl)
    }

    private static let cachedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        return Self.cachedDateFormatter.string(from: date)
    }

    // FIX #286 v15: Parse debug.log for real rescan progress
    // Format: "Still rescanning. At block 2168578. Progress=0.522371"
    private func parseDebugLogForRescanProgress() {
        let debugLogPath = NSString(string: "~/Library/Application Support/Zclassic/debug.log").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: debugLogPath) else {
            print("📜 FIX #286 v15: debug.log not found")
            return
        }

        do {
            // Read last 10KB of file
            let fileURL = URL(fileURLWithPath: debugLogPath)
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            let fileSize = try fileHandle.seekToEnd()

            let readSize: UInt64 = min(fileSize, 10240)
            try fileHandle.seek(toOffset: fileSize - readSize)
            let data = fileHandle.readData(ofLength: Int(readSize))
            fileHandle.closeFile()

            guard let content = String(data: data, encoding: .utf8) else { return }

            // Find the last "Still rescanning" line
            let lines = content.components(separatedBy: "\n").reversed()
            for line in lines {
                if line.contains("Still rescanning") {
                    if let blockRange = line.range(of: "At block "),
                       let progressRange = line.range(of: "Progress=") {
                        let blockStart = line[blockRange.upperBound...]
                        if let blockEnd = blockStart.firstIndex(of: ".") {
                            let blockStr = String(blockStart[..<blockEnd])
                            if let block = Int(blockStr) {
                                debugLogRescanBlock = block
                            }
                        }

                        let progressStr = String(line[progressRange.upperBound...])
                        if let progress = Double(progressStr) {
                            debugLogRescanProgress = progress
                        }

                        print("📜 FIX #286 v15: Parsed debug.log - Block \(debugLogRescanBlock), Progress \(Int(debugLogRescanProgress * 100))%")
                        return
                    }
                }
            }
        } catch {
            print("📜 FIX #286 v15: Error reading debug.log: \(error.localizedDescription)")
        }
    }
}

#endif
