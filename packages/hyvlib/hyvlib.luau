-- hyvlib v0.1.0
-- Copyright (C) 2025 - 2026  Nikita Podvirnyi <krypt0nn@vk.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

function import(...)
    return (load("import").value)(...)
end

----------------------------------------
-- Types

type Promise<T> = {
    poll: (Promise<T>) -> (boolean | nil, T),
    await: (Promise<T>) -> T
}

type Bytes = {
    as_table: (Bytes) -> { number },
    as_string: (Bytes) -> string
}

type Semver = { major: number, minor: number, patch: number }

type Edition = "global" | "china"
type Platform = "x86_64-linux"

type RawGameInfo = {
    game: {
        id: string,
        biz: string
    },
    main: {
        package_id: string,
        branch: string,
        password: string,
        tag: string,
        diff_tags: { string }
    }
}

type GameInfo = {
    game_id: string,
    game_biz: string,
    package_id: string,
    branch: string,
    password: string,
    version: Semver,
    diff_versions: { Semver },
    fetch_sophon_info: () -> Promise<SophonInfo>
}

type SophonInfo = {
    version: Semver,
    build_id: string,
    manifests: { SophonManifestInfo }
}

type SophonManifestInfo = {
    category_id: string,
    category_name: string,
    matching_field: string,
    manifest: {
        id: string,
        compressed_size: string,
        uncompressed_size: string,
        md5_checksum: string,
        download_url: string,
        compressed: boolean,
        download: (platform: Platform, updater: (current: number, total: number) -> ()) -> Promise<{ SophonAsset }>
    },
    chunks: {
        compressed_size: string,
        uncompressed_size: string,
        file_count: string,
        chunk_count: string,
        download_url: string,
        compressed: boolean
    }
}

type SophonAsset = {
    name: string,
    size: number,
    md5_checksum: string,
    chunks: { SophonChunk }
}

type SophonChunk = {
    name: string,
    offset: number,
    compressed: {
        size: number,
        md5_checksum: string
    },
    uncompressed: {
        size: number,
        md5_checksum: string
    }
}

type SophonDownloadManifestInfo = {
    id: string,
    md5_checksum: string, -- uncompressed protobuf manifest file md5 hash
    download_url: string, -- full URL to download the protobuf manifest
    compressed: boolean
}

type SophonDownloadChunkInfo = {
    name: string,
    md5_checksum: string, -- uncompressed chunk file md5 hash
    download_url: string -- full URL to download the chunk
}

type SophonDownloadAssetInfo = {
    name: string,
    md5_checksum: string, -- complete asset md5 hash
    chunks: {{
        chunk: SophonDownloadChunkInfo, -- chunk download info
        offset: number -- chunk's offset within the asset
    }}
}

----------------------------------------
-- Constants

local api_info = {
    global = {
        games_api_url = "https://sg-hyp-api.hoyoverse.com",
        sophon_api_url = "https://sg-public-api.hoyoverse.com",
        launcher_id = "VYTpXlbWo8"
    },

    china = {
        games_api_url = "https://hyp-api.mihoyo.com",
        sophon_api_url = "https://api-takumi.mihoyo.com",
        launcher_id = "jGHBHlcOq1"
    }
}

----------------------------------------
-- Fetch games API

local __games_api_cache: {  [Edition]: { GameInfo } } = {}

local function fetch_games_api(edition: Edition): Promise<{ GameInfo }>
    if __games_api_cache[edition] then
        return task.create(clone(__games_api_cache[edition]))
    end

    local request = http.fetch(`{api_info[edition].games_api_url}/hyp/hyp-connect/api/getGameBranches?launcher_id={api_info[edition].launcher_id}`)

    return task.create(function()
        local status, response = request:poll()

        if not status then
            return false, nil
        end

        if not response.is_ok then
            error("failed to fetch games API")
        end

        response = str.decode("json", str.from_bytes(response.body))

        local iter, semver, sophon = import("iterable", "semver", "sophon")

        __games_api_cache[edition] = iter(response.data.game_branches)
            .map(function(game_info: RawGameInfo): GameInfo
                return {
                    game_id = game_info.game.id,
                    game_biz = game_info.game.biz,
                    package_id = game_info.main.package_id,
                    branch = game_info.main.branch,
                    password = game_info.main.password,
                    version = semver(game_info.main.tag),

                    diff_versions = iter(game_info.main.diff_tags)
                        .map(semver)
                        .collect(),

                    fetch_sophon_info = function()
                        local game_info = {
                            game_id = game_info.game.id,
                            game_biz = game_info.game.biz,
                            package_id = game_info.main.package_id,
                            branch = game_info.main.branch,
                            password = game_info.main.password
                        }

                        return sophon.fetch_api(
                            api_info[edition].sophon_api_url,
                            game_info,
                            edition
                        )
                    end
                }
            end)
            .collect()

        return true, clone(__games_api_cache[edition])
    end)
end

return function()
    local iter, sophon = import("iterable", "sophon")

    local game_info = fetch_games_api("global"):await()[1]
    local sophon_info = game_info.fetch_sophon_info():await()
    local manifest_info = sophon_info.manifests[2]

    dbg(manifest_info)

    local download_manifest = {
        id = manifest_info.manifest.id,
        md5_checksum = manifest_info.manifest.md5_checksum,
        download_url = manifest_info.manifest.download_url,
        compressed = manifest_info.manifest.compressed
    }

    local assets = sophon.download_manifest(
        download_manifest,
        "x86_64-linux",
        function(current: number, total: number)
            print(`Progress: {current / 1024} KiB / {total / 1024} KiB`)
        end
    ):await()

    local output_folder = path.join(path.temp_dir(), "sophon_assets_output")

    for _, asset in ipairs(assets) do
        print(`processing asset '{asset.name}' ({asset.size / 1024} KiB)`)

        local download_asset: SophonDownloadAssetInfo = {
            name = asset.name,
            md5_checksum = asset.md5_checksum,
            chunks = iter(asset.chunks)
                .map(function(chunk: SophonChunk): { chunk: SophonDownloadChunkInfo, offset: number }
                    return {
                        chunk = {
                            name = chunk.name,
                            md5_checksum = chunk.uncompressed.md5_checksum,
                            download_url = `{manifest_info.chunks.download_url}/{chunk.name}`
                        },
                        offset = chunk.offset
                    }
                end)
                .collect()
        }

        sophon.patch_asset(
            output_folder,
            download_asset,
            "x86_64-linux",
            function(current: number, total: number)
                print(`Progress: {current / 1024} KiB / {total / 1024} KiB`)
            end
        ):await()
    end
end

-- return {
--     fetch_games_api = fetch_games_api
-- }
