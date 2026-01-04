-- hyvlib/sophon v0.1.0
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

type GameInfo = {
    game_id: string,
    game_biz: string,
    package_id: string,
    branch: string,
    password: string
}

type RawSophonInfo = {
    tag: string,
    build_id: string,
    manifests: { RawSophonManifestInfo }
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

----------------------------------------
-- Constants

local temp_folder: string = path.join(path.temp_dir(), "hyvlib")

local sophon_manifests_folder: string       = path.join(temp_folder, "manifests")
local sophon_manifests_cache_folder: string = path.join(temp_folder, "manifests_cache")
local sophon_chunks_folder: string          = path.join(temp_folder, "chunks")

local sophon_manifest_protobuf: string = path.join(temp_folder, "manifest.proto")

local downloader_handle: number = downloader.create()
local downloader_update_interval: number = 150

----------------------------------------
-- Utility

local function calc_file_md5(path: string): Promise<string>
    local file_hash = hash.digitize_file("md5", path)

    return task.create(function()
        local status, result = file_hash:poll()

        if not status then
            return false, nil
        else
            return true, str.encode("hex", result)
        end
    end)
end

local function decompress_file(path: string): Promise<any>
    local input_file = fs.open(path, { read = true })

    local output_file = fs.open(`{path}.decompressed`, {
        write = true,
        create = true,
        overwrite = true
    })

    local decompressor = compression.decompressor("zstd")

    local branch: "read" | "decompress" | "finished" = "read"

    return task.create(function(): (boolean | nil, any)
        -- If we're still reading the file.
        if branch == "read" then
            -- Read chunk of the file.
            local chunk = fs.read(input_file)

            -- If chunk is empty - we've finished reading the file, so change
            -- the branch.
            if not chunk then
                -- Flush all the data left in RAM buffer to the decompressor.
                compression.finish(decompressor)

                branch = "decompress"

            -- Otherwise write read file chunk to the decompressor.
            else
                compression.write(decompressor, chunk)

                -- Disabled because otherwise causes weird errors when not
                -- enough data is written to the decoder just yet.
                --
                -- -- Try to read decompressed data. We're doing it here so that
                -- -- the decompressed data is not stored in RAM until the whole
                -- -- file is finished reading.
                -- chunk = compression.read(decompressor)

                -- -- If it's not empty - write it to the output file.
                -- if chunk then
                --     fs.write(output_file, chunk)
                -- end
            end

            return false, nil

        -- If we're decompressing the file.
        elseif branch == "decompress" then
            -- Read chunk of decompressed data.
            local chunk = compression.read(decompressor)

            -- If no data left in the decompressor - finish the promise.
            if not chunk then
                compression.close(decompressor)

                fs.close(input_file)
                fs.close(output_file)

                fs.remove_file(path):await()
                fs.move(`{path}.decompressed`, path):await()

                branch = "finished"

            -- Otherwise write read chunk to the output file.
            else
                fs.write(output_file, chunk)
            end

            return false, nil

        -- If we've finished decompressing the file - return from promise.
        elseif branch == "finished" then
            return true, true

        -- Should be unreachable.
        else
            error("FIXME: unreachable sophon decompress_file branch")
        end
    end)
end

----------------------------------------
-- Chunk downloading

-- Download sophon chunk and return path to it.
local function download_sophon_chunk(
    chunk: SophonDownloadChunkInfo,
    platform: Platform,
    updater: (current: number, total: number) -> ()
): Promise<string>
    local chunk_path: string = path.join(sophon_chunks_folder, chunk.name)

    type State =
        | { branch: "none" }
        | { branch: "check_chunk_hash", promise: Promise<string>, redownload: boolean }
        | { branch: "download_chunk", handle: number }
        | { branch: "decompress_chunk", promise: Promise<any> }

    local state: State = { branch = "none" }

    return task.create(function(): (boolean | nil, string | nil)
        -- If we didn't do anything yet.
        if state.branch == "none" then
            -- If chunk is already downloaded then check its hash.
            if fs.exists(chunk_path) then
                state = {
                    branch = "check_chunk_hash",
                    promise = calc_file_md5(chunk_path),
                    redownload = true -- allow chunk redownloading
                }

            -- Otherwise start downloading it.
            else
                state = {
                    branch = "download_chunk",
                    handle = downloader.download(downloader_handle, {
                        url = chunk.download_url,
                        output_file = chunk_path,
                        continue_download = false
                    })
                }
            end

            return false, nil

        -- If we're checking the chunk hash.
        elseif state.branch == "check_chunk_hash" then
            local status, hash = state.promise:poll()

            -- If we've finished calculating the chunk hash.
            if status == true then
                -- If hash matched - return path to the downloaded chunk.
                if hash == chunk.md5_checksum then
                    return true, chunk_path

                -- Otherwise if downloaded chunk's hash mismatched.
                else
                    -- Delete the wrong file to not to compare its hash if the
                    -- function will be stopped and restarted.
                    fs.remove_file(chunk_path):await()

                    -- If chunk redownloading is forbidden then throw an error.
                    if not state.redownload then
                        error(`downloaded sophon chunk has invalid hash: '{chunk.md5_checksum}' expected, got '{hash}'; download url: '{chunk.download_url}'`)
                    end

                    state = {
                        branch = "download_chunk",
                        handle = downloader.download(downloader_handle, {
                            url = chunk.download_url,
                            output_file = chunk_path,
                            continue_download = false
                        })
                    }
                end
            end

            return false, nil

        -- If we're downloading the chunk.
        elseif state.branch == "download_chunk" then
            local progress = downloader.progress(state.handle) :: { current: number, total: number, finished: boolean }

            updater(progress.current, progress.total)

            -- If downloading finished then check downloaded chunk hash.
            if progress.finished then
                -- Wait for downloading finish even though the progress
                -- reports that it's already finished. Some data might not be
                -- written to disk still.
                downloader.wait(state.handle)

                -- Decompress the chunk.
                state = {
                    branch = "decompress_chunk",
                    promise = decompress_file(chunk_path)
                }
            end

            -- Sleep for a short duration of time between downloader updates.
            sleep(downloader_update_interval)

            return false, nil

        -- If we're decompressing the chunk.
        elseif state.branch == "decompress_chunk" then
            -- If we've finished decompressing the chunk - then check its hash.
            if state.promise:poll() == true then
                state = {
                    branch = "check_chunk_hash",
                    promise = calc_file_md5(chunk_path),
                    redownload = false -- do not allow redownloading the chunk
                }
            end

            return false, nil

        -- Should be unreachable.
        else
            error("FIXME: unreachable download_sophon_chunk branch")
        end
    end)
end

----------------------------------------
-- Manifest downloading and decoding

local function parse_sophon_protobuf_manifest(manifest: string): { SophonAsset }
    local function get_default_sophon_asset(): SophonAsset
        return {
            name = "",
            size = 0,
            md5_checksum = "",
            chunks = {}
        }
    end

    local function get_default_sophon_chunk(): SophonChunk
        return {
            name = "",
            offset = 0,
            compressed = {
                size = 0,
                md5_checksum = ""
            },
            uncompressed = {
                size = 0,
                md5_checksum = ""
            }
        }
    end

    local assets: { SophonAsset } = {}

    local asset: SophonAsset = get_default_sophon_asset()
    local chunk: SophonChunk = get_default_sophon_chunk()

    for _, line in manifest:split("\n") do
        if line == "}" then
            table.insert(assets, asset :: SophonAsset)

            asset = get_default_sophon_asset()
            chunk = get_default_sophon_chunk()
        elseif line:sub(0, 6) == "  name" then
            asset.name = line:sub(10, -2)
        elseif line:sub(0, 6) == "  size" then
            asset.size = tonumber(line:sub(9)) :: number
        elseif line:sub(0, 14) == "  md5_checksum" then
            asset.md5_checksum = line:sub(18, -2)
        elseif line:sub(0, 8) == "    name" then
            chunk.name = line:sub(12, -2)
        elseif line:sub(0, 15) == "    file_offset" then
            chunk.offset = tonumber(line:sub(17)) :: number
        elseif line:sub(0, 19) == "    compressed_size" then
            chunk.compressed.size = tonumber(line:sub(22)) :: number
        elseif line:sub(0, 27) == "    compressed_md5_checksum" then
            chunk.compressed.md5_checksum = line:sub(31, -2)
        elseif line:sub(0, 29) == "    uncompressed_md5_checksum" then
            chunk.uncompressed.md5_checksum = line:sub(33, -2)
        elseif line:sub(0, 21) == "    uncompressed_size" then
            chunk.uncompressed.size = tonumber(line:sub(24)) :: number
        elseif line:sub(0, 3) == "  }" then
            if not asset.chunks then
                asset.chunks = { chunk }
            else
                table.insert(asset.chunks, chunk)
            end

            chunk = get_default_sophon_chunk()
        end
    end

    return assets
end

local __protobuf_installed = false
local __sophon_manifest_protobuf_copied = false

local function decode_sophon_protobuf_manifest(path: string, platform: Platform): Promise<{ SophonAsset }>
    local protobuf, sophon_manifest_protobuf_src = import("protobuf", "sophon-manifest-protobuf")

    -- Fake promise (at least for now)
    return task.create(function()
        if not __protobuf_installed then
            __protobuf_installed = true

            if not protobuf.is_installed(platform) then
                protobuf.install(platform)
            end
        end

        if not __sophon_manifest_protobuf_copied then
            __sophon_manifest_protobuf_copied = true

            if fs.exists(sophon_manifest_protobuf) then
                fs.remove(sophon_manifest_protobuf):await()
            end

            fs.copy(sophon_manifest_protobuf_src, sophon_manifest_protobuf):await()
        end

        local manifest = protobuf.decode(platform, {
            protobuf = sophon_manifest_protobuf,
            type = "sophon.Manifest",
            input = path
        })

        return true, parse_sophon_protobuf_manifest(manifest)
    end)
end

-- Download sophon protobuf manifest to a temporary folder and return its
-- decoded content.
local function download_sophon_manifest(
    manifest: SophonDownloadManifestInfo,
    platform: Platform,
    updater: (current: number, total: number) -> ()
): Promise<{ SophonAsset }>
    local protobuf_manifest_path: string = path.join(sophon_manifests_folder, manifest.id)
    local decoded_manifest_cache_path: string = path.join(sophon_manifests_cache_folder, manifest.md5_checksum)

    type State =
        | { branch: "none" }
        | { branch: "read_protobuf_manifest_cache", promise: Promise<Bytes> }
        | { branch: "check_protobuf_manifest_hash", promise: Promise<string>, redownload: boolean }
        | { branch: "decode_protobuf_manifest", promise: Promise<{ SophonAsset }> }
        | { branch: "write_protobuf_manifest_cache", promise: Promise<any>, manifest: { SophonAsset } }
        | { branch: "download_protobuf_manifest", handle: number }
        | { branch: "decompress_protobuf_manifest", promise: Promise<any> }

    local state: State = { branch = "none" }

    return task.create(function(): (boolean | nil, any)
        -- If we didn't do anything yet
        if state.branch == "none" then
            -- If decoded manifest file cache exists - try to read it.
            if fs.exists(decoded_manifest_cache_path) then
                state = {
                    branch = "read_protobuf_manifest_cache",
                    promise = fs.read_file(decoded_manifest_cache_path)
                }

            -- If we don't have cache file but the protobuf manifest file is
            -- downloaded then check its hash.
            elseif fs.exists(protobuf_manifest_path) then
                state = {
                    branch = "check_protobuf_manifest_hash",
                    promise = calc_file_md5(protobuf_manifest_path),
                    redownload = true -- allow to redownload the manifest
                }

            -- Otherwise if neither cache nor the manifest itself are vailable
            -- we need to start downloading the manifest file.
            else
                state = {
                    branch = "download_protobuf_manifest",
                    handle = downloader.download(downloader_handle, {
                        url = manifest.download_url,
                        output_file = protobuf_manifest_path,
                        continue_download = false
                    })
                }
            end

            return false, nil

        -- Read the manifest cache file and return it.
        elseif state.branch == "read_protobuf_manifest_cache" then
            local status, value = state.promise:poll()

            -- If we've finished reading cache file - return its content.
            if status == true then
                return true, str.decode("bson", value:as_string()).assets
            end

            return false, nil

        -- If we're calculating the downloaded protobuf manifest hash - poll
        -- its promise.
        elseif state.branch == "check_protobuf_manifest_hash" then
            local status, hash = state.promise:poll()

            -- If calculation finished - compare it against expected hash.
            if status == true then
                -- If hash matched - then try to read the decoded manifest
                -- cache.
                if hash == manifest.md5_checksum then
                    state = {
                        branch = "decode_protobuf_manifest",
                        promise = decode_sophon_protobuf_manifest(protobuf_manifest_path, platform)
                    }

                -- Otherwise redownload the manifest file.
                else
                    -- Delete the wrong file to not to compare its hash
                    -- if the function will be stopped and restarted.
                    fs.remove_file(protobuf_manifest_path):await()

                    -- If manifest redownloading is forbidden then throw an
                    -- error.
                    if not state.redownload then
                        error(`downloaded sophon protobuf manifest has invalid hash: '{manifest.md5_checksum}' expected, got '{hash}'; download url: '{manifest.download_url}'`)
                    end

                    state = {
                        branch = "download_protobuf_manifest",
                        handle = downloader.download(downloader_handle, {
                            url = manifest.download_url,
                            output_file = protobuf_manifest_path,
                            continue_download = false
                        })
                    }
                end
            end

            return false, nil

        -- If we're decoding the downloaded protobuf manifest - try to poll
        -- decoding result.
        elseif state.branch == "decode_protobuf_manifest" then
            local status, assets = state.promise:poll()

            -- If decoding finished - write decoded manifest to the cache file.
            if status == true then
                state = {
                    branch = "write_protobuf_manifest_cache",
                    promise = fs.write_file(
                        decoded_manifest_cache_path,
                        str.encode("bson", { assets = assets })
                    ),
                    manifest = assets
                }
            end

            return false, nil

        -- If we're writing the decoded protobuf manifest cache - poll writing
        -- status.
        elseif state.branch == "write_protobuf_manifest_cache" then
            -- If we've finished writing the cache file - return decoded
            -- manifest.
            if state.promise:poll() == true then
                return true, state.manifest
            else
                return false, nil
            end

        -- If we're downloading protobuf manifest file.
        elseif state.branch == "download_protobuf_manifest" then
            local progress = downloader.progress(state.handle) :: { current: number, total: number, finished: boolean }

            updater(progress.current, progress.total)

            -- If downloading finished then check downloaded manifest hash.
            if progress.finished then
                -- Wait for downloading finish even though the progress
                -- reports that it's already finished. Some data might not be
                -- written to disk still.
                downloader.wait(state.handle)

                -- If protobuf manifest file is compressed then decompress it.
                if manifest.compressed then
                    state = {
                        branch = "decompress_protobuf_manifest",
                        promise = decompress_file(protobuf_manifest_path)
                    }

                -- Otherwise start checking its hash.
                else
                    state = {
                        branch = "check_protobuf_manifest_hash",
                        promise = calc_file_md5(protobuf_manifest_path),
                        redownload = false -- do not allow redownloading the manifest
                    }
                end
            end

            -- Sleep for a short duration of time between downloader updates.
            sleep(downloader_update_interval)

            return false, nil

        -- If we're decompressing downloaded protobuf manifest file.
        elseif state.branch == "decompress_protobuf_manifest" then
            -- If we've finished decompressing the protobuf manifest file - then
            -- check its hash.
            if state.promise:poll() == true then
                state = {
                    branch = "check_protobuf_manifest_hash",
                    promise = calc_file_md5(protobuf_manifest_path),
                    redownload = false -- do not allow redownloading the manifest
                }
            end

            return false, nil

        -- Should be unreachable.
        else
            error("FIXME: unreachable download_sophon_manifest branch")
        end
    end)
end

----------------------------------------
-- API fetching

local __sophon_api_cache: { [string]: SophonInfo } = {}

local function fetch_sophon_api(
    api_url: string,
    game_info: GameInfo,
    edition: Edition
): Promise<SophonInfo>
    local index = `{edition}-{game_info.game_id}`

    if __sophon_api_cache[index] then
        return task.create(clone(__sophon_api_cache[index]))
    end

    local request = http.fetch(`{api_url}/downloader/sophon_chunk/api/getBuild?branch={game_info.branch}&package_id={game_info.package_id}&password={game_info.password}`)

    return task.create(function()
        local status, response = request:poll()

        if not status then
            return false, nil
        end

        if not response.is_ok then
            error(`failed to fetch sophon API for game '{game_info.game_biz}'`)
        end

        response = str.decode("json", str.from_bytes(response.body))

        local iter, semver = import("iterable", "semver")

        local manifests = iter(response.data.manifests)
            .map(function(sophon_info: RawSophonManifestInfo): SophonManifestInfo
                local manifest_download_url = `{sophon_info.manifest_download.url_prefix}/{sophon_info.manifest.id}`
                local chunks_download_url = sophon_info.chunk_download.url_prefix

                if #sophon_info.manifest_download.url_suffix > 0 then
                    manifest_download_url = `{manifest_download_url}?{sophon_info.manifest_download.url_suffix}`
                end

                return {
                    category_id = sophon_info.category_id,
                    category_name = sophon_info.category_name,
                    matching_field = sophon_info.matching_field,
                    manifest = {
                        id = sophon_info.manifest.id,
                        compressed_size = sophon_info.manifest.compressed_size,
                        uncompressed_size = sophon_info.manifest.uncompressed_size,
                        md5_checksum = sophon_info.manifest.checksum,
                        download_url = manifest_download_url,
                        compressed = sophon_info.manifest_download.compression,

                        download = function(platform: Platform, updater: (current: number, total: number) -> ()): Promise<{ SophonAsset }>
                            local manifest = {
                                id = sophon_info.manifest.id,
                                md5_checksum = sophon_info.manifest.checksum,
                                download_url = manifest_download_url,
                                compressed = sophon_info.manifest_download.compression
                            }

                            return download_sophon_manifest(manifest, platform, updater)
                        end
                    },
                    chunks = {
                        compressed_size = sophon_info.stats.compressed_size,
                        uncompressed_size = sophon_info.stats.uncompressed_size,
                        file_count = sophon_info.stats.file_count,
                        chunk_count = sophon_info.stats.chunk_count,
                        download_url = chunks_download_url,
                        compressed = sophon_info.chunk_download.compression
                    }
                }
            end)
            .collect()

        __sophon_api_cache[index] = {
            version = semver(response.data.tag),
            build_id = response.data.build_id,
            manifests = manifests
        }

        return true, clone(__sophon_api_cache[index])
    end)
end

return {
    download_manifest = download_sophon_manifest,
    download_chunk = download_sophon_chunk,
    fetch_api = fetch_sophon_api
}
