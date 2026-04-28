import Foundation

enum WebServerType: String, CaseIterable, Codable {
    case apache = "Apache"
    case nginx = "Nginx"
    
    var dockerImage: String {
        switch self {
        case .apache:
            return "httpd"
        case .nginx:
            return "nginx"
        }
    }
    
    var defaultTag: String {
        return "latest"
    }
}

enum DatabaseType: String, CaseIterable, Codable {
    case mysql = "MySQL"
    case mariadb = "MariaDB"
    case postgres = "PostgreSQL"
    
    var dockerImage: String {
        switch self {
        case .mysql:
            return "mysql"
        case .mariadb:
            return "mariadb"
        case .postgres:
            return "postgres"
        }
    }
    
    var defaultTag: String {
        return "latest"
    }
    
    var defaultPort: Int {
        switch self {
        case .mysql, .mariadb:
            return 3306
        case .postgres:
            return 5432
        }
    }
}

enum DatabaseAttachmentMode: String, CaseIterable, Codable {
    case none = "No Database"
    case global = "Global Database"
    case dedicated = "Dedicated Container"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)

        switch raw {
        case DatabaseAttachmentMode.none.rawValue, "Keine Datenbank":
            self = .none
        case DatabaseAttachmentMode.global.rawValue, "Globale Datenbank":
            self = .global
        case DatabaseAttachmentMode.dedicated.rawValue, "Separater Container":
            self = .dedicated
        default:
            self = .global
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .none:
            return rawValue
        case .global:
            return rawValue
        case .dedicated:
            return rawValue
        }
    }
}

enum ApacheMPMType: String, CaseIterable, Codable {
    case event
    case worker
    case prefork
}

struct ServerConfiguration: Codable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var autoStartOnAppLaunch: Bool
    
    var webServerType: WebServerType
    var webServerPort: Int
    var webServerDocumentRoot: String
    var additionalContainerMounts: String
    var webServerCPUs: String
    var webServerMemoryLimit: String
    var webServerAdditionalRunArgs: String
    var apacheSettings: ApacheSettings
    var nginxSettings: NginxSettings
    
    var phpVersion: String
    var phpCPUs: String
    var phpMemoryLimit: String
    var phpSettings: PHPSettings
    
    var databaseAttachmentMode: DatabaseAttachmentMode
    var databaseType: DatabaseType
    var databasePort: Int
    var dedicatedDatabaseCPUs: String
    var dedicatedDatabaseMemoryLimit: String
    var databaseSettings: DatabaseSettings

    var webContainerName: String { "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_web" }
    var phpContainerName: String { "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_php" }
    var dbContainerName: String { "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_db" }
    var dbDataVolumeName: String { "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_database_data" }
    var networkName: String { "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_network" }
    var phpDockerImage: String { "php:\(phpVersion)-fpm" }
    
    init(name: String = "My Server") {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.autoStartOnAppLaunch = true
        
        self.webServerType = .nginx
        self.webServerPort = 8080
        self.webServerDocumentRoot = NSHomeDirectory() + "/Sites"
        self.additionalContainerMounts = ""
        self.webServerCPUs = ""
        self.webServerMemoryLimit = ""
        self.webServerAdditionalRunArgs = ""
        self.apacheSettings = ApacheSettings()
        self.nginxSettings = NginxSettings()
        
        self.phpVersion = PHPVersionCatalog.defaultVersion
        self.phpCPUs = ""
        self.phpMemoryLimit = ""
        self.phpSettings = PHPSettings()
        
        self.databaseType = .mysql
        self.databasePort = 3306
        self.dedicatedDatabaseCPUs = ""
        self.dedicatedDatabaseMemoryLimit = ""
        self.databaseSettings = DatabaseSettings()
        self.databaseAttachmentMode = .global
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case autoStartOnAppLaunch
        case webServerType
        case webServerPort
        case webServerDocumentRoot
        case additionalContainerMounts
        case webServerCPUs
        case webServerMemoryLimit
        case webServerAdditionalRunArgs
        case apacheSettings
        case nginxSettings
        case phpVersion
        case phpCPUs
        case phpMemoryLimit
        case phpSettings
        case databaseType
        case databasePort
        case dedicatedDatabaseCPUs
        case dedicatedDatabaseMemoryLimit
        case databaseSettings
        case databaseAttachmentMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "My Server"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        autoStartOnAppLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartOnAppLaunch) ?? false
        webServerType = try container.decodeIfPresent(WebServerType.self, forKey: .webServerType) ?? .nginx
        webServerPort = try container.decodeIfPresent(Int.self, forKey: .webServerPort) ?? 8080
        webServerDocumentRoot = try container.decodeIfPresent(String.self, forKey: .webServerDocumentRoot) ?? (NSHomeDirectory() + "/Sites")
        additionalContainerMounts = try container.decodeIfPresent(String.self, forKey: .additionalContainerMounts) ?? ""
        webServerCPUs = try container.decodeIfPresent(String.self, forKey: .webServerCPUs) ?? ""
        webServerMemoryLimit = try container.decodeIfPresent(String.self, forKey: .webServerMemoryLimit) ?? ""
        webServerAdditionalRunArgs = try container.decodeIfPresent(String.self, forKey: .webServerAdditionalRunArgs) ?? ""
        apacheSettings = (try? container.decode(ApacheSettings.self, forKey: .apacheSettings)) ?? ApacheSettings()
        nginxSettings = (try? container.decode(NginxSettings.self, forKey: .nginxSettings)) ?? NginxSettings()
        phpVersion = try container.decodeIfPresent(String.self, forKey: .phpVersion)
            ?? LegacyPHPVersion.php83.rawValue
        phpCPUs = try container.decodeIfPresent(String.self, forKey: .phpCPUs) ?? ""
        phpMemoryLimit = try container.decodeIfPresent(String.self, forKey: .phpMemoryLimit) ?? ""
        phpSettings = try container.decodeIfPresent(PHPSettings.self, forKey: .phpSettings) ?? PHPSettings()
        databaseType = try container.decodeIfPresent(DatabaseType.self, forKey: .databaseType) ?? .mysql
        databasePort = try container.decodeIfPresent(Int.self, forKey: .databasePort) ?? 3306
        dedicatedDatabaseCPUs = try container.decodeIfPresent(String.self, forKey: .dedicatedDatabaseCPUs) ?? ""
        dedicatedDatabaseMemoryLimit = try container.decodeIfPresent(String.self, forKey: .dedicatedDatabaseMemoryLimit) ?? ""
        databaseSettings = try container.decodeIfPresent(DatabaseSettings.self, forKey: .databaseSettings) ?? DatabaseSettings()
        databaseAttachmentMode = try container.decodeIfPresent(DatabaseAttachmentMode.self, forKey: .databaseAttachmentMode) ?? .global
    }
}

