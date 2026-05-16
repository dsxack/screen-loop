#!/usr/bin/env swift

// Captures the README demo from a live macOS session. The CGEvent coordinates
// are intentionally tied to the demo machine; use DEMO_CAPTURE=0 to re-render
// from already captured raw frames.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Rect {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func intersection(_ other: Rect) -> Rect? {
        let value = cg.intersection(other.cg)
        guard !value.isNull, value.width > 0, value.height > 0 else { return nil }
        return Rect(x: value.minX, y: value.minY, width: value.width, height: value.height)
    }
}

struct DemoFrame {
    let name: String
    let source: String
    let crop: Rect
    let sharpRects: [Rect]
    let delay: Double
}

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first ?? "docs/screen-loop-demo.gif"
let frameDirectoryPath = arguments.dropFirst().first
let environment = ProcessInfo.processInfo.environment

func environmentValue(_ name: String, default defaultValue: String) -> String {
    guard let value = environment[name], !value.isEmpty else { return defaultValue }
    return value
}

let rawDirectoryPath = environmentValue("DEMO_RAW_DIR", default: ".build/readme-demo/raw")
let trimFramePath = environmentValue("DEMO_TRIM_FRAME", default: "\(rawDirectoryPath)/08-trim-window.png")
let shouldCapture = environment["DEMO_CAPTURE"] != "0"

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

if let frameDirectoryPath {
    try FileManager.default.createDirectory(
        atPath: frameDirectoryPath,
        withIntermediateDirectories: true
    )
}

let canvas = NSSize(width: 960, height: 730)
let menuCrop = Rect(x: 2024, y: 0, width: 1000, height: 760)
let normalMenu = Rect(x: 2130, y: 64, width: 570, height: 705)
let submenuMenu = Rect(x: 2130, y: 64, width: 855, height: 705)
let statusItem = Rect(x: 2122, y: 0, width: 128, height: 58)
let trimCrop = Rect(x: 570, y: 105, width: 2090, height: 1590)
let trimWindow = Rect(x: 690, y: 145, width: 1635, height: 1535)
let trimPreview = Rect(x: 720, y: 238, width: 1586, height: 1035)

func wait(_ seconds: Double) {
    usleep(useconds_t(seconds * 1_000_000))
}

func captureScreenshot(_ path: String) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "screencapture failed for \(path)"]
        )
    }
}

