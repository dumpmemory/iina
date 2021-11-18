//
//  VideoView.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa


class VideoView: NSView {

  weak var player: PlayerCore!
  var link: CVDisplayLink?

  lazy var videoLayer: ViewLayer = {
    let layer = ViewLayer()
    layer.videoView = self
    return layer
  }()

  var videoSize: NSSize?

  var isUninited = false
  var uninitLock = NSLock()

  var draggingTimer: Timer?

  // whether auto show playlist is triggered
  var playlistShown: Bool = false

  // variable for tracing mouse position when dragging in the view
  var lastMousePosition: NSPoint?

  var hasPlayableFiles: Bool = false

  // cached indicator to prevent unnecessary updates of DisplayLink
  var currentDisplay: UInt32?

  var pendingRedrawAfterEnteringPIP = false;

  // MARK: - Attributes

  override var mouseDownCanMoveWindow: Bool {
    return true
  }

  override var isOpaque: Bool {
    return true
  }

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)

    // set up layer
    layer = videoLayer
    videoLayer.contentsScale = NSScreen.main!.backingScaleFactor
    wantsLayer = true

    // other settings
    autoresizingMask = [.width, .height]
    wantsBestResolutionOpenGLSurface = true

    // dragging init
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
  }

  convenience init(frame: CGRect, player: PlayerCore) {
    self.init(frame: frame)
    self.player = player
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func uninit() {
    uninitLock.lock()

    guard !isUninited else {
      uninitLock.unlock()
      return
    }

    player.mpv.mpvUninitRendering()
    isUninited = true
    uninitLock.unlock()
  }

  deinit {
    uninit()
  }

  override func layout() {
    super.layout()
    if pendingRedrawAfterEnteringPIP && superview != nil {
      videoLayer.draw(forced: true)
      pendingRedrawAfterEnteringPIP = false
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    // do nothing
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  // MARK: Drag and drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    hasPlayableFiles = (player.acceptFromPasteboard(sender, isPlaylist: true) == .copy)
    return player.acceptFromPasteboard(sender)
  }

  @objc func showPlaylist() {
    player.mainWindow.menuShowPlaylistPanel(.dummy)
    playlistShown = true
  }

  private func createTimer() {
    draggingTimer = Timer.scheduledTimer(timeInterval: TimeInterval(0.3), target: self,
                                         selector: #selector(showPlaylist), userInfo: nil, repeats: false)
  }

  private func destroyTimer() {
    if let draggingTimer = draggingTimer {
      draggingTimer.invalidate()
    }
    draggingTimer = nil
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {

    guard !player.isInMiniPlayer && !playlistShown && hasPlayableFiles else { return super.draggingUpdated(sender) }

    func inTriggerArea(_ point: NSPoint?) -> Bool {
      guard let point = point, let frame = player.mainWindow.window?.frame else { return false }
      return point.x > (frame.maxX - frame.width * 0.2)
    }

    let position = NSEvent.mouseLocation

    if position != lastMousePosition {
      if inTriggerArea(lastMousePosition) {
        destroyTimer()
      }
      if inTriggerArea(position) {
        createTimer()
      }
      lastMousePosition = position
    }

    return super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    destroyTimer()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    if playlistShown {
      player.mainWindow.hideSideBar()
    }
    playlistShown = false
    lastMousePosition = nil
  }

  // MARK: Display link

  func startDisplayLink() {
    if link == nil {
      CVDisplayLinkCreateWithActiveCGDisplays(&link)
    }
    guard let link = link else {
      Logger.fatal("Cannot Create display link!")
    }
    updateDisplayLink()
    CVDisplayLinkSetOutputCallback(link, displayLinkCallback, mutableRawPointerOf(obj: player.mpv))
    CVDisplayLinkStart(link)
  }

  func stopDisplayLink() {
    guard let link = link, CVDisplayLinkIsRunning(link) else { return }
    CVDisplayLinkStop(link)
  }

  func updateDisplayLink() {
    guard let window = window, let link = link, let screen = window.screen else { return }
    let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
    if (currentDisplay == displayId) {
      return
    }

    CVDisplayLinkSetCurrentCGDisplay(link, displayId)
    let actualData = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    var actualFps: Double = 0;

    if (nominalData.flags & Int32(CVTimeFlags.isIndefinite.rawValue)) < 1 {
      let nominalFps = Double(nominalData.timeScale) / Double(nominalData.timeValue)

      if actualData > 0 {
        actualFps = 1/actualData
      }

      if abs(actualFps - nominalFps) > 1 {
        Logger.log("Falling back to nominal display refresh rate: \(nominalFps) from \(actualFps)")
        actualFps = nominalFps;
      }
    } else {
      Logger.log("Falling back to standard display refresh rate: 60 from \(actualFps)")
      actualFps = 60;
    }
    player.mpv.setDouble(MPVOption.Video.overrideDisplayFps, actualFps)

    setICCProfile(displayId)
    currentDisplay = displayId
  }
  
  // HDR
  func requestEdrMode() -> Bool {
    if (player.hdrMetadata.transfer == nil || player.hdrMetadata.primaries == nil) {
      // SDR content
      return false;
    }
    if (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) <= 1.0 {
      Logger.log("HDR: HDR video was found but the display does not support EDR mode");
      return false;
    }
    Logger.log("HDR: Will activate HDR color space instead of using ICC profile");

    self.wantsExtendedDynamicRangeOpenGLSurface = true
    videoLayer.wantsExtendedDynamicRangeContent = true
    
    var name: CFString? = nil;
    switch player.hdrMetadata.primaries {
    case "displayp3":
      switch player.hdrMetadata.transfer {
      case "pq":
        if #available(macOS 10.15.4, *) {
          name = CGColorSpace.displayP3_PQ
        } else {
          name = CGColorSpace.displayP3_PQ_EOTF
        }
      case "hlg":
        name = CGColorSpace.displayP3_HLG
      default:
        name = CGColorSpace.displayP3
      }
      
    case "bt2020": // deprecated
      switch player.hdrMetadata.transfer {
      case "pq":
        if #available(macOS 11.0, *) {
          name = CGColorSpace.itur_2020_PQ
        } else {
          name = CGColorSpace.itur_2020_PQ_EOTF
        }
      case "hlg":
        if #available(macOS 10.15.6, *) {
          name = CGColorSpace.itur_2020_HLG
        } else {
          fallthrough
        }
      default:
        name = CGColorSpace.itur_2020
      }
      
    // SDR? Should not go here
    case "dcip3":
      name = CGColorSpace.dcip3
    case "bt709":
      name = CGColorSpace.itur_709;
      
    // These values are not detected in FFmpegController, but I still list them here
    case "srgb":
      name = CGColorSpace.sRGB
    default:
      Logger.log("HDR: Unknown HDR color space information transfer=\(player.hdrMetadata.transfer) primaries=\(player.hdrMetadata.primaries)");
      return false;
    }
    
    videoLayer.colorspace = CGColorSpace(name: name!)
    player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, player.hdrMetadata.transfer!)
    player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "bt.2020") // We only support AVCOL_PRI_BT2020, see FFmpegController
    player.mpv.setString(MPVOption.GPURendererOptions.targetPeak, player.hdrMetadata.max_luminance?.stringValue ?? "auto")
    return true;
  }

  func setICCProfile(_ displayId: UInt32) {
    if requestEdrMode() { return }
    
    typealias ProfileData = (uuid: CFUUID, profileUrl: URL?)
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayId)?.takeRetainedValue() else { return }

    var argResult: ProfileData = (uuid, nil)
    withUnsafeMutablePointer(to: &argResult) { data in
      ColorSyncIterateDeviceProfiles({ (dict: CFDictionary?, ptr: UnsafeMutableRawPointer?) -> Bool in
        if let info = dict as? [String: Any], let current = info["DeviceProfileIsCurrent"] as? Int {
          let deviceID = info["DeviceID"] as! CFUUID
          let ptr = ptr!.bindMemory(to: ProfileData.self, capacity: 1)
          let uuid = ptr.pointee.uuid

          if current == 1, deviceID == uuid {
            let profileURL = info["DeviceProfileURL"] as! URL
            ptr.pointee.profileUrl = profileURL
            return false
          }
        }
        return true
      }, data)
    }

    if let iccProfilePath = argResult.profileUrl?.path, FileManager.default.fileExists(atPath: iccProfilePath) {
      player.mpv.setString(MPVOption.GPURendererOptions.iccProfile, iccProfilePath)
    }
  }
}

fileprivate func displayLinkCallback(
  _ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>,
  _ inOutputTime: UnsafePointer<CVTimeStamp>,
  _ flagsIn: CVOptionFlags,
  _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
  _ context: UnsafeMutableRawPointer?) -> CVReturn {
  let mpv = unsafeBitCast(context, to: MPVController.self)
  mpv.mpvReportSwap()
  return kCVReturnSuccess
}
