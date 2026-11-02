// Reproducible, original synthetic media for native Chromium acceptance.
// swiftc -parse-as-library generate-media-fixtures.swift -o /path/to/generator
// /path/to/generator /path/to/fixtures/media
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

enum FixtureError: Error { case failed(String) }

@main struct MediaFixtures {
  static let sampleRate = 48_000
  static func wait(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
    let deadline = Date().addingTimeInterval(15)
    while !input.isReadyForMoreMediaData {
      guard writer.status == .writing, Date() < deadline else {
        throw FixtureError.failed(writer.error?.localizedDescription ?? "Encoder timed out")
      }
      Thread.sleep(forTimeInterval: 0.002)
    }
  }
  static func audioSamples(start: Int, count: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
      blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
      offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block) == noErr, let block else {
      throw FixtureError.failed("PCM allocation failed")
    }
    let values = (start..<(start + count)).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(sampleRate)) * 0.08) }
    try values.withUnsafeBytes { bytes in
      guard CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: bytes.count) == noErr else { throw FixtureError.failed("PCM copy failed") }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
      presentationTimeStamp: CMTime(value: Int64(start), timescale: CMTimeScale(sampleRate)), decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
      throw FixtureError.failed("PCM sample creation failed")
    }
    return sample
  }
  static func encode(at url: URL, video: Bool) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: video ? .mp4 : .m4a)
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
    if !video { writer.add(audio) }
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
      mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
      let description else { throw FixtureError.failed("PCM format failed") }
    let imageInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 160, AVVideoHeightKey: 96,
      AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
        AVVideoAverageBitRateKey: 100_000, AVVideoExpectedSourceFrameRateKey: 30]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: imageInput,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96])
    if video { writer.add(imageInput) }
    guard writer.startWriting() else { throw writer.error ?? FixtureError.failed("Writer failed") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
      if video {
        try wait(imageInput, writer: writer)
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
          let pixel else { throw FixtureError.failed("Video buffer failed") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<96 { for x in 0..<160 {
          let position = y * stride + x * 4
          bytes[position] = UInt8((x + frame * 3) % 256)
          bytes[position + 1] = UInt8((y * 2 + frame) % 256)
          bytes[position + 2] = UInt8(frame * 4); bytes[position + 3] = 255
        }}
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
          throw writer.error ?? FixtureError.failed("Video append failed")
        }
      }
      if !video {
        try wait(audio, writer: writer)
        guard audio.append(try audioSamples(start: frame * 1600, count: 1600, format: description)) else {
          throw writer.error ?? FixtureError.failed("Audio append failed")
        }
      }
    }
    if video { imageInput.markAsFinished() } else { audio.markAsFinished() }
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? FixtureError.failed("Encoding failed") }
  }
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw FixtureError.failed("Output directory required") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, video) in [("synthetic-h264.mp4", true), ("synthetic-aac.m4a", false)] {
      let output = directory.appendingPathComponent(name)
      guard !FileManager.default.fileExists(atPath: output.path) else { throw FixtureError.failed("Refusing to overwrite existing fixture") }
      try await encode(at: output, video: video)
      print(name, try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    var bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
    guard let context = CGContext(directory.appendingPathComponent("synthetic.pdf") as CFURL, mediaBox: &bounds, nil) else {
      throw FixtureError.failed("PDF context failed")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0.3, green: 0.25, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 20, y: 20, width: 280, height: 24))
    let title = NSAttributedString(string: "Zacro native PDF acceptance", attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)])
    context.textPosition = CGPoint(x: 20, y: 130)
    CTLineDraw(CTLineCreateWithAttributedString(title), context)
    context.endPDFPage(); context.closePDF()
  }
}
