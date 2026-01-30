--==[ ADVANCED SERVER HOPPER – ADAPTIVE RANGE ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- Konfigurasi umum
local CONFIG = {
    DelayBeforeStart   = 12,   -- jeda sebelum mulai hop (detik)

    -- 🎯 Range target utama
    MinPlayers         = 7,    -- minimal pemain di server tujuan
    MaxPlayers         = 12,   -- maksimal pemain di server tujuan

    -- 🔻 Batas bawah agar server cadangan tetap lumayan rame
    MinPlayersFloor    = 5,

    -- 📈 Adaptive range
    RangeExpandStep    = 2,    -- tiap step, min -= 2, max += 2
    MaxExpandSteps     = 3,    -- berapa kali range diperluas dari range utama

    MaxPagesToScan     = 4,    -- maksimal halaman server yang discan
    RandomStartPage    = false,-- kalau mau random page, set true

    UseAntiFriend      = true, -- cek teman di server sekarang
    RememberVisited    = true, -- ingat server yang sudah dikunjungi
    ResetVisitedAfter  = 150,  -- kalau visited > ini, reset list
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
----------------------------------------------------------------
local env = getgenv and getgenv() or _G
env.AdvServerHopVisited = env.AdvServerHopVisited or {}
local visited = env.AdvServerHopVisited

local function countVisited()
    local n = 0
    for _ in pairs(visited) do n += 1 end
    return n
end

if CONFIG.RememberVisited and countVisited() > CONFIG.ResetVisitedAfter then
    visited = {}
    env.AdvServerHopVisited = visited
    warn("[ServerHop] Reset daftar visited server (kebanyakan).")
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
    local testUrl = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=10")
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
-- 🪂 Mode simple (kalau HTTP benar-benar nggak bisa)
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
-- 📄 Ambil server list (Advanced mode) + Cooldown & anti 429
----------------------------------------------------------------
local cursor            = nil
local LAST_HTTP_TIME    = 0
local HTTP_COOLDOWN     = 12  -- detik, sesuai permintaan kamu
local HIT_RATE_LIMIT    = false

local function GetServers()
    -- Cooldown biar nggak spam API (anti 429)
    local now = os.clock()
    local diff = now - LAST_HTTP_TIME
    if diff < HTTP_COOLDOWN then
        task.wait(HTTP_COOLDOWN - diff)
    end
    LAST_HTTP_TIME = os.clock()

    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100")
        :format(placeId)

    if cursor then
        url ..= "&cursor=" .. cursor
    end

    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not ok then
        local msg = tostring(result)
        if msg:find("429") then
            HIT_RATE_LIMIT = true
            warn("[ServerHop] Gagal ambil server list: HTTP 429 (Too Many Requests). Cooldown 12 detik.")
            task.wait(12)
        else
            warn("[ServerHop] Gagal ambil server list:", msg)
        end
        return nil
    end

    local decoded
    local okDecode, errDecode = pcall(function()
        decoded = HttpService:JSONDecode(result)
    end)

    if not okDecode or not decoded then
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

print(("[ServerHop] Target awal: %d–%d pemain"):format(CONFIG.MinPlayers, CONFIG.MaxPlayers))

----------------------------------------------------------------
-- 🔎 Kumpulkan semua server kandidat (sekali HTTP saja)
----------------------------------------------------------------
local allServers = {}

for page = 1, CONFIG.MaxPagesToScan do
    local servers = GetServers()
    if not servers then break end

    for _, server in ipairs(servers) do
        local sid       = server.id
        local playing   = server.playing
        local maxPlr    = server.maxPlayers

        local notFull    = playing < maxPlr
        local notVisited = (not CONFIG.RememberVisited) or (not visited[sid])

        if notFull and notVisited then
            table.insert(allServers, {
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

if #allServers == 0 then
    if HIT_RATE_LIMIT then
        warn("[ServerHop] Kena rate limit, tidak hop lagi di join ini supaya tidak spam.")
        return
    else
        warn("[ServerHop] Tidak ada data server (advanced). Rejoin biasa.")
        SimpleRejoin()
        return
    end
end

----------------------------------------------------------------
-- ⚙️ Fungsi pilih server terbaik dengan skor
----------------------------------------------------------------
local function pickBestInRange(minPlayers, maxPlayers)
    local mid = (minPlayers + maxPlayers) / 2
    local best, bestScore = nil, nil

    for _, info in ipairs(allServers) do
        local p = info.playing
        if p >= minPlayers and p <= maxPlayers then
            local dist  = math.abs(p - mid)
            local score = -dist + math.random() -- makin dekat ke mid makin bagus

            if not best or score > bestScore then
                best      = info
                bestScore = score
            end
        end
    end

    return best
end

local function pickBestAboveFloor(floor)
    local best, bestScore = nil, nil

    for _, info in ipairs(allServers) do
        local p = info.playing
        if p >= floor then
            local score = p + math.random() -- makin rame makin prioritas
            if not best or score > bestScore then
                best      = info
                bestScore = score
            end
        end
    end

    return best
end

----------------------------------------------------------------
-- 📈 Adaptive range: 7–12 → (5–14) → (5–16) → ...
----------------------------------------------------------------
local baseMin = CONFIG.MinPlayers
local baseMax = CONFIG.MaxPlayers
local step    = CONFIG.RangeExpandStep
local maxStep = CONFIG.MaxExpandSteps

local target = nil

for i = 0, maxStep do
    local minP = baseMin - step * i
    local maxP = baseMax + step * i

    if minP < CONFIG.MinPlayersFloor then
        minP = CONFIG.MinPlayersFloor
    end

    warn(("[ServerHop] Coba range %d–%d (expand step %d)"):format(minP, maxP, i))
    target = pickBestInRange(minP, maxP)
    if target then
        break
    end
end

if not target then
    -- Tidak ada di range adaptif, pakai server terpadat di atas MinPlayersFloor
    target = pickBestAboveFloor(CONFIG.MinPlayersFloor)
    if target then
        warn("[ServerHop] Tidak ada server di range adaptif, pakai server terpadat di atas floor.")
    else
        warn("[ServerHop] Tidak ada server lain yang bisa dimasuki. Rejoin biasa.")
        SimpleRejoin()
        return
    end
end

----------------------------------------------------------------
-- 🚀 Teleport ke server target
----------------------------------------------------------------
print(("[ServerHop] Teleport ke server %s (%d/%d pemain)")
    :format(target.id, target.playing, target.max))

if CONFIG.RememberVisited then
    visited[target.id] = true
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
