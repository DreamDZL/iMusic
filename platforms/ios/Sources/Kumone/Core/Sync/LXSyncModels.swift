import Foundation

/// Wire models for the `list` feature of LX Sync Server. The server's list
/// payload is intentionally kept separate from the app's presentation model.
struct LXSyncListData: Codable, Equatable {
    var defaultList: [LXSyncMusicInfo]
    var loveList: [LXSyncMusicInfo]
    var userList: [LXSyncUserPlaylist]

    init(
        defaultList: [LXSyncMusicInfo] = [],
        loveList: [LXSyncMusicInfo] = [],
        userList: [LXSyncUserPlaylist] = []
    ) {
        self.defaultList = defaultList
        self.loveList = loveList
        self.userList = userList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultList = (try? container.decode([LXSyncMusicInfo].self, forKey: .defaultList)) ?? []
        loveList = (try? container.decode([LXSyncMusicInfo].self, forKey: .loveList)) ?? []
        userList = (try? container.decode([LXSyncUserPlaylist].self, forKey: .userList)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case defaultList, loveList, userList
    }
}

struct LXSyncUserPlaylist: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var source: String?
    var sourceListId: String?
    var locationUpdateTime: Int?
    var list: [LXSyncMusicInfo]
    /// Optional iMusic metadata survives on the LX server while remaining
    /// safely ignorable by other LX Music clients.
    var iMusicSourceName: String?
    var iMusicCoverURL: String?
    var iMusicLocalCopy: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, source, sourceListId, locationUpdateTime, list
        case iMusicSourceName, iMusicCoverURL, iMusicLocalCopy
    }

    init(
        id: String,
        name: String,
        source: String? = nil,
        sourceListId: String? = nil,
        locationUpdateTime: Int? = nil,
        list: [LXSyncMusicInfo] = [],
        iMusicSourceName: String? = nil,
        iMusicCoverURL: String? = nil,
        iMusicLocalCopy: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceListId = sourceListId
        self.locationUpdateTime = locationUpdateTime
        self.list = list
        self.iMusicSourceName = iMusicSourceName
        self.iMusicCoverURL = iMusicCoverURL
        self.iMusicLocalCopy = iMusicLocalCopy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "iMusic 歌单"
        source = try? container.decode(String.self, forKey: .source)
        sourceListId = try? container.decode(String.self, forKey: .sourceListId)
        locationUpdateTime = try? container.decode(Int.self, forKey: .locationUpdateTime)
        list = (try? container.decode([LXSyncMusicInfo].self, forKey: .list)) ?? []
        iMusicSourceName = try? container.decode(String.self, forKey: .iMusicSourceName)
        iMusicCoverURL = try? container.decode(String.self, forKey: .iMusicCoverURL)
        iMusicLocalCopy = try? container.decode(Bool.self, forKey: .iMusicLocalCopy)
    }
}

struct LXSyncMusicInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var singer: String
    var source: String
    var interval: String?
    var meta: LXSyncMusicMeta

    init(track: Track) {
        let normalized = track.normalizedForLXPlayback()
        let source = normalized.source ?? "wy"
        let metadata = normalized.sourceMetadata
        let songID = metadata["songmid"]
            ?? metadata["songId"]
            ?? metadata["copyrightId"]
            ?? metadata["hash"]
            ?? String(normalized.id)
        id = metadata["lxMusicInfoID"] ?? Self.listMusicID(source: source, songID: songID, metadata: metadata)
        name = normalized.name
        singer = normalized.artistNames
        self.source = source
        interval = Self.formatDuration(normalized.durationMS)
        var wireMeta = LXSyncMusicMeta(
            songId: songID,
            albumName: normalized.album.name,
            picUrl: normalized.album.picUrl,
            albumId: metadata["albumId"],
            strMediaMid: metadata["strMediaMid"],
            albumMid: metadata["albumMid"],
            hash: metadata["hash"],
            copyrightId: metadata["copyrightId"],
            lrcUrl: metadata["lrcUrl"],
            mrcUrl: metadata["mrcUrl"],
            trcUrl: metadata["trcUrl"]
        )
        wireMeta.qualitys = Self.decodeJSON([LXSyncQuality].self, from: metadata["lxSyncQualitys"])
        wireMeta._qualitys = Self.decodeJSON(
            [String: LXSyncQualityMapValue].self,
            from: metadata["lxSyncQualityIndex"]
        )
        meta = wireMeta
    }

    var track: Track {
        let numericID = Int(meta.id ?? meta.songId) ?? Int(id) ?? 0
        let albumID = Int(meta.albumId ?? "") ?? 0
        let duration = Self.parseDuration(interval)
        var metadata: [String: String] = [
            "songmid": meta.songId,
            "source": source,
            "lxMusicInfoID": id,
        ]
        if let value = meta.strMediaMid { metadata["strMediaMid"] = value }
        if let value = meta.albumMid { metadata["albumMid"] = value }
        if let value = meta.hash { metadata["hash"] = value }
        if let value = meta.copyrightId { metadata["copyrightId"] = value }
        if let value = meta.lrcUrl { metadata["lrcUrl"] = value }
        if let value = meta.mrcUrl { metadata["mrcUrl"] = value }
        if let value = meta.trcUrl { metadata["trcUrl"] = value }
        if let qualitys = meta.qualitys, let value = Self.encodeJSON(qualitys) {
            metadata["lxSyncQualitys"] = value
        }
        if let qualityIndex = meta._qualitys, let value = Self.encodeJSON(qualityIndex) {
            metadata["lxSyncQualityIndex"] = value
        }
        return Track(
            id: numericID,
            name: name,
            artists: singer.split(separator: "/").map {
                ArtistRef(id: 0, name: $0.trimmingCharacters(in: .whitespaces))
            },
            album: AlbumRef(id: albumID, name: meta.albumName, picUrl: meta.picUrl),
            durationMS: duration,
            source: source,
            sourceMetadata: metadata
        )
    }

    private static func decodeJSON<Value: Decodable>(_ type: Value.Type, from value: String?) -> Value? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encodeJSON<Value: Encodable>(_ value: Value) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, singer, source, interval, meta
    }

    private static func formatDuration(_ milliseconds: Int) -> String? {
        guard milliseconds > 0 else { return nil }
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// LX Mobile uses source-qualified IDs for list deduplication, with a
    /// source-specific hash suffix for Kugou tracks.
    private static func listMusicID(source: String, songID: String, metadata: [String: String]) -> String {
        if source == "kg", let hash = metadata["hash"], !hash.isEmpty {
            return "\(songID)_\(hash)"
        }
        return "\(source)_\(songID)"
    }

    private static func parseDuration(_ value: String?) -> Int {
        guard let value else { return 0 }
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard !components.isEmpty else { return 0 }
        let seconds = components.suffix(2).reduce(0) { $0 * 60 + $1 }
        return seconds * 1_000
    }
}

