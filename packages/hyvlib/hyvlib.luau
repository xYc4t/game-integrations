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

function import(...): ...any
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

type Region = "global" | "china"
type Game = "genshin" | "hsr" | "zzz"
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
        diff_tags: { string },
        categories: {{
            category_id: string,
            matching_field: string
        }}
    }
}

type GameInfo = {
    -- Latest available game version.
    version: Semver,

    -- List of versions from which it's possible to update the game.
    diffs: { Semver },

    -- Fetch list of required and optional game components.
    fetch_components: () -> Promise<{ GameComponentInfo }>
}

type GameComponentInfo = {
    -- Name of the game component.
    name: string,

    -- Download the game component to the provided base game folder.
    download: (
        game_folder: string,
        platform: Platform,
        updater: (current: number, total: number) -> (),
        max_parallel_assets: number | nil
    ) -> Promise<nil>
}

type SophonFetchApiInfo = {
    game_id: string,
    game_biz: string,
    package_id: string,
    branch: string,
    password: string
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
        compressed: boolean
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

type ApiInfo = {
    [Region]: {
        games_api_url: string,
        sophon_api_url: string,
        launcher_id: string,
        games: {
            [Game]: {
                biz: string,
                id: string
            }
        }
    }
}

local api_info: ApiInfo = {
    global = {
        games_api_url = "https://sg-hyp-api.hoyoverse.com",
        sophon_api_url = "https://sg-public-api.hoyoverse.com",
        launcher_id = "VYTpXlbWo8",

        -- biz = "nap_global",
        -- id = "U5hbdsT9W7",

        -- biz = "hkrpg_global",
        -- id = "4ziysqXOQ8",

        -- biz = "hk4e_global",
        -- id = "gopR6Cufr3",

        -- biz = "bh3_global",
        -- id = "5TIVvvcwtM",

        -- biz = "bh3_global",
        -- id = "g0mMIvshDb",

        -- biz = "bh3_global",
        -- id = "uxB4MC7nzC",

        -- biz = "bh3_global",
        -- id = "bxPTXSET5t",

        -- biz = "bh3_global",
        -- id = "wkE5P5WsIf",
        games = {
            genshin = {
                biz = "hk4e_global",
                id = "gopR6Cufr3"
            },
            hsr = {
                biz = "hkrpg_global",
                id = "4ziysqXOQ8"
            },
            zzz = {
                biz = "nap_global",
                id = "U5hbdsT9W7"
            }
        }
    },

    china = {
        games_api_url = "https://hyp-api.mihoyo.com",
        sophon_api_url = "https://api-takumi.mihoyo.com",
        launcher_id = "jGHBHlcOq1",
        games = {}
    }
}

----------------------------------------
-- Fetch games API

local __games_api_cache: { [Region]: { RawGameInfo } } = {}
local __sophon_api_cache: { [string]: SophonInfo } = {}

local function fetch_games_api(region: Region): Promise<{ RawGameInfo }>
    if __games_api_cache[region] then
        return task.create(clone(__games_api_cache[region]))
    end

    local request = http.fetch(`{api_info[region].games_api_url}/hyp/hyp-connect/api/getGameBranches?launcher_id={api_info[region].launcher_id}`)

    return task.create(function()
        local status, response = request:poll()

        if not status then
            return false, nil
        end

        if not response.is_ok then
            error("failed to fetch games API")
        end

        response = str.decode("json", str.from_bytes(response.body))

        __games_api_cache[region] = response.data.game_branches

        return true, clone(__games_api_cache[region])
    end)
end

local function fetch_sophon_api(region: Region, game_info: SophonFetchApiInfo): Promise<SophonInfo>
    local index = `{region}-{game_info.game_biz}-{game_info.game_id}-{game_info.package_id}-{game_info.branch}`

    if __sophon_api_cache[index] then
        return task.create(clone(__sophon_api_cache[index]))
    end

    local sophon = import("sophon")

    local promise = sophon.fetch_api(
        api_info[region].sophon_api_url,
        game_info,
        region
    )

    return task.create(function(): (boolean, SophonInfo | nil)
        local status, result = promise:poll()

        if not status then
            return false, nil
        end

        __sophon_api_cache[index] = result

        return true, clone(__sophon_api_cache[index])
    end)
end

----------------------------------------
-- Hyvlib game related functions

-- Download a game component ("category").
local function download_game_component(
    output_folder: string,
    manifest_info: SophonManifestInfo,
    platform: Platform,
    updater: (current: number, total: number) -> (),
    max_parallel_assets: number | nil
): Promise<nil>
    local iter, sophon = import("iterable", "sophon")

    -- At least 1 asset patching required.
    local max_parallel_assets = math.max(max_parallel_assets or 1, 1)

    local download_manifest: SophonDownloadManifestInfo = {
        id = manifest_info.manifest.id,
        md5_checksum = manifest_info.manifest.md5_checksum,
        download_url = manifest_info.manifest.download_url,
        compressed = manifest_info.manifest.compressed
    }

    -- Start downloading the sophon manifest for this game component.
    local download_manifest_promise: Promise<{ SophonAsset }> | nil = sophon.download_manifest(
        download_manifest,
        platform,
        updater
    ) :: Promise<{ SophonAsset }>

    -- Queue of assets which were not patched yet.
    local patch_assets_queue: { SophonAsset } = {}

    -- List of assets which are being patched now.
    type ScheduledAssetInfo = {
        asset: SophonAsset,
        promise: Promise<nil>,
        current: number,
        total: number
    }

    local patch_assets_pool: { ScheduledAssetInfo } = {}

    -- Total size of already finished assets patching.
    local finished_assets_total_size = 0

    return task.create(function(): (boolean, nil)
        -- If we're still fetching the sophon manifest.
        if download_manifest_promise ~= nil then
            local status, result = download_manifest_promise:poll()

            -- If we didn't finish downloading yet - keep waiting.
            if not status then
                return false, nil
            end

            -- Otherwise, if we've downloaded the manifest and obtained list of
            -- game component assets - schedule their downloading and patching.
            download_manifest_promise = nil
            patch_assets_queue = result

            return false, nil

        -- If both the pool and the queue are empty then all the tasks were
        -- finished (or there were no tasks at all), so the promise should be
        -- finished.
        elseif #patch_assets_pool == 0 and #patch_assets_queue == 0 then
            return true, nil

        -- Otherwise, if we've downloaded the manifest and there are tasks to
        -- process.
        else
            -- Schedule assets patching if the pool is not full.
            while #patch_assets_pool < max_parallel_assets and #patch_assets_queue > 0 do
                local asset = table.remove(patch_assets_queue, 1) :: SophonAsset

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
                        .collect() :: { chunk: SophonDownloadChunkInfo, offset: number }
                }

                table.insert(patch_assets_pool, {
                    asset = asset,
                    promise = sophon.patch_asset(
                        output_folder,
                        download_asset,
                        platform,
                        function(current: number, total: number)
                            for i, patching_info in ipairs(patch_assets_pool) do
                                if patching_info.asset.name == asset.name then
                                    patch_assets_pool[i].current = current
                                    patch_assets_pool[i].total = total

                                    break
                                end
                            end
                        end
                    ),
                    current = 0,
                    total = 0
                })
            end

            -- Calculate current and total progress of all the assets patching
            -- and send them to the updater callback.
            local current_progress = finished_assets_total_size
            local total_progress = finished_assets_total_size

            for _, patching_info in ipairs(patch_assets_pool) do
                current_progress += patching_info.current
                total_progress += patching_info.total
            end

            updater(current_progress, total_progress)

            -- Iretate over all the scheduled assets patching tasks.
            for _ = 1,#patch_assets_pool do
                -- Take the task info from the pool.
                local asset = table.remove(patch_assets_pool) :: ScheduledAssetInfo

                -- Poll it and if it's not finished yet - return it back to the
                -- pool.
                if not asset.promise:poll() then
                    table.insert(patch_assets_pool, asset)

                    continue
                end

                -- Otherwise increment the total finished assets size. Since
                -- we've already removed the task from the pool we don't need to
                -- do anything else.
                finished_assets_total_size += asset.total
            end

            return false, nil
        end
    end)
