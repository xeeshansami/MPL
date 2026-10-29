import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MplNativeBridge") {
      MplNativeBridge.register(with: registrar)
    }
  }
}

/// Native media helpers for the Dart layer. iOS audio lives in the app's
/// private storage (imported through Files), so discovery and metadata are
/// handled in Dart; this bridge only decodes PCM windows for the AI model.
final class MplNativeBridge: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "mpl.decoder", qos: .utility)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mpl/native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MplNativeBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "decodePcm":
      guard let args = call.arguments as? [String: Any], let uri = args["uri"] as? String else {
        result(FlutterError(code: "bad_args", message: "uri required", details: nil))
        return
      }
      let offsetMs = (args["offsetMs"] as? NSNumber)?.int64Value ?? 0
      let durationMs = (args["durationMs"] as? NSNumber)?.int64Value ?? 0
      queue.async {
        do {
          let value = try Self.decode(uri: uri, offsetMs: offsetMs, durationMs: durationMs)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "decode_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Decodes [offsetMs, offsetMs + durationMs) to interleaved 16-bit LE PCM at
  /// the source sample rate and channel count; Dart performs the down-mix and
  /// resampling shared with Android.
  private static func decode(uri: String, offsetMs: Int64, durationMs: Int64) throws -> [String: Any] {
    let url = uri.hasPrefix("file://") ? URL(string: uri)! : URL(fileURLWithPath: uri)
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw NSError(domain: "mpl", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track in source"])
    }
    var sampleRate = 44100.0
    var channels = 2
    if let desc = track.formatDescriptions.first,
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMAudioFormatDescription)?.pointee {
      sampleRate = asbd.mSampleRate
      channels = Int(asbd.mChannelsPerFrame)
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(value: offsetMs, timescale: 1000),
      duration: CMTime(value: durationMs, timescale: 1000))
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "mpl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read audio"])
    }
    var data = Data()
    while let buffer = output.copyNextSampleBuffer() {
      if let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        var chunk = Data(count: length)
        chunk.withUnsafeMutableBytes { ptr in
          _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        data.append(chunk)
      }
    }
    if reader.status == .failed {
      throw reader.error ?? NSError(domain: "mpl", code: 3, userInfo: [NSLocalizedDescriptionKey: "Decoding failed"])
    }
    return [
      "sampleRate": Int(sampleRate),
      "channels": channels,
      "pcm": FlutterStandardTypedData(bytes: data),
      "startMs": offsetMs,
    ]
  }
}