func captureDemoFrames(rawDirectoryPath: String, trimFramePath: String) throws {
    try FileManager.default.createDirectory(
        atPath: rawDirectoryPath,
        withIntermediateDirectories: true
    )

    guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Could not create CGEventSource"]
        )
    }

    let recStatusItem = CGPoint(x: 1100, y: 16)
    let normalRecordingRow = CGPoint(x: 1210, y: 92)
    let normalSaveFiveMinutesRow = CGPoint(x: 1130, y: 225)
    let altProfileRow = CGPoint(x: 1210, y: 205)
    let altTrimFiveMinutesRow = CGPoint(x: 1130, y: 340)
    let altTrimOneMinuteRow = CGPoint(x: 1130, y: 292)
    let trimVideoControlsPoint = CGPoint(x: 760, y: 615)
    let commandKeyCode: CGKeyCode = 55
    let optionKeyCode: CGKeyCode = 58
    let hKeyCode: CGKeyCode = 4
    let wKeyCode: CGKeyCode = 13
    let escapeKeyCode: CGKeyCode = 53

    func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    func move(_ point: CGPoint) {
        postMouse(.mouseMoved, at: point)
    }

    func click(_ point: CGPoint) {
        postMouse(.leftMouseDown, at: point)
        wait(0.04)
        postMouse(.leftMouseUp, at: point)
    }

    func key(_ keyCode: CGKeyCode, down: Bool) {
        CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: down
        )?.post(tap: .cghidEventTap)
    }

    func pressEscape() {
        key(escapeKeyCode, down: true)
        wait(0.03)
        key(escapeKeyCode, down: false)
    }

    func hideCurrentApp() {
        key(commandKeyCode, down: true)
        wait(0.03)
        key(hKeyCode, down: true)
        wait(0.03)
        key(hKeyCode, down: false)
        wait(0.03)
        key(commandKeyCode, down: false)
        wait(0.45)
    }

    func closeActiveWindow() {
        key(commandKeyCode, down: true)
        wait(0.03)
        key(wKeyCode, down: true)
        wait(0.03)
        key(wKeyCode, down: false)
        wait(0.03)
        key(commandKeyCode, down: false)
        wait(0.25)
    }

    func option(_ down: Bool) {
        key(optionKeyCode, down: down)
    }

    func closeMenu() {
        option(false)
        wait(0.05)
        pressEscape()
        wait(0.25)
    }

    func openMenu(optionDown: Bool) {
        closeMenu()
        if optionDown {
            option(true)
            wait(0.08)
        }
        click(recStatusItem)
        wait(0.55)
    }

    defer { option(false) }

    hideCurrentApp()

    openMenu(optionDown: false)
    try captureScreenshot("\(rawDirectoryPath)/01-normal.png")
    closeMenu()

    openMenu(optionDown: false)
    move(normalRecordingRow)
    wait(0.55)
    try captureScreenshot("\(rawDirectoryPath)/02-recording-submenu.png")
    closeMenu()

    openMenu(optionDown: false)
    move(normalSaveFiveMinutesRow)
    wait(0.35)
    try captureScreenshot("\(rawDirectoryPath)/03-save-hover.png")
    closeMenu()

    openMenu(optionDown: false)
    option(true)
    wait(0.45)
    try captureScreenshot("\(rawDirectoryPath)/04-option.png")
    closeMenu()

    openMenu(optionDown: true)
    move(altTrimFiveMinutesRow)
    wait(0.35)
    try captureScreenshot("\(rawDirectoryPath)/05-trim-hover.png")
    closeMenu()

    openMenu(optionDown: true)
    try captureScreenshot("\(rawDirectoryPath)/06-option-click-open.png")
    closeMenu()

    openMenu(optionDown: true)
    move(altProfileRow)
    wait(0.55)
    try captureScreenshot("\(rawDirectoryPath)/07-profile-submenu.png")
    closeMenu()

    openMenu(optionDown: true)
    click(altTrimOneMinuteRow)
    option(false)
    wait(10.0)
    move(trimVideoControlsPoint)
    wait(0.35)
    move(CGPoint(x: trimVideoControlsPoint.x + 8, y: trimVideoControlsPoint.y))
    wait(0.7)
    try captureScreenshot(trimFramePath)
    closeActiveWindow()
}

if shouldCapture {
    try captureDemoFrames(rawDirectoryPath: rawDirectoryPath, trimFramePath: trimFramePath)
}

let frames = [
    DemoFrame(
        name: "01-normal",
        source: "\(rawDirectoryPath)/01-normal.png",
        crop: menuCrop,
        sharpRects: [statusItem, normalMenu],
        delay: 1.15
    ),
    DemoFrame(
        name: "02-recording-submenu",
        source: "\(rawDirectoryPath)/02-recording-submenu.png",
        crop: menuCrop,
        sharpRects: [statusItem, submenuMenu],
        delay: 1.35
    ),
    DemoFrame(
        name: "03-profile-submenu",
        source: "\(rawDirectoryPath)/07-profile-submenu.png",
        crop: menuCrop,
        sharpRects: [statusItem, submenuMenu],
        delay: 1.35
    ),
    DemoFrame(
        name: "04-save-hover",
        source: "\(rawDirectoryPath)/03-save-hover.png",
        crop: menuCrop,
        sharpRects: [statusItem, normalMenu],
        delay: 1.0
    ),
    DemoFrame(
        name: "05-option-click-open",
        source: "\(rawDirectoryPath)/06-option-click-open.png",
        crop: menuCrop,
        sharpRects: [statusItem, normalMenu],
        delay: 1.15
    ),
    DemoFrame(
        name: "06-option-details",
        source: "\(rawDirectoryPath)/04-option.png",
        crop: menuCrop,
        sharpRects: [statusItem, normalMenu],
        delay: 1.15
    ),
    DemoFrame(
        name: "07-trim-action",
        source: "\(rawDirectoryPath)/05-trim-hover.png",
        crop: menuCrop,
        sharpRects: [statusItem, normalMenu],
        delay: 1.0
    ),
    DemoFrame(
        name: "08-trim-window",
        source: trimFramePath,
        crop: trimCrop,
        sharpRects: [trimWindow],
        delay: 1.8
    )
]