end

local function fetch_game_components(
    region: Region,
    game_info: SophonFetchApiInfo
): Promise<{ GameComponentInfo }>
    local iter = import("iterable")

    local promise = fetch_sophon_api(region, game_info)

    return task.create(function(): (boolean, { GameComponentInfo } | nil)
        local status, result = promise:poll()

        if not status then
            return false, nil
        end

        -- Prepare components list from the returned
        -- sophon manifests.
        local components = iter(result.manifests)
            .map(function(manifest: SophonManifestInfo): GameComponentInfo
                return {
                    name = manifest.matching_field,

                    download = function(
                        game_folder: string,
                        platform: Platform,
                        updater: (current: number, total: number) -> (),
                        max_parallel_assets: number | nil
                    ): Promise<nil>
                        return download_game_component(
                            game_folder,
                            manifest,
                            platform,
                            updater,
                            max_parallel_assets
                        )
                    end
                }
            end)
            .collect() :: { GameComponentInfo }

        return true, components
    end)
end

local function fetch_game_info(game: Game, region: Region, platform: Platform): Promise<GameInfo>
    local promise = fetch_games_api(region)

    return task.create(function(): (boolean, GameInfo | nil)
        local status, api = promise:poll()

        if not status then
            return false, nil
        end

        local iter, semver = import("iterable", "semver")

        local game_info: RawGameInfo | nil = iter(api)
            .find(function(info: RawGameInfo)
                return info.game.biz == api_info[region].games[game].biz
                    and info.game.id == api_info[region].games[game].id
            end)

        if not game_info then
            error(`hyvlib: failed to fetch '{game}' game info`)
        end

        local game_info: GameInfo = {
            version = semver(game_info.main.tag),
            diffs = iter(game_info.main.diff_tags)
                .map(semver)
                .collect(),

            fetch_components = function(): Promise<{ GameComponentInfo }>
                return fetch_game_components(region, {
                    branch = game_info.main.branch,
                    game_biz = game_info.game.biz,
                    game_id = game_info.game.id,
                    package_id = game_info.main.package_id,
                    password = game_info.main.password
                })
            end
        }

        return true, game_info
    end)
