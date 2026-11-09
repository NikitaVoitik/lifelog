// Template for phone/Sources/Secrets.swift, which phone/build.sh generates from ~/Lifelog/config.json (or from the
// LIFELOG_CLOUD_URL / LIFELOG_PHONE_TOKEN environment variables). The real file is gitignored: it holds your Worker URL
// and the phone's upload-only token. You only need to write it by hand if you build from Xcode without build.sh:
//   cp phone/Secrets.example.swift phone/Sources/Secrets.swift   and fill in the values.
enum Secrets {
    static let url = "https://lifelog.<your-subdomain>.workers.dev"  // cloudUrl
    static let token = ""                                             // phoneToken (upload-only)
    static let device = "iphone"                                      // phoneDeviceId
}
