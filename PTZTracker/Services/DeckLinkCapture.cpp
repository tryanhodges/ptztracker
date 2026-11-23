#include "DeckLinkCapture.h"

#if __has_include(<DeckLinkAPI.h>)
#include <DeckLinkAPI.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <utility>

namespace {
class Capture final : public IDeckLinkInputCallback {
    std::atomic<ULONG> references{1};
    std::mutex frameMutex;
    CVPixelBufferRef latestFrame = nullptr;
    CVPixelBufferPoolRef bufferPool = nullptr;

public:
    IDeckLinkInput *input = nullptr;

    ~Capture() override {
        if (latestFrame) CVPixelBufferRelease(latestFrame);
        if (bufferPool) CVPixelBufferPoolRelease(bufferPool);
        if (input) input->Release();
    }

    ULONG AddRef() override { return ++references; }
    ULONG Release() override {
        const auto remaining = --references;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT QueryInterface(REFIID iid, void **result) override {
        if (!result) return E_INVALIDARG;
        *result = nullptr;
        const auto unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &IID_IDeckLinkInputCallback, sizeof(iid)) != 0 &&
            memcmp(&iid, &unknown, sizeof(iid)) != 0) return E_NOINTERFACE;
        *result = static_cast<IDeckLinkInputCallback *>(this);
        AddRef();
        return S_OK;
    }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents, IDeckLinkDisplayMode *,
                                    BMDDetectedVideoInputFormatFlags) override {
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *) override {
        if (!frame || (frame->GetFlags() & bmdFrameHasNoInputSource)) return S_OK;

        IDeckLinkVideoBuffer *source = nullptr;
        if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, reinterpret_cast<void **>(&source)) != S_OK)
            return S_OK;

        CVPixelBufferRef pixels = nullptr;
        if (source->StartAccess(bmdBufferAccessRead) == S_OK) {
            void *bytes = nullptr;
            if (source->GetBytes(&bytes) == S_OK && bytes) pixels = copyPixels(frame, bytes);
            source->EndAccess(bmdBufferAccessRead);
        }
        source->Release();

        if (pixels) {
            std::lock_guard<std::mutex> lock(frameMutex);
            if (latestFrame) CVPixelBufferRelease(latestFrame);
            latestFrame = pixels;
        }
        return S_OK;
    }

    CVPixelBufferRef takeFrame() {
        std::lock_guard<std::mutex> lock(frameMutex);
        return std::exchange(latestFrame, nullptr);
    }

private:
    CVPixelBufferRef copyPixels(IDeckLinkVideoInputFrame *frame, const void *bytes) {
        const auto width = static_cast<int>(frame->GetWidth());
        const auto height = static_cast<int>(frame->GetHeight());
        if (!bufferPool) {
            const OSType pixelFormat = kCVPixelFormatType_422YpCbCr8;
            auto widthValue = CFNumberCreate(nullptr, kCFNumberIntType, &width);
            auto heightValue = CFNumberCreate(nullptr, kCFNumberIntType, &height);
            auto formatValue = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pixelFormat);
            auto surface = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
            const void *keys[] = {kCVPixelBufferWidthKey, kCVPixelBufferHeightKey,
                                  kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferIOSurfacePropertiesKey};
            const void *values[] = {widthValue, heightValue, formatValue, surface};
            auto attributes = CFDictionaryCreate(nullptr, keys, values, 4,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CVPixelBufferPoolCreate(nullptr, nullptr, attributes, &bufferPool);
            CFRelease(attributes);
            CFRelease(surface);
            CFRelease(formatValue);
            CFRelease(heightValue);
            CFRelease(widthValue);
        }

        CVPixelBufferRef pixels = nullptr;
        if (!bufferPool || CVPixelBufferPoolCreatePixelBuffer(nullptr, bufferPool, &pixels) != kCVReturnSuccess)
            return nullptr;
        if (CVPixelBufferLockBaseAddress(pixels, 0) != kCVReturnSuccess) {
            CVPixelBufferRelease(pixels);
            return nullptr;
        }
        const size_t sourceStride = frame->GetRowBytes();
        const size_t destinationStride = CVPixelBufferGetBytesPerRow(pixels);
        auto *destination = static_cast<unsigned char *>(CVPixelBufferGetBaseAddress(pixels));
        auto *source = static_cast<const unsigned char *>(bytes);
        for (int row = 0; row < height; ++row) {
            memcpy(destination + row * destinationStride, source + row * sourceStride,
                   std::min(sourceStride, destinationStride));
        }
        CVPixelBufferUnlockBaseAddress(pixels, 0);
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        return pixels;
    }
};

IDeckLinkIterator *makeIterator() {
    using Factory = IDeckLinkIterator *(*)();
    static const auto factory = []() -> Factory {
        auto library = dlopen("/Library/Frameworks/DeckLinkAPI.framework/DeckLinkAPI", RTLD_LAZY | RTLD_LOCAL);
        return library ? reinterpret_cast<Factory>(dlsym(library, "CreateDeckLinkIteratorInstance_0004")) : nullptr;
    }();
    return factory ? factory() : nullptr;
}
}

void *PTZDeckLinkOpen(const char **errorMessage) {
    auto *iterator = makeIterator();
    if (!iterator) {
        *errorMessage = "Could not load Blackmagic Desktop Video.";
        return nullptr;
    }

    auto *capture = new Capture();
    IDeckLink *device = nullptr;
    while (iterator->Next(&device) == S_OK) {
        CFStringRef name = nullptr;
        if (device->GetDisplayName(&name) == S_OK && name) {
            if (CFStringFind(name, CFSTR("UltraStudio HD Mini"), 0).location != kCFNotFound)
                device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(&capture->input));
            CFRelease(name);
        }
        device->Release();
        if (capture->input) break;
    }
    iterator->Release();

    if (!capture->input) {
        *errorMessage = "DeckLink could not open the UltraStudio HD Mini.";
    } else if (capture->input->SetCallback(capture) != S_OK) {
        *errorMessage = "Could not set the DeckLink frame callback.";
    } else if (capture->input->EnableVideoInput(bmdModeHD1080i6000, bmdFormat8BitYUV, bmdVideoInputFlagDefault) != S_OK) {
        *errorMessage = "Could not enable 1080i60 on the UltraStudio. Check that other capture apps are closed.";
        capture->input->SetCallback(nullptr);
    } else if (capture->input->StartStreams() != S_OK) {
        *errorMessage = "Could not start the UltraStudio video stream.";
        capture->input->DisableVideoInput();
        capture->input->SetCallback(nullptr);
    } else {
        return capture;
    }

    capture->Release();
    return nullptr;
}

CVPixelBufferRef PTZDeckLinkCopyFrame(void *capture) {
    return static_cast<Capture *>(capture)->takeFrame();
}

void PTZDeckLinkClose(void *handle) {
    auto *capture = static_cast<Capture *>(handle);
    capture->input->StopStreams();
    capture->input->DisableVideoInput();
    capture->input->SetCallback(nullptr);
    capture->Release();
}
#else
void *PTZDeckLinkOpen(const char **errorMessage) {
    *errorMessage = "This build needs the Blackmagic DeckLink SDK to capture from the UltraStudio.";
    return nullptr;
}

CVPixelBufferRef PTZDeckLinkCopyFrame(void *) { return nullptr; }
void PTZDeckLinkClose(void *) {}
#endif
