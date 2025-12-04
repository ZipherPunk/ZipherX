# ZipherX TestFlight Beta Release Guide

## Pre-Release Checklist

### 1. Code Preparation

- [ ] **Remove all debug logging** - Set `DEBUG_LOGGING = false` in production
- [ ] **Update version numbers** in Xcode:
  - Version (CFBundleShortVersionString): `1.0.0`
  - Build (CFBundleVersion): Increment for each upload (e.g., `1`, `2`, `3`)
- [ ] **Update bundle identifier** if needed
- [ ] **Ensure App Transport Security** allows HTTPS connections
- [ ] **Remove any test/debug UI elements**

### 2. App Store Connect Setup

1. **Create App Record**:
   - Go to [App Store Connect](https://appstoreconnect.apple.com)
   - Click "My Apps" → "+" → "New App"
   - Platform: iOS (and macOS if submitting both)
   - Bundle ID: Your registered bundle identifier
   - SKU: Unique identifier (e.g., `zipherx-ios-2025`)

2. **App Information**:
   - Primary Language: English
   - Category: Finance
   - Content Rights: "This app does not contain third-party content"

### 3. Required Metadata (Critical for Approval)

#### App Description
```
ZipherX is a secure, privacy-focused cryptocurrency wallet for Zclassic (ZCL).

Features:
• Full shielded (z-address) transaction support
• Secure key storage using device Secure Enclave
• No account required - you control your keys
• BIP-39 seed phrase backup
• Face ID / Touch ID authentication
• Real-time balance and transaction history

Security:
• Keys never leave your device
• AES-256 encrypted database
• Multi-peer network consensus
• Open source and auditable
```

#### Keywords
```
cryptocurrency, wallet, zclassic, zcl, privacy, blockchain, crypto, secure, shielded
```

#### Support URL
Required! Create a simple landing page or use your GitHub repo URL.

#### Privacy Policy URL
**CRITICAL** - Apple requires this for all apps. Include:
- What data is collected (none for a self-custody wallet)
- How data is used
- Data retention policies
- Contact information

Example privacy policy points:
```
ZipherX Privacy Policy

Data Collection: ZipherX does not collect, store, or transmit any personal
information to external servers. All wallet data is stored locally on your
device and encrypted.

Network Communication: The app connects to the Zclassic peer-to-peer network
to sync blockchain data. Only standard blockchain protocol messages are
transmitted. Your IP address may be visible to network peers.

Cryptographic Keys: Your spending keys are stored in the device's Secure
Enclave (or encrypted keychain) and never leave your device.

Analytics: ZipherX does not include any analytics or tracking SDKs.
```

### 4. Screenshots Requirements

#### iOS Screenshots Needed:
- **6.7" (iPhone 15 Pro Max)**: 1290 x 2796 px
- **6.5" (iPhone 15 Plus)**: 1284 x 2778 px
- **5.5" (iPhone 8 Plus)**: 1242 x 2208 px (optional but recommended)

#### macOS Screenshots:
- At least 1280 x 800 px, max 9000 x 9000 px

**Screenshot Tips**:
1. Use iOS Simulator set to desired device
2. Cmd+S to save screenshot
3. Show key screens: Balance, Send, Receive, Transaction History
4. Ensure no sensitive data (use test wallet)
5. Clean status bar (full battery, good signal, no distracting notifications)

### 5. App Review Guidelines - Key Points

#### 5.1 Finance/Cryptocurrency Apps
Apple has specific requirements:
- Must clearly explain what the app does
- Must have working functionality (not just a placeholder)
- Must handle errors gracefully
- Must have customer support contact

#### 5.2 Common Rejection Reasons & Solutions

| Reason | Solution |
|--------|----------|
| **Guideline 2.1 - Crashes** | Test thoroughly on real devices |
| **Guideline 2.3 - Metadata** | Ensure description matches functionality |
| **Guideline 4.2 - Minimum Functionality** | App must be fully functional |
| **Guideline 5.1.1 - Privacy** | Include privacy policy URL |
| **Guideline 5.1.2 - Data Use** | Explain any network connections |

#### 5.3 Cryptocurrency-Specific Guidance
- Avoid mentioning "trading" or "exchange" if you don't offer it
- Don't promise investment returns
- Make clear it's a self-custody wallet
- Explain that users are responsible for their keys

### 6. Build & Upload Process

#### Xcode Archive Steps:
```bash
# 1. Select "Any iOS Device" as build target
# 2. Product → Archive
# 3. Window → Organizer → Select Archive
# 4. Click "Distribute App"
# 5. Select "App Store Connect"
# 6. Choose "Upload"
# 7. Wait for upload and processing
```

#### Code Signing:
- Ensure you have valid Distribution certificate
- Use App Store provisioning profile
- For macOS: May need notarization for direct distribution

### 7. TestFlight Configuration

#### Internal Testing (Team Members):
- Automatic - anyone in your App Store Connect team can test
- No review required
- Max 100 testers

#### External Testing (Public Beta):
- Requires Beta App Review (usually 24-48 hours)
- Max 10,000 testers per app
- Create public link or invite by email

**Beta Test Information** (shown to testers):
```
What to Test:
• Create new wallet and verify seed phrase backup
• Send and receive shielded transactions
• Check that balance updates correctly
• Test Face ID/Touch ID authentication
• Verify transaction history accuracy

Known Issues:
• Initial sync may take 1-2 minutes on first launch
• [List any known issues]

Feedback:
Please report any issues via [your feedback channel]
```

### 8. Beta App Review Tips

#### What Reviewers Check:
1. App launches without crashing
2. Core functionality works
3. Description matches what app does
4. No placeholder content
5. Privacy policy is accessible

#### Demo Account/Instructions:
For crypto wallets, provide:
```
Test Instructions for App Review:

1. Launch the app
2. Tap "Create New Wallet"
3. Save the seed phrase (test only)
4. The app will sync with the blockchain (~1-2 minutes)
5. You can view the balance screen and transaction history
6. To test receiving, you can use the QR code on the Receive screen

Note: This is a self-custody wallet - no account or login required.
The app connects to the Zclassic peer-to-peer network.
```

### 9. Common Issues & Solutions

#### Issue: App Rejected for "Guideline 4.2 - Minimum Functionality"
**Solution**: Ensure the app demonstrates real functionality. Include:
- Working balance display
- Real blockchain connection
- Ability to generate addresses

#### Issue: "We were unable to review your app"
**Solution**: Provide clear demo instructions in App Review notes.

#### Issue: Binary Rejected for Missing NSFaceIDUsageDescription
**Solution**: Add to Info.plist:
```xml
<key>NSFaceIDUsageDescription</key>
<string>ZipherX uses Face ID to secure your wallet and authorize transactions.</string>
```

#### Issue: Network Connection Warnings
**Solution**: Add NSAppTransportSecurity if needed (though HTTPS should work by default)

### 10. Post-Submission Monitoring

1. **Check Processing Status**: Usually 15-30 minutes after upload
2. **Monitor Email**: Apple sends updates about review status
3. **Resolution Center**: Check for any issues or questions from Apple
4. **Respond Quickly**: Faster responses = faster approval

### 11. Version Update Workflow

For subsequent updates:
1. Increment build number
2. Archive and upload
3. Add "What's New" text
4. Submit for review
5. TestFlight updates automatically after approval

---

## Quick Reference

### Required Info.plist Keys
```xml
<key>NSFaceIDUsageDescription</key>
<string>Face ID is used to secure your wallet.</string>

<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

### App Store Connect URLs
- Dashboard: https://appstoreconnect.apple.com
- TestFlight: https://appstoreconnect.apple.com/apps/[APP_ID]/testflight

### Useful Commands
```bash
# Check code signing
codesign -dvvv /path/to/YourApp.app

# Validate archive before upload
xcrun altool --validate-app -f YourApp.ipa -t ios -u your@email.com

# Check for common issues
xcodebuild -exportArchive -archivePath YourApp.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath ./Export
```

---

**Remember**: Beta review is typically faster than full App Store review. Most rejections are for simple metadata issues that can be quickly resolved.

Good luck with your release! 🚀