end

----------------------------------------
-- Hyvlib export functions

type Hyvlib = {
    games: {[Game]: {
        -- Try to parse game version from its installation files.
        try_parse_version: (game_folder: string, region: Region) -> Promise<Semver | nil>,

        -- Fetch game info from the API.
        fetch_info: (region: Region) -> Promise<GameInfo>
    }}
}

local function __blank_parse_version(): Promise<Semver | nil>
    return task.create(nil)
end

local hyvlib: Hyvlib = {
    games = {
        genshin = {
            -- TODO: parse version from actual game files
            try_parse_version = __blank_parse_version,

            fetch_info = function(region: Region, platform: Platform): Promise<GameInfo>
                return fetch_game_info("genshin", region, platform)
            end
        },

        hsr = {
            -- TODO: parse version from actual game files
            try_parse_version = __blank_parse_version,

            fetch_info = function(region: Region, platform: Platform): Promise<GameInfo>
                return fetch_game_info("hsr", region, platform)
            end
        },

        zzz = {
            -- TODO: parse version from actual game files
            try_parse_version = __blank_parse_version,

            fetch_info = function(region: Region, platform: Platform): Promise<GameInfo>
                return fetch_game_info("zzz", region, platform)
            end
        }
    }
}

-- return hyvlib

return function()
    local game_info = hyvlib.games["zzz" :: Game].fetch_info("global"):await()
    local game_components = game_info.fetch_components():await()

    dbg(game_components)

    local output_folder = path.join(path.temp_dir(), "penis")

    game_components[1].download(
        output_folder,
        "x86_64-linux",
        function(current: number, total: number)
            if total > 0 then
                print(`Downloading: {math.floor(current / total * 10000) / 100}% of {total / 1024 / 1024} MiB`)
            end
        end,
        4
    ):await()

    -- local game_info = fetch_games_api("global"):await()[1]
    -- local sophon_info = game_info.fetch_sophon_info():await()
    -- local manifest_info = sophon_info.manifests[2]

    -- dbg(manifest_info)

    -- local download_manifest = {
    --     id = manifest_info.manifest.id,
    --     md5_checksum = manifest_info.manifest.md5_checksum,
    --     download_url = manifest_info.manifest.download_url,
    --     compressed = manifest_info.manifest.compressed
    -- }

    -- local assets = sophon.download_manifest(
    --     download_manifest,
    --     "x86_64-linux",
    --     function(current: number, total: number)
    --         print(`Progress: {current / 1024} KiB / {total / 1024} KiB`)
    --     end
    -- ):await()

    -- local output_folder = path.join(path.temp_dir(), "sophon_assets_output")

    -- for _, asset in ipairs(assets) do
    --     print(`processing asset '{asset.name}' ({asset.size / 1024} KiB)`)

    --     local download_asset: SophonDownloadAssetInfo = {
    --         name = asset.name,
    --         md5_checksum = asset.md5_checksum,
    --         chunks = iter(asset.chunks)
    --             .map(function(chunk: SophonChunk): { chunk: SophonDownloadChunkInfo, offset: number }
    --                 return {
    --                     chunk = {
    --                         name = chunk.name,
    --                         md5_checksum = chunk.uncompressed.md5_checksum,
    --                         download_url = `{manifest_info.chunks.download_url}/{chunk.name}`
    --                     },
    --                     offset = chunk.offset
    --                 }
    --             end)
    --             .collect()
    --     }

    --     sophon.patch_asset(
    --         output_folder,
    --         download_asset,
    --         "x86_64-linux",
    --         function(current: number, total: number)
    --             print(`Progress: {current / 1024} KiB / {total / 1024} KiB`)
    --         end
    --     ):await()
    -- end
end
