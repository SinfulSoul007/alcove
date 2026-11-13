import Foundation
import BrowserCore

func runExtensionStoreLocationChecks(_ check:(Bool,String)->Void) throws {
    let id = String(repeating:"a",count:32)
    for input in [id," \n"+id+"\t","https://chromewebstore.google.com/detail/"+id,"https://chromewebstore.google.com/detail/owned-fixture/"+id+"?hl=en&utm_source=fixture","https://chrome.google.com/webstore/detail/owned-fixture/"+id] {
        let location = try ExtensionStoreLocation(input)
        check(location.id == id && location.url.absoluteString == "https://chromewebstore.google.com/detail/"+id,"A supported Web Store ID/link resolves only its canonical extension identity")
    }
    func invalid(_ input:String) -> Bool {do {_ = try ExtensionStoreLocation(input);return false} catch {return true}}
    for input in ["",String(repeating:"a",count:31),String(repeating:"a",count:33),String(repeating:"q",count:32),String(repeating:"а",count:32),"http://chromewebstore.google.com/detail/"+id,"https://chromewebstore.google.com.evil.invalid/detail/"+id,"https://user@chromewebstore.google.com/detail/"+id,"https://chromewebstore.google.com:8443/detail/"+id,"https://chromewebstore.google.com/other/"+id,"https://chromewebstore.google.com/detail/"+id+"/extra","https://chromewebstore.google.com/detail/%61"+String(id.dropFirst()),"https://chromewebstore.google.com/detail/../"+id] {
        check(invalid(input),"An invalid or misleading store location is rejected: "+input)
    }
    let version = "143.0.1234.56"
    func metadata(_ version:String,name:String? = nil,platform:ExtensionStorePlatform = .arm64) throws -> Data {
        try JSONSerialization.data(withJSONObject:["versions":[["name":name ?? "chrome/platforms/\(platform.rawValue)/channels/stable/versions/\(version)","version":version]]])
    }
    check(try ExtensionStoreCatalog.selectionVersion(from:metadata(version),platform:.arm64) == version,"Package selection reads a validated four-part version from the exact stable platform metadata")
    check(try ExtensionStoreCatalog.selectionVersion(from:metadata(version,platform:.x86_64),platform:.x86_64) == version,"Intel package selection uses the separate documented Mac platform")
    func invalidMetadata(_ data:Data) -> Bool {do {_ = try ExtensionStoreCatalog.selectionVersion(from:data,platform:.arm64);return false} catch {return true}}
    for bad in ["143.0.1","143.0.1.2.3","143.0.x.2","143.0.1.2&x=other","4294967296.0.0.1",""] {
        check(invalidMetadata(try metadata(bad)),"Malformed selection versions cannot enter an update request: "+bad)
    }
    check(invalidMetadata(try metadata(version,name:"chrome/platforms/mac/channels/stable/versions/"+version)),"Metadata for another platform cannot select a package version")
    check(invalidMetadata(try metadata(version,name:"chrome/platforms/mac_arm64/channels/beta/versions/"+version)),"Beta metadata cannot stand in for the published stable channel")
    check(invalidMetadata(Data(#"{"versions":[]}"#.utf8)) && invalidMetadata(Data(repeating:32,count:1_048_577)),"Missing and oversized metadata fail before package selection")
    let request = try ExtensionStoreCatalog.downloadURL(id:id,version:version),components = URLComponents(url:request,resolvingAgainstBaseURL:false)!
    let query = Dictionary(uniqueKeysWithValues:components.queryItems!.map{($0.name,$0.value ?? "")})
    check(request.scheme == "https" && request.host == "clients2.google.com" && request.path == "/service/update2/crx" && query == ["response":"redirect","prodversion":version,"acceptformat":"crx3","x":"id="+id+"&uc"],"The official CRX3 request safely encodes the selected version and exactly one extension ID")
    check(ExtensionStoreCatalog.versionURL(platform:.arm64).absoluteString == "https://versionhistory.googleapis.com/v1/chrome/platforms/mac_arm64/channels/stable/versions?order_by=version%20desc&page_size=1","Stable metadata requests are bounded to one numeric-version result")
    check(ExtensionStoreCatalog.allows(request,for:.package) && ExtensionStoreCatalog.allows(URL(string:"https://clients2.googleusercontent.com/crx/blobs/owned/package.crx")!,for:.package),"Package policy accepts the official update endpoint and its exact HTTPS blob origin")
    for value in ["http://clients2.googleusercontent.com/crx/blobs/owned/package.crx","https://clients2.googleusercontent.com.evil.invalid/crx/blobs/owned/package.crx","https://user:password@clients2.googleusercontent.com/crx/blobs/owned/package.crx","https://clients2.googleusercontent.com:8443/crx/blobs/owned/package.crx","https://clients2.googleusercontent.com/other/package.crx","https://clients2.googleusercontent.com/crx/blobs/../package.crx","https://clients2.googleusercontent.com/crx/blobs/owned/package.crx#fragment","https://clients2.google.com/other"] {
        check(!ExtensionStoreCatalog.allows(URL(string:value)!,for:.package),"Redirect policy refuses credentials, downgrades and paths outside the exact download scope: "+value)
    }
    check(!ExtensionStoreCatalog.allows(request,for:.metadata(.arm64)) && !ExtensionStoreCatalog.allows(ExtensionStoreCatalog.versionURL(platform:.x86_64),for:.metadata(.arm64)),"Metadata responses cannot switch service or platform through a redirect")
}
