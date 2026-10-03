import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import tidy

@objcMembers
final class ImageLoaderTests: XCTestCase {
    private var tempDir: URL!
    private var loader: ImageLoader!

    override func setUpWithError() throws {
        tempDir = try TestImageFactory.makeTempDirectory()
        loader = ImageLoader()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ type: UTType, _ name: String, width: Int, height: Int, orientation: Int? = nil) throws -> URL {
        try TestImageFactory.write(TestImageFactory.makeImage(width: width, height: height),
                                   to: tempDir.appendingPathComponent(name), type: type, orientation: orientation)
    }

    // MARK: 缩略图

    func testThumbnailScalesToMaxPixel() throws {
        let url = try write(.jpeg, "big.jpg", width: 2000, height: 1000)
        runAsync {
            let thumb = await self.loader.thumbnail(for: url, maxPixel: 500)
            XCTAssertNotNil(thumb)
            XCTAssertLessThanOrEqual(max(thumb!.width, thumb!.height), 500)
            XCTAssertEqual(thumb!.width, 500) // 长边为宽
        }
    }

    /// 竖拍 EXIF 转正：存储 100×200 + orientation 6 → 显示 200×100
    func testThumbnailAppliesEXIFOrientation() throws {
        let url = try write(.jpeg, "portrait.jpg", width: 100, height: 200, orientation: 6)
        runAsync {
            let thumb = await self.loader.thumbnail(for: url, maxPixel: 100)
            XCTAssertNotNil(thumb)
            XCTAssertEqual(thumb!.width, 100)
            XCTAssertEqual(thumb!.height, 50)
        }
    }

    // MARK: 全图

    func testFullImageAppliesEXIFOrientation() throws {
        let url = try write(.jpeg, "portrait-full.jpg", width: 100, height: 200, orientation: 6)
        runAsync {
            let full = try? await self.loader.fullImage(for: url)
            XCTAssertNotNil(full)
            XCTAssertEqual(full!.width, 200)
            XCTAssertEqual(full!.height, 100)
        }
    }

    func testFullImageOrientation180() throws {
        let url = try write(.jpeg, "rot180.jpg", width: 120, height: 60, orientation: 3)
        runAsync {
            let full = try? await self.loader.fullImage(for: url)
            XCTAssertEqual(full?.width, 120)
            XCTAssertEqual(full?.height, 60)
        }
    }

    // MARK: 缓存命中

    func testCacheHit() throws {
        let url = try write(.png, "cached.png", width: 64, height: 64)
        runAsync {
            let first = try? await self.loader.fullImage(for: url)
            let second = try? await self.loader.fullImage(for: url)
            XCTAssertNotNil(first)
            XCTAssertTrue(first === second, "第二次应命中缓存返回同一对象")
            let hits = await self.loader.cacheHits
            XCTAssertEqual(hits, 1)
        }
    }

    // MARK: >50MP 降采样（用小上限模拟）

    func testDownsamplingOverPixelLimit() throws {
        let smallLoader = ImageLoader(maxPixels: 10_000)
        let url = try write(.png, "huge.png", width: 200, height: 200) // 40_000 px > 10_000
        runAsync {
            let image = try? await smallLoader.fullImage(for: url)
            XCTAssertNotNil(image)
            // 长边换算公式：longEdge = sqrt(10000 × 1) = 100
            XCTAssertEqual(max(image!.width, image!.height), 100)
        }
    }

    func testNoDownsamplingUnderLimit() throws {
        let url = try write(.png, "normal.png", width: 200, height: 200)
        runAsync {
            let image = try? await self.loader.fullImage(for: url)
            XCTAssertEqual(image?.width, 200)
        }
    }

    // MARK: 损坏文件

    func testCorruptFileFails() throws {
        let url = tempDir.appendingPathComponent("corrupt.jpg")
        try Data([0xFF, 0xD8, 0x00, 0x11, 0x22]).write(to: url)
        runAsync {
            let thumb = await self.loader.thumbnail(for: url, maxPixel: 500)
            XCTAssertNil(thumb)
            do {
                _ = try await self.loader.fullImage(for: url)
                XCTFail("损坏文件应抛错")
            } catch {}
        }
    }

    // MARK: 格式解码

    func testDecodeGIF() throws {
        let url = tempDir.appendingPathComponent("anim.gif")
        try TestImageFactory.writeGIF(frames: 2, size: CGSize(width: 16, height: 16), to: url)
        runAsync {
            let image = try? await self.loader.fullImage(for: url)
            XCTAssertNotNil(image) // 首帧可解码（动图播放走 NSImageView，不经缓存）
        }
    }

    func testDecodeHEIC() throws {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
        guard supported else { throw XCTSkip("本机不支持 HEIC 编码，跳过") }
        let url = try write(.heic, "photo.heic", width: 32, height: 32)
        runAsync {
            let image = try? await self.loader.fullImage(for: url)
            XCTAssertEqual(image?.width, 32)
        }
    }

    func testDecodeTIFFAndBMP() throws {
        let tiff = try write(.tiff, "a.tiff", width: 16, height: 16)
        let bmp = try write(.bmp, "b.bmp", width: 16, height: 16)
        runAsync {
            let tiffImage = try? await self.loader.fullImage(for: tiff)
            let bmpImage = try? await self.loader.fullImage(for: bmp)
            XCTAssertNotNil(tiffImage)
            XCTAssertNotNil(bmpImage)
        }
    }
}
