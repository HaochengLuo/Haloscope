import Foundation

/// Capabilities that are safe to use for the current distribution channel.
///
/// Keep channel decisions here so a Preview build cannot accidentally present
/// a signed-only capability as available.
enum DistributionChannel {
    #if HALOSCOPE_UNSIGNED_PREVIEW
    static let kind = "unsigned-preview"
    static let displayName = "Haloscope Preview"
    static let bundleIdentifier = "com.lamluo.haloscope.preview"
    static let supportsWidget = false
    static let supportsSharedStorage = false
    static let supportsLoginItem = false
    static let supportsAutomaticUpdates = false
    static let isAppleTrustedDistribution = false
    #else
    static let kind = "developer-id"
    static let displayName = "Haloscope"
    static let bundleIdentifier = "com.lamluo.haloscope"
    static let supportsWidget = true
    static let supportsSharedStorage = true
    static let supportsLoginItem = true
    static let supportsAutomaticUpdates = false
    static let isAppleTrustedDistribution = true
    #endif

    static let previewLabel = "Unsigned Preview"
}
