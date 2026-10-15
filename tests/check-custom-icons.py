#!/usr/bin/env python3
"""Exercise icon import, persistence, appearance changes, reset, and native settings offline."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()
let work = URL(fileURLWithPath: CommandLine.arguments[1])
let originalLight = URL(fileURLWithPath: CommandLine.arguments[2])
let originalDark = URL(fileURLWithPath: CommandLine.arguments[3])
let storage = work.appendingPathComponent("saved/CustomIcons.plist")
var iconStyle: String?
let icons = MusicAppIcons(storageURL: storage, iconStyle: { iconStyle })
let aqua = NSAppearance(named: .aqua)!
let darkAqua = NSAppearance(named: .darkAqua)!
let finderIcon = Bundle.main.bundleURL.appendingPathComponent("Icon\r")
func finderArtwork() throws -> Data {
    try Data(contentsOf: finderIcon.appendingPathComponent("..namedfork/rsrc"))
}
if CommandLine.arguments.last == "save-before-update" {
    app.appearance = aqua
    icons.start()
    try icons.importIcon(from: originalLight, for: .light)
    try icons.importIcon(from: originalDark, for: .dark)
    try app.applicationIconImage.tiffRepresentation!.write(to: work.appendingPathComponent("selected-light.tiff"))
    try finderArtwork().write(to: work.appendingPathComponent("selected-finder-icon"))
} else if CommandLine.arguments.last == "check-after-update" {
    assert(icons.image(for: .light) != nil && icons.image(for: .dark) != nil)
    app.appearance = aqua
    icons.start()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    let selectedBeforeUpdate = try Data(contentsOf: work.appendingPathComponent("selected-light.tiff"))
    assert(app.applicationIconImage.tiffRepresentation == selectedBeforeUpdate,
           "An updated app reapplies the saved custom icon instead of its new bundled icon")
    let finderBeforeUpdate = try Data(contentsOf: work.appendingPathComponent("selected-finder-icon"))
    let finderAfterUpdate = try finderArtwork()
    assert(finderAfterUpdate == finderBeforeUpdate, "The replacement app must restore its Finder icon too")
    print("PASS: custom choices survive app replacement and are reapplied on launch")
} else {
iconStyle = "RegularAutomatic"
app.appearance = aqua
icons.start()
assert(!icons.hasCustomIcons && icons.loadError == nil)
let initialIcon = app.applicationIconImage.tiffRepresentation!
let light = work.appendingPathComponent("chosen.ICNS")
try FileManager.default.copyItem(at: originalLight, to: light)
try icons.importIcon(from: light, for: .light)
let activeLight = app.applicationIconImage.tiffRepresentation!
let finderLight = try finderArtwork()
assert(!finderLight.isEmpty && icons.finderError == nil, "The actual app bundle gets a persistent Finder icon")
assert(icons.hasCustomIcons && icons.image(for: .light) != nil && icons.image(for: .dark) == nil)
try FileManager.default.removeItem(at: light)
assert(MusicAppIcons(storageURL: storage).image(for: .light) != nil, "The source download is no longer needed")

icons.apply(appearance: darkAqua)
assert(app.applicationIconImage.tiffRepresentation == initialIcon, "An empty slot restores the native icon")
assert(!FileManager.default.fileExists(atPath: finderIcon.path), "An empty slot clears the old Finder override")
try icons.importIcon(from: originalDark, for: .dark)
icons.apply(appearance: darkAqua)
let activeDark = app.applicationIconImage.tiffRepresentation!
assert(activeDark != activeLight, "Light and Dark must render different artwork")
let finderDark = try finderArtwork()
assert(finderDark != finderLight, "Finder follows the selected Light or Dark artwork")
let restored = MusicAppIcons(storageURL: storage)
assert(restored.image(for: .light) != nil && restored.image(for: .dark) != nil)

let beforeFailure = try Data(contentsOf: storage)
for (name, bytes) in [("broken.icns", Data("icns0000bad".utf8)),
                      ("renamed.icns", try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))),
                      ("wrong.png", try Data(contentsOf: originalLight))] {
    let url = work.appendingPathComponent(name)
    try bytes.write(to: url)
    do { try icons.importIcon(from: url, for: .light); fatalError("Accepted invalid file: \(name)") }
    catch { }
    let afterFailure = try Data(contentsOf: storage)
    assert(afterFailure == beforeFailure, "Failed imports must preserve both choices")
}
let blocked = work.appendingPathComponent("not-a-folder")
try Data().write(to: blocked)
let unwritable = MusicAppIcons(storageURL: blocked.appendingPathComponent("CustomIcons.plist"))
do { try unwritable.importIcon(from: originalLight, for: .light); fatalError("Accepted a failed save") }
catch { }
assert(unwritable.image(for: .light) == nil)


app.appearance = darkAqua
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
assert(app.applicationIconImage.tiffRepresentation == activeDark, "Observe macOS appearance changes")
app.appearance = aqua
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
assert(app.applicationIconImage.tiffRepresentation == activeLight)

if #available(macOS 26.0, *) {
    app.appearance = darkAqua
    iconStyle = nil
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.3))
    assert(app.applicationIconImage.tiffRepresentation == activeLight,
           "Default icon style uses Light even when the system appearance is Dark")
    app.appearance = aqua
    iconStyle = "RegularDark"
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.3))
    assert(app.applicationIconImage.tiffRepresentation == activeDark, "Icon style changes apply without restarting")
    for style in ["ClearLight", "ClearDark", "ClearAutomatic", "TintedLight", "TintedDark", "TintedAutomatic"] {
        iconStyle = style
        icons.apply(appearance: aqua)
        assert(app.applicationIconImage.isValid && app.applicationIconImage.tiffRepresentation != activeDark,
               "\(style) must use the native icon renderer instead of the raw Dark image")
    }
    iconStyle = "FutureUnknownStyle"
    icons.apply(appearance: aqua)
    assert(app.applicationIconImage.tiffRepresentation == activeLight, "Unknown styles fall back to system appearance")
}

var nativeIcon: MusicAppIcons.NativeIcon? = try MusicAppIcons.NativeIcon(data: Data(contentsOf: originalDark))
let renderURL = nativeIcon!.url
let cachedArtwork = try Data(contentsOf: renderURL.appendingPathComponent("Contents/Resources/Icon.icns"))
let originalArtwork = try Data(contentsOf: originalDark)
assert(cachedArtwork == originalArtwork, "System effects must render the uploaded artwork")
assert(FileManager.default.isExecutableFile(atPath: renderURL.appendingPathComponent("Contents/MacOS/Icon").path),
       "IconServices must recognize a valid app icon without an unsupported-app badge")
nativeIcon = nil
assert(!FileManager.default.fileExists(atPath: renderURL.path), "Disposable render bundles are cleaned up")

let settings = MusicSettings(icons: icons)
settings.show()
let window = settings.window!
window.contentView!.layoutSubtreeIfNeeded()
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let views = descendants(window.contentView!)
let choose = views.compactMap { $0 as? NSButton }.filter { $0.title == "Choose Icon…" }
assert(choose.count == 2 && Set(choose.compactMap { $0.identifier?.rawValue }) == ["light", "dark"])
let reset = views.compactMap { $0 as? NSButton }.first { $0.title == "Reset to Default" }!
assert(reset.isEnabled)
reset.performClick(nil)
assert(!icons.hasCustomIcons && !reset.isEnabled)
assert(!FileManager.default.fileExists(atPath: storage.path))
assert(!FileManager.default.fileExists(atPath: finderIcon.path), "Reset removes the persistent Finder icon")
assert(!MusicAppIcons(storageURL: storage).hasCustomIcons)
assert(app.applicationIconImage.tiffRepresentation == initialIcon, "Reset restores the bundled icon")
try icons.reset()

let deniedStorage = work.appendingPathComponent("denied/CustomIcons.plist")
let denied = MusicAppIcons(storageURL: deniedStorage, applicationURL: work.appendingPathComponent("Missing.app"))
do { try denied.importIcon(from: originalLight, for: .light); fatalError("An unsuccessful Finder update must report an error") }
catch { }
assert(denied.finderError != nil && denied.image(for: .light) != nil, "Keep uploads when the application is not writable")
let deniedSaved = try Data(contentsOf: deniedStorage)
do { try denied.reset(); fatalError("An unsuccessful Finder reset must report an error") }
catch { }
let afterDeniedReset = try Data(contentsOf: deniedStorage)
assert(afterDeniedReset == deniedSaved && denied.image(for: .light) != nil, "A failed reset must preserve saved icons")

try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("corrupt preferences".utf8).write(to: storage)
let corrupt = MusicAppIcons(storageURL: storage)
assert(corrupt.loadError != nil && corrupt.image(for: .light) == nil)
try corrupt.reset()
assert(corrupt.loadError == nil && !corrupt.hasCustomIcons)
print("PASS: ICNS validation, atomic saves, independent slots, reload, live icon style/appearance, settings, and full reset")
window.close()
}
'''

env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
with tempfile.TemporaryDirectory(prefix="music-custom-icon-check-") as directory:
    work = Path(directory)
    app = work / "IconCheck.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Resources").mkdir()
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.music-icon-check", "CFBundleExecutable": "IconCheck",
        "CFBundleName": "IconCheck", "CFBundlePackageType": "APPL", "CFBundleIconFile": "icon.icns",
    }))
    shutil.copyfile(root / "Music/icon.icns", app / "Resources/icon.icns")
    for name in ("Light", "Dark"):
        shutil.copyfile(root / f"Music/Assets.xcassets/{name}.imageset/{name.lower()}.png", app / f"Resources/{name}.png")
    script = work / "main.swift"
    script.write_text(checks)
    binary = app / "MacOS/IconCheck"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(root / "Music/MusicAppIcons.swift"),
                    str(root / "Music/MusicSettings.swift"), str(root / "Music/MusicExtensions.swift"),
                    str(script), "-o", str(binary)], check=True, env=env)
    subprocess.run(["codesign", "--sign", "-", str(app.parent)], check=True, capture_output=True)
    command = [str(binary), str(work), str(root / "Music/icon.icns"), str(root / "Music/icon-dark.icns"),
               str(root / "Music/Assets.xcassets/Light.imageset/light.png")]
    subprocess.run(command, check=True, timeout=30)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app.parent)], check=True, capture_output=True)
    print("PASS: customizing and resetting preserves the app signature")
    subprocess.run(command + ["save-before-update"], check=True, timeout=30)
    assert (app.parent / "Icon\r").exists(), "The Finder icon must remain after the process exits"
    subprocess.run(["codesign", "--verify", "--deep", str(app.parent)], check=True, capture_output=True)
    print("PASS: Finder icon persists after quitting; normal code-signature verification passes")
    saved = (work / "saved/CustomIcons.plist").read_bytes()
    replacement = work / "Updated.app"
    shutil.copytree(app.parent, replacement)
    subprocess.run(["/bin/sh", str(root / "scripts/clear-build-icon.sh"), str(replacement)], check=True)
    assert not (replacement / "Icon\r").exists(), "A rebuilt app must not contain runtime icon metadata"
    info = replacement / "Contents/Info.plist"
    info.write_bytes(plistlib.dumps({**plistlib.loads(info.read_bytes()), "CFBundleVersion": "2"}))
    shutil.copyfile(root / "Music/icon-dark.icns", replacement / "Contents/Resources/icon.icns")
    subprocess.run(["codesign", "--force", "--sign", "-", str(replacement)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(replacement)], check=True, capture_output=True)
    shutil.rmtree(app.parent)
    replacement.rename(app.parent)
    subprocess.run(command + ["check-after-update"], check=True, timeout=30)
    assert (work / "saved/CustomIcons.plist").read_bytes() == saved, "An update must not overwrite saved choices"