private enum LegacyPHPVersion: String, CaseIterable, Codable {
    case php83 = "8.3"
    case php82 = "8.2"
    case php81 = "8.1"
    case php80 = "8.0"
    case php74 = "7.4"
}

struct PHPSettings: Codable {
    var memoryLimit: String = "256M"
    var maxExecutionTime: Int = 300
    var maxInputTime: Int = 300
    var maxInputVars: Int = 1000
    var defaultSocketTimeout: Int = 60
    var realpathCacheSize: String = "4096K"
    var realpathCacheTTL: Int = 120
    var uploadMaxFilesize: String = "64M"
    var postMaxSize: String = "64M"
    var fileUploadsEnabled: Bool = true
    var maxFileUploads: Int = 20
    var displayErrors: Bool = true
    var displayStartupErrors: Bool = true
    var logErrors: Bool = true
    var errorLogPath: String = "/proc/self/fd/2"
    var errorReporting: String = "E_ALL"
    var timezone: String = "Europe/Zurich"
    var exposePHP: Bool = false
    var allowURLFopen: Bool = true
    var allowURLInclude: Bool = false
    var disableFunctions: String = ""
    var sessionSaveHandler: String = "files"
    var sessionSavePath: String = "/tmp"
    var sessionGCMaxLifetime: Int = 1440
    var sessionCookieSecure: Bool = false
    var sessionCookieHTTPOnly: Bool = true
    var sessionCookieSameSite: String = "Lax"
    var opcacheEnabled: Bool = true
    var opcacheMemoryConsumption: Int = 128
    var opcacheMaxAcceleratedFiles: Int = 10000
    var opcacheValidateTimestamps: Bool = true
    var opcacheRevalidateFreq: Int = 2
    var opcacheJITEnabled: Bool = false
    var opcacheJITBufferSize: String = "128M"
    var opcacheJITMode: String = "1255"
    var enableMySQLExtensions: Bool = true
    var enableGD: Bool = false
    var enableGDWebP: Bool = false
    var enableGDAvif: Bool = false
    var enableIntl: Bool = false
    var enableZip: Bool = false
    var enableBCMath: Bool = false
    var enableExif: Bool = false
    var enableSOAP: Bool = false
    var enableXSL: Bool = false
    var enablePDOPgSQL: Bool = false
    var enablePgSQL: Bool = false
    var enableMBString: Bool = false
    var enableSockets: Bool = false
    var enablePCNTL: Bool = false
    var enablePDOSQLite: Bool = false
    var enableSQLite3: Bool = false
    var enableCurlExtension: Bool = false
    var enableDOMExtension: Bool = false
    var enableXMLExtension: Bool = false
    var enableSimpleXMLExtension: Bool = false
    var enableFTPExtension: Bool = false
    var enableRedisExtension: Bool = false
    var enableImagickExtension: Bool = false
    var enableXdebugExtension: Bool = false
    var enableSSH2Extension: Bool = false
    var installZipBinaryTools: Bool = false
    var installLibarchiveTools: Bool = false
    var installICUFullData: Bool = false
    var installGitTool: Bool = false
    var installCurlWgetTools: Bool = false
    var installEditorsNanoVim: Bool = false
    var installTreeTool: Bool = false
    var installRsyncTool: Bool = false
    var installFFmpegTool: Bool = false
    var installGhostscriptTool: Bool = false
    var installImageMagickTools: Bool = false
    var installNodeJSTools: Bool = false
    var installComposerTool: Bool = false
    var fpmProcessManager: String = "dynamic"
    var fpmMaxChildren: Int = 20
    var fpmStartServers: Int = 4
    var fpmMinSpareServers: Int = 2
    var fpmMaxSpareServers: Int = 6
    var fpmMaxRequests: Int = 500
    var additionalIniDirectives: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case memoryLimit, maxExecutionTime, maxInputTime, maxInputVars, defaultSocketTimeout, realpathCacheSize, realpathCacheTTL
        case uploadMaxFilesize, postMaxSize, fileUploadsEnabled, maxFileUploads
        case displayErrors, displayStartupErrors, logErrors, errorLogPath, errorReporting, timezone
        case exposePHP, allowURLFopen, allowURLInclude, disableFunctions
        case sessionSaveHandler, sessionSavePath, sessionGCMaxLifetime, sessionCookieSecure, sessionCookieHTTPOnly, sessionCookieSameSite
        case opcacheEnabled, opcacheMemoryConsumption, opcacheMaxAcceleratedFiles, opcacheValidateTimestamps, opcacheRevalidateFreq, opcacheJITEnabled, opcacheJITBufferSize, opcacheJITMode
        case enableMySQLExtensions, enableGD, enableGDWebP, enableGDAvif, enableIntl, enableZip, enableBCMath, enableExif, enableSOAP, enableXSL, enablePDOPgSQL, enablePgSQL, enableMBString, enableSockets, enablePCNTL, enablePDOSQLite, enableSQLite3, enableCurlExtension, enableDOMExtension, enableXMLExtension, enableSimpleXMLExtension, enableFTPExtension, enableRedisExtension, enableImagickExtension, enableXdebugExtension, enableSSH2Extension
        case installZipBinaryTools, installLibarchiveTools, installICUFullData, installGitTool, installCurlWgetTools, installEditorsNanoVim, installTreeTool, installRsyncTool, installFFmpegTool, installGhostscriptTool, installImageMagickTools, installNodeJSTools, installComposerTool
        case fpmProcessManager, fpmMaxChildren, fpmStartServers, fpmMinSpareServers, fpmMaxSpareServers, fpmMaxRequests
        case additionalIniDirectives
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryLimit = try container.decodeIfPresent(String.self, forKey: .memoryLimit) ?? memoryLimit
        maxExecutionTime = try container.decodeIfPresent(Int.self, forKey: .maxExecutionTime) ?? maxExecutionTime
        maxInputTime = try container.decodeIfPresent(Int.self, forKey: .maxInputTime) ?? maxInputTime
        maxInputVars = try container.decodeIfPresent(Int.self, forKey: .maxInputVars) ?? maxInputVars
        defaultSocketTimeout = try container.decodeIfPresent(Int.self, forKey: .defaultSocketTimeout) ?? defaultSocketTimeout
        realpathCacheSize = try container.decodeIfPresent(String.self, forKey: .realpathCacheSize) ?? realpathCacheSize
        realpathCacheTTL = try container.decodeIfPresent(Int.self, forKey: .realpathCacheTTL) ?? realpathCacheTTL
        uploadMaxFilesize = try container.decodeIfPresent(String.self, forKey: .uploadMaxFilesize) ?? uploadMaxFilesize
        postMaxSize = try container.decodeIfPresent(String.self, forKey: .postMaxSize) ?? postMaxSize
        fileUploadsEnabled = try container.decodeIfPresent(Bool.self, forKey: .fileUploadsEnabled) ?? fileUploadsEnabled
        maxFileUploads = try container.decodeIfPresent(Int.self, forKey: .maxFileUploads) ?? maxFileUploads
        displayErrors = try container.decodeIfPresent(Bool.self, forKey: .displayErrors) ?? displayErrors
        displayStartupErrors = try container.decodeIfPresent(Bool.self, forKey: .displayStartupErrors) ?? displayStartupErrors
        logErrors = try container.decodeIfPresent(Bool.self, forKey: .logErrors) ?? logErrors
        errorLogPath = try container.decodeIfPresent(String.self, forKey: .errorLogPath) ?? errorLogPath
        errorReporting = try container.decodeIfPresent(String.self, forKey: .errorReporting) ?? errorReporting
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? timezone
        exposePHP = try container.decodeIfPresent(Bool.self, forKey: .exposePHP) ?? exposePHP
        allowURLFopen = try container.decodeIfPresent(Bool.self, forKey: .allowURLFopen) ?? allowURLFopen
        allowURLInclude = try container.decodeIfPresent(Bool.self, forKey: .allowURLInclude) ?? allowURLInclude
        disableFunctions = try container.decodeIfPresent(String.self, forKey: .disableFunctions) ?? disableFunctions
        sessionSaveHandler = try container.decodeIfPresent(String.self, forKey: .sessionSaveHandler) ?? sessionSaveHandler
        sessionSavePath = try container.decodeIfPresent(String.self, forKey: .sessionSavePath) ?? sessionSavePath
        sessionGCMaxLifetime = try container.decodeIfPresent(Int.self, forKey: .sessionGCMaxLifetime) ?? sessionGCMaxLifetime
        sessionCookieSecure = try container.decodeIfPresent(Bool.self, forKey: .sessionCookieSecure) ?? sessionCookieSecure
        sessionCookieHTTPOnly = try container.decodeIfPresent(Bool.self, forKey: .sessionCookieHTTPOnly) ?? sessionCookieHTTPOnly
        sessionCookieSameSite = try container.decodeIfPresent(String.self, forKey: .sessionCookieSameSite) ?? sessionCookieSameSite
        opcacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .opcacheEnabled) ?? opcacheEnabled
        opcacheMemoryConsumption = try container.decodeIfPresent(Int.self, forKey: .opcacheMemoryConsumption) ?? opcacheMemoryConsumption
        opcacheMaxAcceleratedFiles = try container.decodeIfPresent(Int.self, forKey: .opcacheMaxAcceleratedFiles) ?? opcacheMaxAcceleratedFiles
        opcacheValidateTimestamps = try container.decodeIfPresent(Bool.self, forKey: .opcacheValidateTimestamps) ?? opcacheValidateTimestamps
        opcacheRevalidateFreq = try container.decodeIfPresent(Int.self, forKey: .opcacheRevalidateFreq) ?? opcacheRevalidateFreq
        opcacheJITEnabled = try container.decodeIfPresent(Bool.self, forKey: .opcacheJITEnabled) ?? opcacheJITEnabled
        opcacheJITBufferSize = try container.decodeIfPresent(String.self, forKey: .opcacheJITBufferSize) ?? opcacheJITBufferSize
        opcacheJITMode = try container.decodeIfPresent(String.self, forKey: .opcacheJITMode) ?? opcacheJITMode
        enableMySQLExtensions = try container.decodeIfPresent(Bool.self, forKey: .enableMySQLExtensions) ?? enableMySQLExtensions
        enableGD = try container.decodeIfPresent(Bool.self, forKey: .enableGD) ?? enableGD
        enableGDWebP = try container.decodeIfPresent(Bool.self, forKey: .enableGDWebP) ?? enableGDWebP
        enableGDAvif = try container.decodeIfPresent(Bool.self, forKey: .enableGDAvif) ?? enableGDAvif
        enableIntl = try container.decodeIfPresent(Bool.self, forKey: .enableIntl) ?? enableIntl
        enableZip = try container.decodeIfPresent(Bool.self, forKey: .enableZip) ?? enableZip
        enableBCMath = try container.decodeIfPresent(Bool.self, forKey: .enableBCMath) ?? enableBCMath
        enableExif = try container.decodeIfPresent(Bool.self, forKey: .enableExif) ?? enableExif
        enableSOAP = try container.decodeIfPresent(Bool.self, forKey: .enableSOAP) ?? enableSOAP
        enableXSL = try container.decodeIfPresent(Bool.self, forKey: .enableXSL) ?? enableXSL
        enablePDOPgSQL = try container.decodeIfPresent(Bool.self, forKey: .enablePDOPgSQL) ?? enablePDOPgSQL
        enablePgSQL = try container.decodeIfPresent(Bool.self, forKey: .enablePgSQL) ?? enablePgSQL
        enableMBString = try container.decodeIfPresent(Bool.self, forKey: .enableMBString) ?? enableMBString
        enableSockets = try container.decodeIfPresent(Bool.self, forKey: .enableSockets) ?? enableSockets
        enablePCNTL = try container.decodeIfPresent(Bool.self, forKey: .enablePCNTL) ?? enablePCNTL
        enablePDOSQLite = try container.decodeIfPresent(Bool.self, forKey: .enablePDOSQLite) ?? enablePDOSQLite
        enableSQLite3 = try container.decodeIfPresent(Bool.self, forKey: .enableSQLite3) ?? enableSQLite3
        enableCurlExtension = try container.decodeIfPresent(Bool.self, forKey: .enableCurlExtension) ?? enableCurlExtension
        enableDOMExtension = try container.decodeIfPresent(Bool.self, forKey: .enableDOMExtension) ?? enableDOMExtension
        enableXMLExtension = try container.decodeIfPresent(Bool.self, forKey: .enableXMLExtension) ?? enableXMLExtension
        enableSimpleXMLExtension = try container.decodeIfPresent(Bool.self, forKey: .enableSimpleXMLExtension) ?? enableSimpleXMLExtension
        enableFTPExtension = try container.decodeIfPresent(Bool.self, forKey: .enableFTPExtension) ?? enableFTPExtension
        enableRedisExtension = try container.decodeIfPresent(Bool.self, forKey: .enableRedisExtension) ?? enableRedisExtension
        enableImagickExtension = try container.decodeIfPresent(Bool.self, forKey: .enableImagickExtension) ?? enableImagickExtension
        enableXdebugExtension = try container.decodeIfPresent(Bool.self, forKey: .enableXdebugExtension) ?? enableXdebugExtension
        enableSSH2Extension = try container.decodeIfPresent(Bool.self, forKey: .enableSSH2Extension) ?? enableSSH2Extension
        installZipBinaryTools = try container.decodeIfPresent(Bool.self, forKey: .installZipBinaryTools) ?? installZipBinaryTools
        installLibarchiveTools = try container.decodeIfPresent(Bool.self, forKey: .installLibarchiveTools) ?? installLibarchiveTools
        installICUFullData = try container.decodeIfPresent(Bool.self, forKey: .installICUFullData) ?? installICUFullData
        installGitTool = try container.decodeIfPresent(Bool.self, forKey: .installGitTool) ?? installGitTool
        installCurlWgetTools = try container.decodeIfPresent(Bool.self, forKey: .installCurlWgetTools) ?? installCurlWgetTools
        installEditorsNanoVim = try container.decodeIfPresent(Bool.self, forKey: .installEditorsNanoVim) ?? installEditorsNanoVim
        installTreeTool = try container.decodeIfPresent(Bool.self, forKey: .installTreeTool) ?? installTreeTool
        installRsyncTool = try container.decodeIfPresent(Bool.self, forKey: .installRsyncTool) ?? installRsyncTool
        installFFmpegTool = try container.decodeIfPresent(Bool.self, forKey: .installFFmpegTool) ?? installFFmpegTool
        installGhostscriptTool = try container.decodeIfPresent(Bool.self, forKey: .installGhostscriptTool) ?? installGhostscriptTool
        installImageMagickTools = try container.decodeIfPresent(Bool.self, forKey: .installImageMagickTools) ?? installImageMagickTools
        installNodeJSTools = try container.decodeIfPresent(Bool.self, forKey: .installNodeJSTools) ?? installNodeJSTools
        installComposerTool = try container.decodeIfPresent(Bool.self, forKey: .installComposerTool) ?? installComposerTool
        fpmProcessManager = try container.decodeIfPresent(String.self, forKey: .fpmProcessManager) ?? fpmProcessManager
        fpmMaxChildren = try container.decodeIfPresent(Int.self, forKey: .fpmMaxChildren) ?? fpmMaxChildren
        fpmStartServers = try container.decodeIfPresent(Int.self, forKey: .fpmStartServers) ?? fpmStartServers
        fpmMinSpareServers = try container.decodeIfPresent(Int.self, forKey: .fpmMinSpareServers) ?? fpmMinSpareServers
        fpmMaxSpareServers = try container.decodeIfPresent(Int.self, forKey: .fpmMaxSpareServers) ?? fpmMaxSpareServers
        fpmMaxRequests = try container.decodeIfPresent(Int.self, forKey: .fpmMaxRequests) ?? fpmMaxRequests
        additionalIniDirectives = try container.decodeIfPresent(String.self, forKey: .additionalIniDirectives) ?? additionalIniDirectives
    }
}

