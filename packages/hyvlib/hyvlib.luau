-- hyvlib v0.1.0
-- Copyright (C) 2025  Nikita Podvirnyi <krypt0nn@vk.com>
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

type Semver = { major: number, minor: number, patch: number }
type Edition = "global" | "china"

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
    fetch_sophon_info: () -> SophonInfo
}

type RawSophonManifestInfo = {
    category_id: string,
    category_name: string,
    matching_field: string,
    manifest: {
        id: string,
        compressed_size: string,
        uncompressed_size: string,
        checksum: string
    },
    manifest_download: {
        url_prefix: string,
        url_suffix: string,
        compression: boolean,
        encryption: boolean,
        password: string
    },
    chunk_download: {
        url_prefix: string,
        url_suffix: string,
        compression: boolean,
        encryption: boolean,
        password: string
    },
    stats: {
        compressed_size: string,
        uncompressed_size: string,
        file_count: string,
        chunk_count: string
    },
    deduplicated_stats: {
        compressed_size: string,
        uncompressed_size: string,
        file_count: string,
        chunk_count: string
    }
}

type RawSophonInfo = {
    tag: string,
    build_id: string,
    manifests: { RawSophonManifestInfo }
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
        fetch: (updater: (current: number, total: number) -> ()) -> ()
    }
}

type SophonInfo = {
    version: Semver,
    build_id: string,
    manifests: { SophonManifestInfo }
}

type SophonAsset = {
    name: string,
    size: number,
    hash_md5: string,
    chunks: { SophonChunk }
}

