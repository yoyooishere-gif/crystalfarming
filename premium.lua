--==[ ADVANCED SERVER HOPPER – ADAPTIVE, ANTI 429, VISITED 2 JAM ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local CONFIG = {
    DelayBeforeStart   = 12,   -- jeda sebelum mulai hop (detik)

    -- 🎯 Range utama
    MinPlayers         = 7,
    MaxPlayers         = 12,

    -- 🔻 Batas bawah biar cadangan nggak terlalu sepi
    MinPlayersFloor    = 5,

    -- 📈 Adaptive range
    RangeExpandStep    = 2,    -- per step: min-=2, max+=2
    MaxExpandSteps     = 3,    -- berapa kali lebarin range

    MaxPagesToScan     = 3,    -- SEMAKIN KECIL = SEMAKIN AMAN DARI 429
    RandomStartPage    = false,

    UseAntiFriend      = true,
    RememberVisited    = true, -- pakai sistem visited 2 jam
}

task.wait(CONFIG.DelayBeforeStart)

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local placeId     = game.PlaceId

math.randomseed(os.time())

----------------------------------------------------------------
-- 🔁 VISITED (tidak masuk server yang sama < 2 jam)
----------------------------------------------------------------
local VISITED_TTL_SECONDS = 2 * 60 * 60  -- 2 jam

-- simpan di getgenv supaya kepakai antar eksekusi script
local env = getgenv and getgenv() or _G
env.AdvServerHopVisitedTimes = env.AdvServerHopVisitedTimes or {}
env.AdvServerHopVisitedTimes[placeId] = env.AdvServerHopVisitedTimes[placeId] or {}

-- visited khusus per place
local visited = env.AdvServerHopVisitedTimes[placeId]

-- bersihkan entry yang sudah lebih dari 2 jam
local function cleanupVisited()
    local now = os.time()
    for jobId, t in pairs(visited) do
        if (now - t) > VISITED_TTL_SECONDS then
            visited[jobId] = nil
        end
    end
end

-- cek apakah server pernah dikunjungi < 2 jam
local function wasVisitedRecently(jobId)
    cleanupVisited()
    local t = visited[jobId]
    if not t then return false end
    return (os.time() - t) <= VISITED_TTL_SECONDS
end

-- tandai server baru dikunjungi
local function markVisited(jobId)
    cleanupVisited()
    visited[jobId] = os.time()
end

----------------------------------------------------------------
-- 👥 Anti friend
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
-- 📄 Ambil server list (anti-429)
----------------------------------------------------------------
local cursor            = nil
local LAST_HTTP_TIME    = 0
local HTTP_COOLDOWN     = 12   -- cooldown antar request
local HIT_RATE_LIMIT    = false

local function GetServers()
    -- Cooldown anti spam / anti 429
    local now  = os.clock()
    local diff = now - LAST_HTTP_TIME
    if diff < HTTP_COOLDOWN then
        task.wait(HTTP_COOLDOWN - diff)
    end
    LAST_HTTP_TIME = os.clock()

    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100")
        :format(placeId)
    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not ok then
        local msg = tostring(result)
        if msg:find("429") then
            HIT_RATE_LIMIT = true
            warn("[ServerHop] HTTP 429 (Too Many Requests). Stop dulu, jangan spam.")
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
-- (Opsional) Random start page
----------------------------------------------------------------
if CONFIG.RandomStartPage then
    local maxSkip   = math.max(0, CONFIG.MaxPagesToScan - 1)
    local skipPages = math.random(0, maxSkip)

    for _ = 1, skipPages do
        local servers = GetServers()
        if not servers or not cursor then break end
    end

    print("[ServerHop] Mulai scan dari page acak, skip halaman:", skipPages)
end

print(("[ServerHop] Target awal: %d–%d pemain"):format(CONFIG.MinPlayers, CONFIG.MaxPlayers))

----------------------------------------------------------------
-- 🔎 Kumpulkan semua server yang mungkin
----------------------------------------------------------------
local allServers = {}

for page = 1, CONFIG.MaxPagesToScan do
    local servers = GetServers()
    if not servers then break end

    for _, server in ipairs(servers) do
        local sid       = server.id
        local playing   = server.playing
        local maxPlr    = server.maxPlayers

        local notFull        = playing < maxPlr
        local notVisitedRecently = (not CONFIG.RememberVisited) or (not wasVisitedRecently(sid))

        if notFull and notVisitedRecently then
            table.insert(allServers, {
                id      = sid,
                playing = playing,
                max     = maxPlr,
            })
        elseif CONFIG.RememberVisited and wasVisitedRecently(sid) then
            -- Debug info: server dilewati karena pernah dikunjungi < 2 jam
            warn("[ServerHop] Skip server " .. tostring(sid) .. " (pernah dikunjungi < 2 jam).")
        end
    end

    if not cursor then
        break
    end
end

if #allServers == 0 then
    if HIT_RATE_LIMIT then
        -- ⛔ DI SINI PENTING: JANGAN REJOIN, CUKUP STOP
        warn("[ServerHop] Tidak jadi hop karena baru saja kena rate limit. Tunggu beberapa menit dulu.")
        return
    else
        warn("[ServerHop] Tidak ada data server yang valid. Tidak jadi hop.")
        return
    end
end

----------------------------------------------------------------
-- ⚙️ Scoring & adaptive range
----------------------------------------------------------------
local function pickBestInRange(minPlayers, maxPlayers)
    local mid = (minPlayers + maxPlayers) / 2
    local best, bestScore = nil, nil

    for _, info in ipairs(allServers) do
        local p = info.playing
        if p >= minPlayers and p <= maxPlayers then
            local dist  = math.abs(p - mid)
            local score = -dist + math.random()
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

-- Adaptive range: 7–12 → (5–14) → dst
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

    warn(("[ServerHop] Coba range %d–%d (step %d)"):format(minP, maxP, i))
    target = pickBestInRange(minP, maxP)
    if target then
        break
    end
end

if not target then
    target = pickBestAboveFloor(CONFIG.MinPlayersFloor)
    if target then
        warn("[ServerHop] Tidak ada server di range adaptif, pakai server terpadat ≥ floor.")
    else
        warn("[ServerHop] Tidak menemukan server yang cocok. Tidak jadi hop.")
        return
    end
end

----------------------------------------------------------------
-- 🚀 Teleport
----------------------------------------------------------------
print(("[ServerHop] Teleport ke server %s (%d/%d pemain)")
    :format(target.id, target.playing, target.max))

if CONFIG.RememberVisited then
    markVisited(target.id)
end

local okTp, tpErr = pcall(function()
    TeleportService:TeleportToPlaceInstance(placeId, target.id, LocalPlayer)
end)

if not okTp then
    local errStr = tostring(tpErr)
    warn("[ServerHop] Teleport gagal:", errStr)
end
