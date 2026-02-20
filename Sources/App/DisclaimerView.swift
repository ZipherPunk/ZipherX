import SwiftUI

/// Legal Disclaimer View - Shown on first launch
/// Provides important legal protections for the developer
struct DisclaimerView: View {
    @Binding var hasAcceptedDisclaimer: Bool
    @State private var hasScrolledToBottom: Bool = false
    @State private var showAcceptButton: Bool = false

    // Timer to enable accept button after reading time
    @State private var readingTimeElapsed: Bool = false

    // FIX #1447: Track scroll position via global coordinates instead of onAppear
    // (onAppear fires immediately on macOS because ScrollView eagerly renders all content)
    @State private var scrollViewBottomEdge: CGFloat = 0

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                headerView

                // Scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        disclaimerContent

                        // FIX #1447: Bottom anchor reports position via preference key
                        // instead of onAppear (which fires immediately on macOS)
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: BottomAnchorYKey.self,
                                           value: geo.frame(in: .global).maxY)
                        }
                        .frame(height: 1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .overlay(
                    // FIX #1447: Track the scroll view's visible bottom edge
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            scrollViewBottomEdge = geo.frame(in: .global).maxY
                        }
                    }
                )
                .onPreferenceChange(BottomAnchorYKey.self) { bottomY in
                    // FIX #1447: Bottom anchor is visible when its global Y <= scroll view bottom edge
                    if scrollViewBottomEdge > 0 && bottomY <= scrollViewBottomEdge + 30 && !hasScrolledToBottom {
                        withAnimation(.easeIn(duration: 0.3)) {
                            hasScrolledToBottom = true
                        }
                    }
                }

                // Accept button area
                acceptButtonArea
            }
        }
        .onAppear {
            // Enable accept button after 5 seconds (minimum reading time)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    readingTimeElapsed = true
                }
            }
        }
    }

    /// FIX #1447: Preference key for tracking bottom anchor's global Y position during scroll
    private struct BottomAnchorYKey: PreferenceKey {
        static var defaultValue: CGFloat = .greatestFiniteMagnitude
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            // Logo
            Image("ZipherpunkLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)

            Text("ZIPHERX")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(NeonColors.primary)

            Text("IMPORTANT LEGAL NOTICE")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(NeonColors.primary.opacity(0.8))
                .padding(.top, 4)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    // MARK: - Disclaimer Content

    private var disclaimerContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Section 1: Nature of Software
            sectionView(
                title: "1. OPEN SOURCE SOFTWARE",
                content: """
                ZipherX is free, open-source software distributed under the MIT License. \
                This application is a tool that enables users to interact with the Zclassic blockchain network. \
                The software is provided "as is" without any representations or warranties of any kind, \
                either express or implied.
                """
            )

            // Section 2: Privacy Rights
            sectionView(
                title: "2. PRIVACY AS A FUNDAMENTAL RIGHT",
                icon: "lock.shield.fill",
                content: """
                Privacy is a fundamental human right recognized by the United Nations Declaration of Human Rights, \
                the International Covenant on Civil and Political Rights, and numerous other international and regional treaties. \
                ZipherX implements cryptographic privacy features that exist to protect this fundamental right. \
                Financial privacy is essential for personal security, protection from discrimination, \
                and the preservation of human dignity.
                """
            )

            // Section 3: Non-Custodial
            sectionView(
                title: "3. NON-CUSTODIAL ARCHITECTURE",
                icon: "key.fill",
                content: """
                ZipherX is a non-custodial wallet. The developer(s) of this software:

                \u{2022} Have NO access to your private keys or funds
                \u{2022} Cannot freeze, seize, or control your assets
                \u{2022} Cannot reverse, cancel, or modify any transactions
                \u{2022} Do NOT collect, store, or transmit any personal data
                \u{2022} Do NOT operate any central servers or maintain any logs

                Your keys are stored exclusively on your device using hardware-backed encryption.
                """
            )

            // Section 4: Decentralization
            sectionView(
                title: "4. DECENTRALIZED NETWORK",
                icon: "network",
                content: """
                ZipherX connects directly to the peer-to-peer Zclassic network. \
                There is no central server, no intermediary, and no single point of control. \
                The software is merely an interface to interact with a decentralized, \
                permissionless blockchain network that operates independently of any individual or organization.
                """
            )

            // Section 5: User Responsibility
            sectionView(
                title: "5. USER RESPONSIBILITY",
                icon: "person.fill.checkmark",
                content: """
                By using this software, you acknowledge and agree that:

                \u{2022} YOU are solely responsible for compliance with all applicable laws and regulations in your jurisdiction
                \u{2022} YOU are responsible for securing your recovery phrase and private keys
                \u{2022} YOU are responsible for verifying transaction details before confirmation
                \u{2022} YOU understand that blockchain transactions are irreversible
                \u{2022} YOU accept all risks associated with using cryptocurrency software
                """
            )

            // Section 6: No Financial Advice
            sectionView(
                title: "6. NO FINANCIAL ADVICE",
                icon: "dollarsign.circle",
                content: """
                Nothing in this software constitutes financial, investment, legal, or tax advice. \
                The developer(s) are not financial advisors. \
                You should consult qualified professionals for any financial decisions. \
                Cryptocurrency values are volatile and you may lose some or all of your investment.
                """
            )

            // Section 7: Limitation of Liability
            sectionView(
                title: "7. LIMITATION OF LIABILITY",
                content: """
                TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT SHALL THE DEVELOPERS, \
                CONTRIBUTORS, OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, \
                WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, \
                OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

                This includes but is not limited to: loss of funds, loss of profits, loss of data, \
                business interruption, or any indirect, incidental, special, or consequential damages.
                """
            )

            // Section 8: Intended Use
            sectionView(
                title: "8. INTENDED USE",
                icon: "checkmark.shield.fill",
                content: """
                This software is intended for legitimate privacy-preserving financial transactions. \
                Legitimate uses include but are not limited to:

                \u{2022} Protecting personal financial information from data breaches
                \u{2022} Preventing financial surveillance and profiling
                \u{2022} Protecting business confidentiality
                \u{2022} Donations to sensitive causes (journalism, activism, charity)
                \u{2022} Personal security in high-risk environments

                The existence of privacy tools does not imply endorsement of any illegal activity.
                """
            )

            // Section 9: Jurisdiction
            sectionView(
                title: "9. JURISDICTIONAL NOTICE",
                icon: "globe",
                content: """
                Cryptocurrency regulations vary by jurisdiction. Some features of this software may not be \
                legal in all jurisdictions. It is YOUR responsibility to ensure that your use of this \
                software complies with all applicable laws in your location. \
                The developer(s) make no representations regarding the legality of this software in any jurisdiction.
                """
            )

            // Section 10: Beta / Experimental Software
            sectionView(
                title: "10. EXPERIMENTAL SOFTWARE",
                icon: "exclamationmark.triangle.fill",
                content: """
                ZipherX is beta software under active development. It may contain bugs, errors, \
                defects, or incomplete features that could result in loss of funds, corrupted data, \
                or unexpected behavior. There is NO guarantee that the software will function correctly, \
                continuously, or without interruption. \
                DO NOT use this software with funds you cannot afford to lose entirely and permanently.
                """
            )

            // Section 11: Indemnification
            sectionView(
                title: "11. INDEMNIFICATION",
                content: """
                BY USING THIS SOFTWARE, YOU AGREE TO INDEMNIFY, DEFEND, AND HOLD HARMLESS THE DEVELOPERS, \
                CONTRIBUTORS, AND COPYRIGHT HOLDERS FROM AND AGAINST ANY AND ALL CLAIMS, LIABILITIES, \
                DAMAGES, LOSSES, COSTS, AND EXPENSES (INCLUDING REASONABLE LEGAL FEES) ARISING OUT OF OR \
                RELATED TO YOUR USE OR MISUSE OF THIS SOFTWARE, YOUR VIOLATION OF THIS DISCLAIMER, \
                OR YOUR VIOLATION OF ANY APPLICABLE LAW OR REGULATION.
                """
            )

            // Section 12: Third-Party Services & Force Majeure
            sectionView(
                title: "12. THIRD-PARTY SERVICES & FORCE MAJEURE",
                icon: "link",
                content: """
                ZipherX relies on third-party decentralized services including but not limited to: \
                the Zclassic blockchain network, the Tor anonymity network, and peer-to-peer node operators. \
                The developer(s) have NO control over these networks and accept NO responsibility for:

                \u{2022} Network outages, congestion, or failures
                \u{2022} Blockchain forks, reorganizations, or protocol changes
                \u{2022} Tor network disruptions or de-anonymization attacks
                \u{2022} Malicious peer nodes or Sybil attacks
                \u{2022} Acts of God, war, government action, or any event beyond reasonable control

                Your use of these third-party networks is entirely at your own risk.
                """
            )

            // Section 13: Backup Warning
            sectionView(
                title: "13. BACKUP WARNING",
                icon: "externaldrive.fill.badge.exclamationmark",
                content: """
                YOU MUST BACK UP YOUR WALLET BEFORE INSTALLING OR USING ZIPHERX. \
                If you are running an existing Zclassic full node or any other wallet software, \
                back up ALL wallet files, private keys, and spending keys BEFORE proceeding. \
                ZipherX's Full Node mode connects to your local node — software bugs could potentially \
                overwrite, corrupt, or delete existing wallet data. This applies to both P2P mode and \
                Full Node mode. The developer(s) accept NO responsibility for loss of funds or data \
                resulting from failure to maintain adequate backups. \
                ALWAYS maintain independent, offline backups of your keys and wallet files. \
                Never rely solely on any single piece of software to protect your funds.
                """
            )

            // Section 14: Voluntary Contributions
            sectionView(
                title: "14. VOLUNTARY CONTRIBUTIONS",
                icon: "person.3.fill",
                content: """
                All contributions to the development of ZipherX — including but not limited to code, \
                documentation, design, testing, bug reports, translations, and feedback — are made \
                on a strictly voluntary and unpaid basis. Contributing to this project does NOT entitle \
                any contributor to:\n\n\
                \u{2022} Any form of compensation, payment, or remuneration\n\
                \u{2022} Any ownership, equity, or intellectual property rights in the software\n\
                \u{2022} Any share of revenue, profits, donations, or financial benefits\n\
                \u{2022} Any employment, contractor, or business relationship with the developer(s)\n\
                \u{2022} Any decision-making authority over the project's direction\n\n\
                Contributions are made under the terms of the MIT License. By contributing, you agree \
                that your contributions become part of the open-source project with no expectation of \
                compensation or ownership of any kind, now or in the future.
                """
            )

            // Cypherpunk quote
            quoteView

            // Final acknowledgment
            acknowledgmentView
        }
    }

    private func sectionView(title: String, icon: String? = nil, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let iconName = icon {
                    Image(systemName: iconName)
                        .foregroundColor(NeonColors.primary)
                        .font(.system(size: 14))
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(NeonColors.primary)
            }

            Text(content)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NeonColors.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NeonColors.primary.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var quoteView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\"Privacy is necessary for an open society in the electronic age. Privacy is not secrecy. A private matter is something one doesn't want the whole world to know, but a secret matter is something one doesn't want anybody to know. Privacy is the power to selectively reveal oneself to the world.\"")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .italic()
                .foregroundColor(NeonColors.primary.opacity(0.9))
                .lineSpacing(4)

            Text("- Eric Hughes, A Cypherpunk's Manifesto (1993)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(NeonColors.primary.opacity(0.7))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NeonColors.primary.opacity(0.08))
        )
    }

    private var acknowledgmentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BY PROCEEDING, YOU ACKNOWLEDGE THAT:")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                acknowledgmentItem("You have read and understood all 14 sections of this disclaimer")
                acknowledgmentItem("You are at least 18 years of age or the age of majority in your jurisdiction")
                acknowledgmentItem("You accept full responsibility for your use of this software")
                acknowledgmentItem("You will comply with all applicable laws in your jurisdiction")
                acknowledgmentItem("You understand the risks of using cryptocurrency and beta software")
                acknowledgmentItem("You agree to the indemnification terms in Section 11")
                acknowledgmentItem("You understand that third-party networks are outside the developer's control")
                acknowledgmentItem("You have backed up all existing wallet files and keys before using this software")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func acknowledgmentItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.square")
                .foregroundColor(NeonColors.primary)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.8))
        }
    }

    // MARK: - Accept Button Area

    private var acceptButtonArea: some View {
        VStack(spacing: 12) {
            Divider()
                .background(NeonColors.primary.opacity(0.3))

            if !hasScrolledToBottom {
                Text("Please scroll down to read the entire disclaimer")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(NeonColors.primary.opacity(0.6))
                    .padding(.top, 8)
            }

            Button(action: {
                // Store acceptance with timestamp
                UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "disclaimerAcceptedTimestamp")
                UserDefaults.standard.set(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", forKey: "disclaimerAcceptedVersion")

                withAnimation(.easeInOut(duration: 0.3)) {
                    hasAcceptedDisclaimer = true
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 16))
                    Text("I ACCEPT AND UNDERSTAND")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                }
                .foregroundColor(canAccept ? .black : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(canAccept ? NeonColors.primary : NeonColors.primary.opacity(0.3))
                )
            }
            .disabled(!canAccept)
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(Color.black)
    }

    private var canAccept: Bool {
        hasScrolledToBottom && readingTimeElapsed
    }
}

// MARK: - Preview

#Preview {
    DisclaimerView(hasAcceptedDisclaimer: .constant(false))
}
