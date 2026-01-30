--==[ ADVANCED SERVER HOPPER – NO DUPLICATE SERVER (<2 JAM) ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- Konfigurasi umum
local CONFIG = {
    DelayBeforeStart    = 12,      -- jeda sebelum mulai hop (detik)
    MaxPagesToScan      = 6,       -- maksimal halaman server yang discan
    RandomStartPage     = true,    -- mulai dari page acak
    UseAntiFriend       = true,    -- cek teman di server sekarang
    RememberVisited     = true,    -- ingat server yang sudah dikunjungi
    ResetVisitedAfter   = 300,     -- kalau total data visited > ini, reset penuh
    VisitExpirySeconds  = 2 * 60 * 60, -- EXP: 2 jam (dalam detik)
}

task.wait(CONFIG.DelayBeforeStart)

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local placeId     = game.PlaceId

math.randomseed(os.time())

----------------------------------------------------------------
-- 🔁 GLOBAL visited server list (supaya ingat lewat teleport)
--     Format: visited[serverId] = timestampTerakhirMasuk (os.time())
----------------------------------------------------------------
local env = getgenv and getgenv() or _G
env.AdvServerHopVisited = env.AdvServerHopVisited or {}
local visited = env.AdvServerHopVisited

local function cleanupExpiredVisited()
    if not CONFIG.RememberVisited then return end
    local now = os.time()
    local removed = 0

    for sid, ts in pairs(visited) do
        if type(ts) ~= "number" or (now - ts) >= CONFIG.VisitExpirySeconds then
            visited[sid] = nil
            removed += 1
        end
    end

    if removed > 0 then
        warn(("[ServerHop] Bersihkan %d server dari visited (kadaluarsa)."):format(removed))
    end
end

local function countVisited()
    local n = 0
    for _ in pairs(visited) do n += 1 end
    return n
end

-- Bersihkan entry kadaluarsa dulu
cleanupExpiredVisited()

if CONFIG.RememberVisited and countVisited() > CONFIG.ResetVisitedAfter then
    visited = {}
    env.AdvServerHopVisited = visited
    warn("[ServerHop] Reset total visited server (kebanyakan data).")
end

-- Cek apakah server sudah pernah dikunjungi & masih dalam masa "ban" (belum 2 jam)
local function isStillVisited(serverId)
    if not CONFIG.RememberVisited then
        return false
    end

    local ts = visited[serverId]
    if not ts then
        return false
    end

    local now = os.time()
    if (now - ts) >= CONFIG.VisitExpirySeconds then
        -- sudah lewat 2 jam, hapus dan anggap belum visited
        visited[serverId] = nil
        return false
    end

    -- masih dalam periode 2 jam
    return true
end

----------------------------------------------------------------
-- 👥 Load daftar teman (kalau anti friend on)
----------------------------------------------------------------
local FriendIds = {}

local function loadFriends()
    local ok, pagesOrErr = pcall(function()
        return Players:GetFriendsAsync(LocalPlayer.UserId)
    end)

    if not ok then
        warn("[ServerHop] Gagal load daftar teman:", pagesOrErr)
        return
    end

    local pages = pagesOrErr
    repeat
        for _, info in ipairs(pages:GetCurrentPage()) do
            FriendIds[info.Id] = true
        end
    until pages.IsFinished or not pcall(function()
        pages:AdvanceToNextPageAsync()
    end)
end

if CONFIG.UseAntiFriend then
    loadFriends()
end

local function HasFriendInCurrentServer()
    if not CONFIG.UseAntiFriend then return false end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and FriendIds[plr.UserId] then
            return true, plr.Name
        end
    end
    return false
end

local hasFriend, friendName = HasFriendInCurrentServer()
if hasFriend then
    warn("[ServerHop] Ada teman di server ini:", friendName, "→ cari server lain.")
else
    print("[ServerHop] Tidak ada teman di server ini.")
end

----------------------------------------------------------------
-- 🌐 Cek apakah HTTP ke games.roblox.com tersedia
----------------------------------------------------------------
local HTTP_OK = true

do
    local testUrl = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=10")
        :format(placeId)

    local ok, res = pcall(function()
        return game:HttpGet(testUrl)
    end)

    if not ok then
        HTTP_OK = false
        warn("[ServerHop] HTTP ke games.roblox.com diblokir oleh executor / device.")
        warn("[ServerHop] Pindah ke mode sederhana: rejoin biasa.")
    else
        local okDecode = pcall(function()
            HttpService:JSONDecode(res)
        end)
        if not okDecode then
            HTTP_OK = false
            warn("[ServerHop] Response server list tidak valid, mode advanced dimatikan.")
        end
    end
end

----------------------------------------------------------------
-- 🪂 Mode simple (kalau HTTP tidak bisa)
----------------------------------------------------------------
local function SimpleRejoin()
    warn("[ServerHop] Mode simple aktif (tanpa server list). Rejoin place saja.")
    local okTp, err = pcall(function()
        TeleportService:Teleport(placeId, LocalPlayer)
    end)
    if not okTp then
        warn("[ServerHop] Teleport simple gagal:", err)
    end
end

if not HTTP_OK then
    SimpleRejoin()
    return
end

----------------------------------------------------------------
-- 📄 Ambil server list (Advanced mode)
----------------------------------------------------------------
local cursor = nil

local function GetServers()
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
        :format(placeId)

    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not ok then
        warn("[ServerHop] Gagal ambil server list:", result)
        return nil
    end

    local decoded
    local okDecode, errDecode = pcall(function()
        decoded = HttpService:JSONDecode(result)
    end)

    if not okDecode then
        warn("[ServerHop] Gagal decode JSON server list:", errDecode)
        return nil
    end

    cursor = decoded.nextPageCursor
    return decoded.data
end

----------------------------------------------------------------
-- 🎲 Skip ke page acak dulu (RandomStartPage)
----------------------------------------------------------------
if CONFIG.RandomStartPage then
    local maxSkip = math.max(0, CONFIG.MaxPagesToScan - 1)
    local skipPages = math.random(0, maxSkip)

    for _ = 1, skipPages do
        local servers = GetServers()
        if not servers or not cursor then break end
    end

    print("[ServerHop] Mulai scan dari page acak, skip halaman:", skipPages)
end

print("[ServerHop] Mode bebas jumlah pemain, hanya skip server yang sudah pernah dimasuki (<2 jam).")

----------------------------------------------------------------
-- 🔎 Kumpulkan kandidat server
--     - tidak penuh
--     - belum pernah dikunjungi dalam 2 jam terakhir (kalau RememberVisited = true)
----------------------------------------------------------------
local candidates = {}

for page = 1, CONFIG.MaxPagesToScan do
    local servers = GetServers()
    if not servers then break end

    for _, server in ipairs(servers) do
        local sid     = server.id
        local playing = server.playing
        local maxPlr  = server.maxPlayers

        local notFull    = playing < maxPlr
        local notVisited = (not CONFIG.RememberVisited) or (not isStillVisited(sid))

        if notFull and notVisited then
            table.insert(candidates, {
                id      = sid,
                playing = playing,
                max     = maxPlr,
            })
        end
    end

    if not cursor then
        break
    end
end

-- Fungsi pilih server random dari kandidat
local function pickRandom(list)
    if #list == 0 then return nil end
    return list[math.random(1, #list)]
end

local target = pickRandom(candidates)

if not target then
    warn("[ServerHop] Tidak menemukan server lain yang belum dikunjungi (advanced). Rejoin biasa.")
    SimpleRejoin()
    return
end

----------------------------------------------------------------
-- 🚀 Teleport ke server target
----------------------------------------------------------------
print(("[ServerHop] Teleport ke server %s (%d/%d pemain)")
    :format(target.id, target.playing, target.max))

if CONFIG.RememberVisited then
    visited[target.id] = os.time()
end

local okTp, tpErr = pcall(function()
    TeleportService:TeleportToPlaceInstance(placeId, target.id, LocalPlayer)
end)

if not okTp then
    local errStr = tostring(tpErr)
    warn("[ServerHop] Teleport gagal:", errStr)

    if errStr:find("773") or errStr:lower():find("restricted") then
        warn("[ServerHop] Error 773 (tempat/server dibatasi Roblox). " ..
             "Ini batas server, bukan script. Coba lagi nanti atau ganti game.")
    end
end
