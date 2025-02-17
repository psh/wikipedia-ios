@objc(WMFRouter)
public class Router: NSObject {
    public enum Destination: Equatable {
        case inAppLink(_: URL)
        case externalLink(_: URL)
        case article(_: URL)
        case articleHistory(_: URL, articleTitle: String)
        case articleDiffCompare(_: URL, fromRevID: Int?, toRevID: Int?)
        case articleDiffSingle(_: URL, fromRevID: Int?, toRevID: Int?)
        case talk(_: URL)
        case userTalk(_: URL)
        case search(_: URL, term: String?)
        case audio(_: URL)
        case onThisDay(_: Int?)
    }
    
    unowned let configuration: Configuration
    
    required init(configuration: Configuration) {
        self.configuration = configuration
    }
    
    // MARK: Public
    
    /// Gets the appropriate in-app destination for a given URL
    public func destination(for url: URL) -> Destination {
        
        guard let siteURL = url.wmf_site,
        let project = WikimediaProject(siteURL: siteURL) else {
            
            guard url.isWikimediaHostedAudioFileLink else {
                return webViewDestinationForHostURL(url)
            }
            
            return .audio(url.byMakingAudioFileCompatibilityAdjustments)
        }
        
        return destinationForHostURL(url, project: project)
    }

    public func doesOpenInBrowser(for url: URL) -> Bool {
        return [.externalLink(url), .inAppLink(url)].contains(destination(for: url))
    }
    
    
    // MARK: Internal and Private
    
    private let mobilediffRegexCompare = try! NSRegularExpression(pattern: "^mobilediff/([0-9]+)\\.\\.\\.([0-9]+)", options: .caseInsensitive)
    private let mobilediffRegexSingle = try! NSRegularExpression(pattern: "^mobilediff/([0-9]+)", options: .caseInsensitive)
    private let historyRegex = try! NSRegularExpression(pattern: "^history/(.*)", options: .caseInsensitive)
    
    internal func destinationForWikiResourceURL(_ url: URL, project: WikimediaProject) -> Destination? {
        guard let path = url.wikiResourcePath else {
            return nil
        }
        
        let language = project.languageCode ?? "en"
        let namespaceAndTitle = path.namespaceAndTitleOfWikiResourcePath(with: language)
        let namespace = namespaceAndTitle.0
        let title = namespaceAndTitle.1
        switch namespace {
        case .talk:
            if FeatureFlags.needsNewTalkPage && project.supportsNativeUserTalkPages {
                return .talk(url)
            } else {
                return nil
            }
        case .userTalk:
            return project.supportsNativeUserTalkPages ? .userTalk(url) : nil
        case .special:
            
            guard project.supportsNativeDiffPages else {
                return nil
            }
            
            if let compareDiffMatch = mobilediffRegexCompare.firstMatch(in: title),
                let fromRevID = Int(mobilediffRegexCompare.replacementString(for: compareDiffMatch, in: title, offset: 0, template: "$1")),
                let toRevID = Int(mobilediffRegexCompare.replacementString(for: compareDiffMatch, in: title, offset: 0, template: "$2")) {
                
                return .articleDiffCompare(url, fromRevID: fromRevID, toRevID: toRevID)
            }
            if let singleDiffMatch = mobilediffRegexSingle.firstReplacementString(in: title),
                let toRevID = Int(singleDiffMatch) {
                return .articleDiffSingle(url, fromRevID: nil, toRevID: toRevID)
            }
            
            if let articleTitle = historyRegex.firstReplacementString(in: title)?.normalizedPageTitle {
                return .articleHistory(url, articleTitle: articleTitle)
            }
            
            return nil
        case .main:
            
            guard project.mainNamespaceGoesToNativeArticleView else {
                return nil
            }
            
            return WikipediaURLTranslations.isMainpageTitle(title, in: language) ? nil : Destination.article(url)
        case .wikipedia:
            
            guard project.considersWResourcePathsForRouting else {
                return nil
            }
            
            let onThisDayURLSnippet = "On_this_day"
            if title.uppercased().contains(onThisDayURLSnippet.uppercased()) {
                // URL in form of https://en.wikipedia.org/wiki/Wikipedia:On_this_day/Today?3. Take bit past question mark.
                if let selected = url.query {
                    return .onThisDay(Int(selected))
                } else {
                    return .onThisDay(nil)
                }
            } else {
                fallthrough
            }
        default:
            return nil
        }
    }
    
    internal func destinationForWResourceURL(_ url: URL, project: WikimediaProject) -> Destination? {
        
        guard project.considersWResourcePathsForRouting,
              let path = url.wResourcePath else {
            return nil
        }
        
        guard var components = URLComponents(string: path) else {
            return nil
        }
        components.query = url.query
        guard components.path.lowercased() == "index.php" else {
            return nil
        }
        guard let queryItems = components.queryItems else {
            return nil
        }
        
        var params: [String: String] = [:]
        params.reserveCapacity(queryItems.count)
        for item in queryItems {
            params[item.name] = item.value
        }
        
        if let search = params["search"] {
            return .search(url, term: search)
        }
        
        let maybeTitle = params["title"]
        let maybeDiff = params["diff"]
        let maybeOldID = params["oldid"]
        let maybeType = params["type"]
        let maybeAction = params["action"]
        let maybeDir = params["dir"]
        let maybeLimit = params["limit"]
        
        guard let title = maybeTitle else {
            return nil
        }
        
        if maybeLimit != nil,
            maybeDir != nil,
            let action = maybeAction,
            action == "history" {
            // TODO: push history 'slice'
            return .articleHistory(url, articleTitle: title)
        } else if let action = maybeAction,
            action == "history" {
            return .articleHistory(url, articleTitle: title)
        } else if let type = maybeType,
            type == "revision",
            let diffString = maybeDiff,
            let oldIDString = maybeOldID,
            let toRevID = Int(diffString),
            let fromRevID = Int(oldIDString) {
            return .articleDiffCompare(url, fromRevID: fromRevID, toRevID: toRevID)
        } else if let diff = maybeDiff,
            diff == "prev",
            let oldIDString = maybeOldID,
            let toRevID = Int(oldIDString) {
            return .articleDiffCompare(url, fromRevID: nil, toRevID: toRevID)
        } else if let diff = maybeDiff,
            diff == "next",
            let oldIDString = maybeOldID,
            let fromRevID = Int(oldIDString) {
            return .articleDiffCompare(url, fromRevID: fromRevID, toRevID: nil)
        } else if let oldIDString = maybeOldID,
            let toRevID = Int(oldIDString) {
            return .articleDiffSingle(url, fromRevID: nil, toRevID: toRevID)
        }
        
        return nil
    }
    
    internal func destinationForHostURL(_ url: URL, project: WikimediaProject) -> Destination {
        let canonicalURL = url.canonical
        
        if let wikiResourcePathInfo = destinationForWikiResourceURL(canonicalURL, project: project) {
            return wikiResourcePathInfo
        }
        
        if let wResourcePathInfo = destinationForWResourceURL(canonicalURL, project: project) {
            return wResourcePathInfo
        }
        
        return webViewDestinationForHostURL(url)
    }
    
    internal func webViewDestinationForHostURL(_ url: URL) -> Destination {
        let canonicalURL = url.canonical
        
        if configuration.hostCanRouteToInAppWebView(url.host) {
            return .inAppLink(canonicalURL)
        } else {
            return .externalLink(url)
        }
    }
}