struct LXSyncMusicMeta: Codable, Equatable {
    var songId: String
    var albumName: String
    var picUrl: String?
    var qualitys: [LXSyncQuality]?
    var _qualitys: [String: LXSyncQualityMapValue]?
    var albumId: String?
    var strMediaMid: String?
    var id: String?
    var albumMid: String?
    var hash: String?
    var copyrightId: String?
    var lrcUrl: String?
    var mrcUrl: String?
    var trcUrl: String?

    init(
        songId: String,
        albumName: String,
        picUrl: String? = nil,
        albumId: String? = nil,
        strMediaMid: String? = nil,
        albumMid: String? = nil,
        hash: String? = nil,
        copyrightId: String? = nil,
        lrcUrl: String? = nil,
        mrcUrl: String? = nil,
        trcUrl: String? = nil
    ) {
        self.songId = songId
        self.albumName = albumName
        self.picUrl = picUrl
        self.qualitys = nil
        self._qualitys = nil
        self.albumId = albumId
        self.strMediaMid = strMediaMid
        self.id = nil
        self.albumMid = albumMid
        self.hash = hash
        self.copyrightId = copyrightId
        self.lrcUrl = lrcUrl
        self.mrcUrl = mrcUrl
        self.trcUrl = trcUrl
    }

    private enum CodingKeys: String, CodingKey {
        case songId, albumName, picUrl, qualitys, _qualitys, albumId
        case strMediaMid, id, albumMid, hash, copyrightId, lrcUrl, mrcUrl, trcUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songId = Self.stringValue(container, key: .songId) ?? ""
        albumName = Self.stringValue(container, key: .albumName) ?? ""
        picUrl = Self.stringValue(container, key: .picUrl)
        qualitys = try? container.decode([LXSyncQuality].self, forKey: .qualitys)
        _qualitys = try? container.decode([String: LXSyncQualityMapValue].self, forKey: ._qualitys)
        albumId = Self.stringValue(container, key: .albumId)
        strMediaMid = Self.stringValue(container, key: .strMediaMid)
        id = Self.stringValue(container, key: .id)
        albumMid = Self.stringValue(container, key: .albumMid)
        hash = Self.stringValue(container, key: .hash)
        copyrightId = Self.stringValue(container, key: .copyrightId)
        lrcUrl = Self.stringValue(container, key: .lrcUrl)
        mrcUrl = Self.stringValue(container, key: .mrcUrl)
        trcUrl = Self.stringValue(container, key: .trcUrl)
    }

    private static func stringValue(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

struct LXSyncQuality: Codable, Equatable {
    var type: String
    var size: String?
    var hash: String?
}

/// LX's `_qualitys` index is keyed by quality, so each value contains only
/// `size` (and `hash` for Kugou). The parallel `qualitys` array uses the
/// separate `LXSyncQuality` shape with its required `type` field.
struct LXSyncQualityMapValue: Codable, Equatable {
    var size: String?
    var hash: String?

    private enum CodingKeys: String, CodingKey {
        case size, hash
    }

    init(size: String? = nil, hash: String? = nil) {
        self.size = size
        self.hash = hash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(String.self, forKey: .size)
        hash = try container.decodeIfPresent(String.self, forKey: .hash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let size {
            try container.encode(size, forKey: .size)
        } else {
            try container.encodeNil(forKey: .size)
        }
        try container.encodeIfPresent(hash, forKey: .hash)
    }
}

extension LXSyncListData {
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        // CodingKeys are declared in the LX wire-model order so this stays
        // compatible with the server's MD5(JSON.stringify(listData)) check.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