type SophonChunk = {
    name: string,
    compressed_size: number,
    decompressed_size: number,
    compressed_hash_md5: string,
    decompressed_hash_md5: string
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

local current_platform: string = "x86_64-linux" -- make it an argument somewhere

local temp_folder: string = path.join(path.temp_dir(), "hyvlib")

local sophon_manifests_folder: string       = path.join(temp_folder, "manifests")
local sophon_manifests_cache_folder: string = path.join(temp_folder, "manifests_cache")
local sophon_chunks_folder: string          = path.join(temp_folder, "chunks")

local sophon_manifest_protobuf: string = path.join(temp_folder, "manifest.proto")

local __games_api_cache: {  [Edition]: { GameInfo } } = {}
local __sophon_api_cache: { [string]: SophonInfo } = {}

local __protobuf_installed = false
local __sophon_manifest_protobuf_copied = false

local downloader_handle = downloader.create()

----------------------------------------
-- Util functions

local function calc_file_md5(path: string): string
    return str.encode(hash.digitize_file("md5", path), "hex")
end

----------------------------------------
-- Sophon

local function parse_sophon_manifest(manifest: string): { SophonAsset }
    local assets: { SophonAsset } = {}
    local asset: SophonAsset = {} :: SophonAsset
    local chunk: SophonChunk = {} :: SophonChunk

    for _, line in manifest:split("\n") do
        if line == "}" then
            table.insert(assets, asset :: SophonAsset)

            asset = {} :: SophonAsset
            chunk = {} :: SophonChunk
        elseif line:sub(0, 6) == "  name" then
            asset.name = line:sub(10, -2)
        elseif line:sub(0, 6) == "  size" then
            asset.size = tonumber(line:sub(9)) :: number
        elseif line:sub(0, 10) == "  hash_md5" then
            asset.hash_md5 = line:sub(14, -2)
        elseif line:sub(0, 8) == "    name" then
            chunk.name = line:sub(12, -2)
        elseif line:sub(0, 23) == "    compressed_hash_md5" then
            chunk.compressed_hash_md5 = line:sub(27, -2)
        elseif line:sub(0, 25) == "    decompressed_hash_md5" then
            chunk.decompressed_hash_md5 = line:sub(29, -2)
        elseif line:sub(0, 19) == "    compressed_size" then
            chunk.compressed_size = tonumber(line:sub(22)) :: number
        elseif line:sub(0, 21) == "    decompressed_size" then
            chunk.decompressed_size = tonumber(line:sub(24)) :: number
        elseif line:sub(0, 3) == "  }" then
            if not asset.chunks then
                asset.chunks = { chunk }
            else
                table.insert(asset.chunks, chunk)
            end

            chunk = {} :: SophonChunk
        end
    end

    return assets :: { SophonAsset }
end

local function decode_sophon_manifest(path: string): { SophonAsset }
    local protobuf, sophon_manifest_protobuf_src = import("protobuf", "sophon-manifest-protobuf")

    if not __protobuf_installed then
        __protobuf_installed = true

        protobuf.install(current_platform)
    end

    if not __sophon_manifest_protobuf_copied then
        __sophon_manifest_protobuf_copied = true

        if fs.exists(sophon_manifest_protobuf) then
            fs.remove(sophon_manifest_protobuf)
        end

        fs.copy(sophon_manifest_protobuf_src, sophon_manifest_protobuf)
    end

    local manifest = protobuf.decode(current_platform, {
        protobuf = sophon_manifest_protobuf,
        type = "sophon.Manifest",
        input = path
    })

    return parse_sophon_manifest(manifest)
end

----------------------------------------
-- Fetch sophon API

local function fetch_sophon_api(edition: Edition, raw_game_info: RawGameInfo): SophonInfo
    local index = `{edition}-{raw_game_info.game.id}`

    if __sophon_api_cache[index] then
        return __sophon_api_cache[index]
    end

    local iter, semver = import("iterable", "semver")

    local response = net.fetch(`{api_info[edition].sophon_api_url}/downloader/sophon_chunk/api/getBuild?branch={raw_game_info.main.branch}&package_id={raw_game_info.main.package_id}&password={raw_game_info.main.password}`)

    if not response.is_ok then
        error(`failed to fetch sophon API for game '{raw_game_info.game.biz}'`)
    end

    response = str.decode(str.from_bytes(response.body), "json")

    local manifests = iter(response.data.manifests)
        .map(function(sophon_info: RawSophonManifestInfo): SophonManifestInfo
            return {
                category_id = sophon_info.category_id,
                category_name = sophon_info.category_name,
                matching_field = sophon_info.matching_field,

                manifest = {
                    id = sophon_info.manifest.id,
                    compressed_size = sophon_info.manifest.compressed_size,
                    uncompressed_size = sophon_info.manifest.uncompressed_size,
                    md5_checksum = sophon_info.manifest.checksum,

                    fetch = function(updater: (current: number, total: number) -> ())
                        local manifest_path: string = path.join(sophon_manifests_folder, sophon_info.manifest.id)
                        local cache_path: string = path.join(sophon_manifests_cache_folder, sophon_info.manifest.checksum)

                        if fs.exists(manifest_path) and calc_file_md5(manifest_path) == sophon_info.manifest.checksum then
                            if fs.exists(cache_path) then
                                local manifest = fs.read_file(cache_path)

                                return str.decode(str.from_bytes(manifest), "json")
                            end

                            local manifest = decode_sophon_manifest(manifest_path)

                            fs.write_file(cache_path, str.encode(manifest, "json"))

                            return manifest
                        end

                        local url = `{sophon_info.manifest_download.url_prefix}{sophon_info.manifest_download.url_suffix}/{sophon_info.manifest.id}`

                        local task = downloader.download(downloader_handle, {
                            url = url,
                            output_file = manifest_path,
                            continue_download = false,
                            on_update = function(current, total)
                                if updater then
                                    updater(current, total)
                                end
                            end
                        })

                        downloader.wait(task)

                        if sophon_info.manifest_download.compression then
                            local manifest_content = fs.read_file(manifest_path)

                            manifest_content = compression.decompress("zstd", manifest_content)

                            fs.write_file(manifest_path, manifest_content)
                        end

                        if calc_file_md5(manifest_path) ~= sophon_info.manifest.checksum then
                            error(`downloaded manifest '{url}' to '{manifest_path}' has invalid hash`)
                        end

                        local manifest = decode_sophon_manifest(manifest_path)

                        fs.write_file(cache_path, str.encode(manifest, "json"))

                        return manifest
                    end
                }
            }
        end)
        .collect()

    __sophon_api_cache[index] = {
        version = semver(response.data.tag),
        build_id = response.data.build_id,
        manifests = manifests
    }

    return __sophon_api_cache[index]
end

----------------------------------------
-- Fetch games API

local function fetch_games_api(edition: Edition): { GameInfo }
    if __games_api_cache[edition] then
        return __games_api_cache[edition]
    end

    local iter, semver = import("iterable", "semver")

    local response = net.fetch(`{api_info[edition].games_api_url}/hyp/hyp-connect/api/getGameBranches?launcher_id={api_info[edition].launcher_id}`)

    if not response.is_ok then
        error("failed to fetch games API")
    end

    response = str.decode(str.from_bytes(response.body), "json")

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
                    return fetch_sophon_api(edition, game_info)
                end
            }
        end)
        .collect()

    return __games_api_cache[edition]
end

return {
    fetch_games_api = fetch_games_api
}