struct ApacheSettings: Codable {
    var mpmType: ApacheMPMType = .event
    var startServers: Int = 2
    var serverLimit: Int = 2
    var threadsPerChild: Int = 25
    var minSpareThreads: Int = 10
    var maxSpareThreads: Int = 25
    var maxRequestWorkers: Int = 50
    var timeout: Int = 60
    var proxyTimeout: Int = 60
    var requestReadTimeout: String = "header=20-40,MinRate=500 body=20,MinRate=500"
    var keepAliveEnabled: Bool = true
    var maxKeepAliveRequests: Int = 1000
    var keepAliveTimeout: Int = 2
    var traceEnableOff: Bool = true
    var serverSignatureOff: Bool = true
    var enableSendfile: Bool = false
    var enableMMAP: Bool = false
    var serverTokensProd: Bool = true
    var enableDeflate: Bool = true
    var enableRewrite: Bool = true
    var enableExpires: Bool = false
    var expiresDefault: String = "access plus 7 days"
    var fileETagEnabled: Bool = false
    var requireAllGranted: Bool = true
    var restrictToSpecificIPs: Bool = false
    var allowedIPs: String = ""
    var allowOverrideAll: Bool = true
    var optionIndexes: Bool = false
    var optionIncludes: Bool = false
    var optionExecCGI: Bool = false
    var optionSymLinksIfOwnerMatch: Bool = false
    var optionIncludesNoExec: Bool = false
    var optionFollowSymLinks: Bool = true
    var optionMultiViews: Bool = false
    var forceDirectoryListing: Bool = false
    var logLevel: String = "warn"
    var customLogFormat: String = "%h %l %u %t \\\"%r\\\" %>s %b"
    var customLogTarget: String = "/proc/self/fd/1"
    var errorLogTarget: String = "/proc/self/fd/2"
    var limitRequestBody: Int = 0
    var limitRequestFields: Int = 100
    var limitRequestLine: Int = 8190
    var headerXFrameOptionsEnabled: Bool = true
    var headerXFrameOptionsValue: String = "SAMEORIGIN"
    var headerXContentTypeOptionsEnabled: Bool = true
    var headerReferrerPolicyEnabled: Bool = true
    var headerReferrerPolicyValue: String = "strict-origin-when-cross-origin"
    var headerCSPEnabled: Bool = false
    var headerCSPValue: String = "default-src 'self';"
    var proxyPreserveHost: Bool = true
    var sslProxyEngineEnabled: Bool = false
    var proxyPassRules: String = ""
    var virtualHostDirectives: String = ""
    var additionalDirectives: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mpmType, startServers, serverLimit, threadsPerChild, minSpareThreads, maxSpareThreads, maxRequestWorkers
        case timeout, proxyTimeout, requestReadTimeout
        case keepAliveEnabled, maxKeepAliveRequests, keepAliveTimeout
        case traceEnableOff, serverSignatureOff, enableSendfile, enableMMAP, serverTokensProd, enableDeflate, enableRewrite
        case enableExpires, expiresDefault, fileETagEnabled
        case requireAllGranted, restrictToSpecificIPs, allowedIPs, allowOverrideAll
        case optionIndexes, optionIncludes, optionExecCGI, optionSymLinksIfOwnerMatch, optionIncludesNoExec, optionFollowSymLinks, optionMultiViews
        case forceDirectoryListing
        case logLevel, customLogFormat, customLogTarget, errorLogTarget
        case limitRequestBody, limitRequestFields, limitRequestLine
        case headerXFrameOptionsEnabled, headerXFrameOptionsValue
        case headerXContentTypeOptionsEnabled
        case headerReferrerPolicyEnabled, headerReferrerPolicyValue
        case headerCSPEnabled, headerCSPValue
        case proxyPreserveHost, sslProxyEngineEnabled, proxyPassRules
        case virtualHostDirectives, additionalDirectives
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mpmType = try container.decodeIfPresent(ApacheMPMType.self, forKey: .mpmType) ?? mpmType
        startServers = try container.decodeIfPresent(Int.self, forKey: .startServers) ?? startServers
        serverLimit = try container.decodeIfPresent(Int.self, forKey: .serverLimit) ?? serverLimit
        threadsPerChild = try container.decodeIfPresent(Int.self, forKey: .threadsPerChild) ?? threadsPerChild
        minSpareThreads = try container.decodeIfPresent(Int.self, forKey: .minSpareThreads) ?? minSpareThreads
        maxSpareThreads = try container.decodeIfPresent(Int.self, forKey: .maxSpareThreads) ?? maxSpareThreads
        maxRequestWorkers = try container.decodeIfPresent(Int.self, forKey: .maxRequestWorkers) ?? maxRequestWorkers
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? timeout
        proxyTimeout = try container.decodeIfPresent(Int.self, forKey: .proxyTimeout) ?? proxyTimeout
        requestReadTimeout = try container.decodeIfPresent(String.self, forKey: .requestReadTimeout) ?? requestReadTimeout
        keepAliveEnabled = try container.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? keepAliveEnabled
        maxKeepAliveRequests = try container.decodeIfPresent(Int.self, forKey: .maxKeepAliveRequests) ?? maxKeepAliveRequests
        keepAliveTimeout = try container.decodeIfPresent(Int.self, forKey: .keepAliveTimeout) ?? keepAliveTimeout
        traceEnableOff = try container.decodeIfPresent(Bool.self, forKey: .traceEnableOff) ?? traceEnableOff
        serverSignatureOff = try container.decodeIfPresent(Bool.self, forKey: .serverSignatureOff) ?? serverSignatureOff
        enableSendfile = try container.decodeIfPresent(Bool.self, forKey: .enableSendfile) ?? enableSendfile
        enableMMAP = try container.decodeIfPresent(Bool.self, forKey: .enableMMAP) ?? enableMMAP
        serverTokensProd = try container.decodeIfPresent(Bool.self, forKey: .serverTokensProd) ?? serverTokensProd
        enableDeflate = try container.decodeIfPresent(Bool.self, forKey: .enableDeflate) ?? enableDeflate
        enableRewrite = try container.decodeIfPresent(Bool.self, forKey: .enableRewrite) ?? enableRewrite
        enableExpires = try container.decodeIfPresent(Bool.self, forKey: .enableExpires) ?? enableExpires
        expiresDefault = try container.decodeIfPresent(String.self, forKey: .expiresDefault) ?? expiresDefault
        fileETagEnabled = try container.decodeIfPresent(Bool.self, forKey: .fileETagEnabled) ?? fileETagEnabled
        requireAllGranted = try container.decodeIfPresent(Bool.self, forKey: .requireAllGranted) ?? requireAllGranted
        restrictToSpecificIPs = try container.decodeIfPresent(Bool.self, forKey: .restrictToSpecificIPs) ?? restrictToSpecificIPs
        allowedIPs = try container.decodeIfPresent(String.self, forKey: .allowedIPs) ?? allowedIPs
        allowOverrideAll = try container.decodeIfPresent(Bool.self, forKey: .allowOverrideAll) ?? allowOverrideAll
        optionIndexes = try container.decodeIfPresent(Bool.self, forKey: .optionIndexes) ?? optionIndexes
        optionIncludes = try container.decodeIfPresent(Bool.self, forKey: .optionIncludes) ?? optionIncludes
        optionExecCGI = try container.decodeIfPresent(Bool.self, forKey: .optionExecCGI) ?? optionExecCGI
        optionSymLinksIfOwnerMatch = try container.decodeIfPresent(Bool.self, forKey: .optionSymLinksIfOwnerMatch) ?? optionSymLinksIfOwnerMatch
        optionIncludesNoExec = try container.decodeIfPresent(Bool.self, forKey: .optionIncludesNoExec) ?? optionIncludesNoExec
        optionFollowSymLinks = try container.decodeIfPresent(Bool.self, forKey: .optionFollowSymLinks) ?? optionFollowSymLinks
        optionMultiViews = try container.decodeIfPresent(Bool.self, forKey: .optionMultiViews) ?? optionMultiViews
        forceDirectoryListing = try container.decodeIfPresent(Bool.self, forKey: .forceDirectoryListing) ?? forceDirectoryListing
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? logLevel
        customLogFormat = try container.decodeIfPresent(String.self, forKey: .customLogFormat) ?? customLogFormat
        customLogTarget = try container.decodeIfPresent(String.self, forKey: .customLogTarget) ?? customLogTarget
        errorLogTarget = try container.decodeIfPresent(String.self, forKey: .errorLogTarget) ?? errorLogTarget
        limitRequestBody = try container.decodeIfPresent(Int.self, forKey: .limitRequestBody) ?? limitRequestBody
        limitRequestFields = try container.decodeIfPresent(Int.self, forKey: .limitRequestFields) ?? limitRequestFields
        limitRequestLine = try container.decodeIfPresent(Int.self, forKey: .limitRequestLine) ?? limitRequestLine
        headerXFrameOptionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerXFrameOptionsEnabled) ?? headerXFrameOptionsEnabled
        headerXFrameOptionsValue = try container.decodeIfPresent(String.self, forKey: .headerXFrameOptionsValue) ?? headerXFrameOptionsValue
        headerXContentTypeOptionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerXContentTypeOptionsEnabled) ?? headerXContentTypeOptionsEnabled
        headerReferrerPolicyEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerReferrerPolicyEnabled) ?? headerReferrerPolicyEnabled
        headerReferrerPolicyValue = try container.decodeIfPresent(String.self, forKey: .headerReferrerPolicyValue) ?? headerReferrerPolicyValue
        headerCSPEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerCSPEnabled) ?? headerCSPEnabled
        headerCSPValue = try container.decodeIfPresent(String.self, forKey: .headerCSPValue) ?? headerCSPValue
        proxyPreserveHost = try container.decodeIfPresent(Bool.self, forKey: .proxyPreserveHost) ?? proxyPreserveHost
        sslProxyEngineEnabled = try container.decodeIfPresent(Bool.self, forKey: .sslProxyEngineEnabled) ?? sslProxyEngineEnabled
        proxyPassRules = try container.decodeIfPresent(String.self, forKey: .proxyPassRules) ?? proxyPassRules
        virtualHostDirectives = try container.decodeIfPresent(String.self, forKey: .virtualHostDirectives) ?? virtualHostDirectives
        additionalDirectives = try container.decodeIfPresent(String.self, forKey: .additionalDirectives) ?? additionalDirectives
    }
}

