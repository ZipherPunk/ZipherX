# Quick Instructions: Add New Files to Xcode

## Manual Method (Easiest)

1. Open Xcode
2. In the Project Navigator (left sidebar), find these folders:
   - `Sources/Core/Storage/`
   - `Sources/Core/Wallet/`
   - `Sources/Core/Services/`
3. Right-click each folder and select "Add Files to ZipherX..."
4. Add these files:
   - `TempImportDatabase.swift` → `Sources/Core/Storage/`
   - `ParallelImportCoordinator.swift` → `Sources/Core/Wallet/`
   - `ParallelImportProgressView.swift` → `Sources/Core/Services/`
5. Make sure "Copy items if needed" is **UNCHECKED** (files are already in place)
6. Make sure "Add to targets: ZipherX" and "ZipherXMac" are **CHECKED**
7. Click "Add"

## Command Line Method (Alternative)

Open Xcode project:
```bash
open ZipherX.xcodeproj
```

Then follow the manual method above.

## Verify Files Are Added

After adding, check that these files appear in Xcode:
- ✅ TempImportDatabase.swift
- ✅ ParallelImportCoordinator.swift
- ✅ ParallelImportProgressView.swift

## Then Build

```bash
xcodebuild -scheme ZipherX -sdk macosx build
```

---

**Error you saw**: `Cannot find 'ParallelImportCoordinator' in scope`

This will be fixed once the files are added to the Xcode project target.