func loadImage(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not load image at \(path)"]
        )
    }
    return image
}

func crop(_ image: CGImage, to rect: Rect) throws -> CGImage {
    let integral = rect.cg.integral
    guard let cropped = image.cropping(to: integral) else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not crop \(integral)"]
        )
    }
    return cropped
}

func drawImage(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
    NSGraphicsContext.current?.cgContext.saveGState()
    NSGraphicsContext.current?.cgContext.setAlpha(alpha)
    NSImage(cgImage: image, size: rect.size).draw(in: rect)
    NSGraphicsContext.current?.cgContext.restoreGState()
}

func destinationRect(for sourceRect: Rect, crop cropRect: Rect) -> CGRect {
    let scaleX = canvas.width / cropRect.width
    let scaleY = canvas.height / cropRect.height
    let x = (sourceRect.x - cropRect.x) * scaleX
    let yFromTop = (sourceRect.y - cropRect.y) * scaleY
    let width = sourceRect.width * scaleX
    let height = sourceRect.height * scaleY
    return CGRect(x: x, y: canvas.height - yFromTop - height, width: width, height: height)
}

func roundedClipPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func render(_ frame: DemoFrame) throws -> CGImage {
    let source = try loadImage(frame.source)
    let croppedSource = try crop(source, to: frame.crop)

    let image = NSImage(size: canvas)
    image.lockFocus()
    NSColor.black.setFill()
    CGRect(origin: .zero, size: canvas).fill()

    drawImage(croppedSource, in: CGRect(origin: .zero, size: canvas))
    NSColor(calibratedWhite: 0, alpha: 0.24).setFill()
    CGRect(origin: .zero, size: canvas).fill()

    for sharpRect in frame.sharpRects {
        guard let clipped = sharpRect.intersection(frame.crop) else { continue }
        let part = try crop(source, to: clipped)
        let destination = destinationRect(for: clipped, crop: frame.crop)
        NSGraphicsContext.current?.cgContext.saveGState()
        roundedClipPath(destination.insetBy(dx: -2, dy: -2), radius: 14).addClip()
        drawImage(part, in: destination)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    image.unlockFocus()

    var proposed = CGRect(origin: .zero, size: canvas)
    guard let result = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not render \(frame.name)"]
        )
    }
    return result
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func writeGIF(_ rendered: [(CGImage, Double)]) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            rendered.count,
            nil
        )
    else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not create GIF destination"]
        )
    }

    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFLoopCount as String: 0
        ]
    ] as CFDictionary)

    for (image, delay) in rendered {
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay
            ]
        ] as CFDictionary)
    }

    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "ScreenLoopDemo",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Could not finalize GIF"]
        )
    }
}

let rendered = try frames.map { frame -> (CGImage, Double) in
    let image = try render(frame)
    if let frameDirectoryPath {
        try writePNG(image, to: "\(frameDirectoryPath)/\(frame.name).png")
    }
    return (image, frame.delay)
}

try writeGIF(rendered)
print(outputURL.path)