struct NginxSettings: Codable {
    var workerProcesses: String = "auto"
    var workerConnections: Int = 1024
    var keepaliveTimeout: Int = 65
    var sendfileEnabled: Bool = true
    var tcpNopushEnabled: Bool = true
    var tcpNodelayEnabled: Bool = true
    var clientBodyTimeout: Int = 60
    var clientHeaderTimeout: Int = 60
    var sendTimeout: Int = 60
    var clientMaxBodySize: String = "64m"
    var gzipEnabled: Bool = true
    var gzipMinLength: Int = 1024
    var tryFilesRule: String = "$uri $uri/ /index.php?$query_string"
    var fastcgiConnectTimeout: Int = 60
    var fastcgiSendTimeout: Int = 60
    var fastcgiReadTimeout: Int = 300
    var fastcgiBufferSize: String = "32k"
    var fastcgiBuffersCount: Int = 8
    var fastcgiBuffersSize: String = "16k"
    var proxyConnectTimeout: Int = 60
    var proxySendTimeout: Int = 60
    var proxyReadTimeout: Int = 60
    var autoIndexEnabled: Bool = false
    var accessLogEnabled: Bool = true
    var errorLogLevel: String = "warn"
    var headerXFrameOptionsEnabled: Bool = true
    var headerXFrameOptionsValue: String = "SAMEORIGIN"
    var headerXContentTypeOptionsEnabled: Bool = true
    var headerReferrerPolicyEnabled: Bool = true
    var headerReferrerPolicyValue: String = "strict-origin-when-cross-origin"
    var headerCSPEnabled: Bool = false
    var headerCSPValue: String = "default-src 'self';"
    var staticCacheEnabled: Bool = false
    var staticCacheExpires: String = "7d"
    var additionalServerDirectives: String = ""
    var additionalLocationDirectives: String = ""
    var additionalLocationBlocks: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case workerProcesses, workerConnections, keepaliveTimeout
        case sendfileEnabled, tcpNopushEnabled, tcpNodelayEnabled
        case clientBodyTimeout, clientHeaderTimeout, sendTimeout
        case clientMaxBodySize, gzipEnabled, gzipMinLength, tryFilesRule
        case fastcgiConnectTimeout, fastcgiSendTimeout, fastcgiReadTimeout
        case fastcgiBufferSize, fastcgiBuffersCount, fastcgiBuffersSize
        case proxyConnectTimeout, proxySendTimeout, proxyReadTimeout
        case autoIndexEnabled, accessLogEnabled, errorLogLevel
        case headerXFrameOptionsEnabled, headerXFrameOptionsValue
        case headerXContentTypeOptionsEnabled
        case headerReferrerPolicyEnabled, headerReferrerPolicyValue
        case headerCSPEnabled, headerCSPValue
        case staticCacheEnabled, staticCacheExpires
        case additionalServerDirectives, additionalLocationDirectives, additionalLocationBlocks
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workerProcesses = try container.decodeIfPresent(String.self, forKey: .workerProcesses) ?? workerProcesses
        workerConnections = try container.decodeIfPresent(Int.self, forKey: .workerConnections) ?? workerConnections
        keepaliveTimeout = try container.decodeIfPresent(Int.self, forKey: .keepaliveTimeout) ?? keepaliveTimeout
        sendfileEnabled = try container.decodeIfPresent(Bool.self, forKey: .sendfileEnabled) ?? sendfileEnabled
        tcpNopushEnabled = try container.decodeIfPresent(Bool.self, forKey: .tcpNopushEnabled) ?? tcpNopushEnabled
        tcpNodelayEnabled = try container.decodeIfPresent(Bool.self, forKey: .tcpNodelayEnabled) ?? tcpNodelayEnabled
        clientBodyTimeout = try container.decodeIfPresent(Int.self, forKey: .clientBodyTimeout) ?? clientBodyTimeout
        clientHeaderTimeout = try container.decodeIfPresent(Int.self, forKey: .clientHeaderTimeout) ?? clientHeaderTimeout
        sendTimeout = try container.decodeIfPresent(Int.self, forKey: .sendTimeout) ?? sendTimeout
        clientMaxBodySize = try container.decodeIfPresent(String.self, forKey: .clientMaxBodySize) ?? clientMaxBodySize
        gzipEnabled = try container.decodeIfPresent(Bool.self, forKey: .gzipEnabled) ?? gzipEnabled
        gzipMinLength = try container.decodeIfPresent(Int.self, forKey: .gzipMinLength) ?? gzipMinLength
        tryFilesRule = try container.decodeIfPresent(String.self, forKey: .tryFilesRule) ?? tryFilesRule
        fastcgiConnectTimeout = try container.decodeIfPresent(Int.self, forKey: .fastcgiConnectTimeout) ?? fastcgiConnectTimeout
        fastcgiSendTimeout = try container.decodeIfPresent(Int.self, forKey: .fastcgiSendTimeout) ?? fastcgiSendTimeout
        fastcgiReadTimeout = try container.decodeIfPresent(Int.self, forKey: .fastcgiReadTimeout) ?? fastcgiReadTimeout
        fastcgiBufferSize = try container.decodeIfPresent(String.self, forKey: .fastcgiBufferSize) ?? fastcgiBufferSize
        fastcgiBuffersCount = try container.decodeIfPresent(Int.self, forKey: .fastcgiBuffersCount) ?? fastcgiBuffersCount
        fastcgiBuffersSize = try container.decodeIfPresent(String.self, forKey: .fastcgiBuffersSize) ?? fastcgiBuffersSize
        proxyConnectTimeout = try container.decodeIfPresent(Int.self, forKey: .proxyConnectTimeout) ?? proxyConnectTimeout
        proxySendTimeout = try container.decodeIfPresent(Int.self, forKey: .proxySendTimeout) ?? proxySendTimeout
        proxyReadTimeout = try container.decodeIfPresent(Int.self, forKey: .proxyReadTimeout) ?? proxyReadTimeout
        autoIndexEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoIndexEnabled) ?? autoIndexEnabled
        accessLogEnabled = try container.decodeIfPresent(Bool.self, forKey: .accessLogEnabled) ?? accessLogEnabled
        errorLogLevel = try container.decodeIfPresent(String.self, forKey: .errorLogLevel) ?? errorLogLevel
        headerXFrameOptionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerXFrameOptionsEnabled) ?? headerXFrameOptionsEnabled
        headerXFrameOptionsValue = try container.decodeIfPresent(String.self, forKey: .headerXFrameOptionsValue) ?? headerXFrameOptionsValue
        headerXContentTypeOptionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerXContentTypeOptionsEnabled) ?? headerXContentTypeOptionsEnabled
        headerReferrerPolicyEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerReferrerPolicyEnabled) ?? headerReferrerPolicyEnabled
        headerReferrerPolicyValue = try container.decodeIfPresent(String.self, forKey: .headerReferrerPolicyValue) ?? headerReferrerPolicyValue
        headerCSPEnabled = try container.decodeIfPresent(Bool.self, forKey: .headerCSPEnabled) ?? headerCSPEnabled
        headerCSPValue = try container.decodeIfPresent(String.self, forKey: .headerCSPValue) ?? headerCSPValue
        staticCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .staticCacheEnabled) ?? staticCacheEnabled
        staticCacheExpires = try container.decodeIfPresent(String.self, forKey: .staticCacheExpires) ?? staticCacheExpires
        additionalServerDirectives = try container.decodeIfPresent(String.self, forKey: .additionalServerDirectives) ?? additionalServerDirectives
        additionalLocationDirectives = try container.decodeIfPresent(String.self, forKey: .additionalLocationDirectives) ?? additionalLocationDirectives
        additionalLocationBlocks = try container.decodeIfPresent(String.self, forKey: .additionalLocationBlocks) ?? additionalLocationBlocks
    }
}

struct DatabaseSettings: Codable {
    var rootPassword: String = "root"
    var databaseName: String = "development"
    var username: String = "devuser"
    var password: String = "devpassword"
    var maxConnections: Int = 150
    var queryCache: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case rootPassword, databaseName, username, password, maxConnections, queryCache
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedRoot = try container.decodeIfPresent(String.self, forKey: .rootPassword) ?? rootPassword
        rootPassword = Self.normalizeLegacyRootPassword(decodedRoot)
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName) ?? databaseName
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? username
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? password
        maxConnections = try container.decodeIfPresent(Int.self, forKey: .maxConnections) ?? maxConnections
        queryCache = try container.decodeIfPresent(Bool.self, forKey: .queryCache) ?? queryCache
    }

    private static func normalizeLegacyRootPassword(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "root'" {
            return "root"
        }
        return trimmed
    }
}

struct ProxyManagerSettings: Codable {
    var isEnabled: Bool = false
    var autoStartOnAppLaunch: Bool = true
    var httpPort: Int = 80
    var httpsPort: Int = 443
    var adminPort: Int = 81
    var useNamedVolumes: Bool = true
    var dataMountPath: String = NSHomeDirectory() + "/Docker/DockAMP/nginx-proxy-manager/data"
    var letsEncryptMountPath: String = NSHomeDirectory() + "/Docker/DockAMP/nginx-proxy-manager/letsencrypt"
    var cpus: String = ""
    var memoryLimit: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, autoStartOnAppLaunch, httpPort, httpsPort, adminPort, useNamedVolumes, dataMountPath, letsEncryptMountPath, cpus, memoryLimit
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        autoStartOnAppLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartOnAppLaunch) ?? autoStartOnAppLaunch
        httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? httpPort
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort) ?? httpsPort
        adminPort = try container.decodeIfPresent(Int.self, forKey: .adminPort) ?? adminPort
        useNamedVolumes = try container.decodeIfPresent(Bool.self, forKey: .useNamedVolumes) ?? useNamedVolumes
        dataMountPath = try container.decodeIfPresent(String.self, forKey: .dataMountPath) ?? dataMountPath
        letsEncryptMountPath = try container.decodeIfPresent(String.self, forKey: .letsEncryptMountPath) ?? letsEncryptMountPath
        cpus = try container.decodeIfPresent(String.self, forKey: .cpus) ?? cpus
        memoryLimit = try container.decodeIfPresent(String.self, forKey: .memoryLimit) ?? memoryLimit
    }
}

enum ContainerStatus: String {
    case running = "running"
    case stopped = "stopped"
    case starting = "starting"
    case stopping = "stopping"
    case error = "error"
    case notCreated = "not_created"
}

struct ContainerInfo {
    let name: String
    let status: ContainerStatus
    let uptime: String?
    let image: String
    let ports: [String]
}
