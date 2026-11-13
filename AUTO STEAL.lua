-- RMZ Hub | Roblox egg-steal automation | Lua (Roblox executor)
-- Target: any Roblox game with egg/pet-steal mechanics
-- Run in: Synapse X, Krnl, Fluxus, Delta, or similar executor

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- CONFIG
-- ============================================================
local CONFIG = {
    autoSteal       = true,
    autoStealRange  = 30,      -- studs
    autoStealDelay  = 0.15,    -- seconds between attempts
    antiHit         = true,
    antiTrap        = true,
    autoConveyor    = false,
    autoConveyorSpeed = 0.5,   -- seconds between belt grabs
    showPetMenu     = true,
    guiColor        = Color3.fromRGB(15, 15, 20),
    accentColor     = Color3.fromRGB(255, 45, 85),
}

-- Rarity order (game-agnostic — adjust per game)
local RARITY_ORDER = {
    ["Common"]    = 1,
    ["Uncommon"]  = 2,
    ["Rare"]      = 3,
    ["Epic"]      = 4,
    ["Legendary"] = 5,
    ["Mythical"]  = 6,
    ["Secret"]    = 7,
    ["Exclusive"] = 8,
    ["Limited"]   = 9,
}

local RARITY_COLORS = {
    ["Common"]    = Color3.fromRGB(180, 180, 180),
    ["Uncommon"]  = Color3.fromRGB(90, 200, 90),
    ["Rare"]      = Color3.fromRGB(80, 150, 255),
    ["Epic"]      = Color3.fromRGB(180, 80, 255),
    ["Legendary"] = Color3.fromRGB(255, 200, 50),
    ["Mythical"]  = Color3.fromRGB(255, 80, 80),
    ["Secret"]    = Color3.fromRGB(255, 50, 200),
    ["Exclusive"] = Color3.fromRGB(50, 255, 220),
    ["Limited"]   = Color3.fromRGB(255, 140, 0),
    ["Unknown"]   = Color3.fromRGB(150, 150, 150),
}

-- ============================================================
-- HELPERS
-- ============================================================
local function getCharacter()
    return LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
end

local function getHRP()
    local char = getCharacter()
    return char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = getCharacter()
    return char:FindFirstChildOfClass("Humanoid")
end

local function distance(a, b)
    return (a.Position - b.Position).Magnitude
end

local function getRarity(petName)
    local name = petName:lower()
    for rarity, _ in pairs(RARITY_ORDER) do
        if name:find(rarity:lower(), 1, true) then
            return rarity
        end
    end
    -- heuristic fallbacks common in pet games
    if name:find("secret") or name:find("hidden") then return "Secret" end
    if name:find("mythic") or name:find("mythical") then return "Mythical" end
    if name:find("legend") or name:find("legendary") then return "Legendary" end
    if name:find("epic") then return "Epic" end
    if name:find("rare") then return "Rare" end
    if name:find("uncommon") then return "Uncommon" end
    return "Unknown"
end

local function getPetValue(petName, rarity)
    local base = {
        Common = 1, Uncommon = 5, Rare = 25, Epic = 100,
        Legendary = 500, Mythical = 2500, Secret = 10000,
        Exclusive = 15000, Limited = 20000, Unknown = 0,
    }
    local v = base[rarity] or 0
    -- scale by name length as a cheap heuristic for named pets
    v = v * (1 + (#petName % 10) * 0.1)
    return math.floor(v)
end

-- ============================================================
-- REMOTE DISCOVERY
-- ============================================================
-- Most egg/pet-steal games expose a RemoteEvent or RemoteFunction
-- with a name matching steal/egg/pet/grab/take/claim.
local function findStealRemotes()
    local remotes = {}
    local patterns = {"steal", "egg", "pet", "grab", "take", "claim", "hatch", "collect"}
    local function scan(root)
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                local n = obj.Name:lower()
                for _, p in ipairs(patterns) do
                    if n:find(p, 1, true) then
                        table.insert(remotes, obj)
                        break
                    end
                end
            end
        end
    end
    scan(ReplicatedStorage)
    if Workspace:FindFirstChild("Remotes") then scan(Workspace.Remotes) end
    return remotes
end

local STEAL_REMOTES = findStealRemotes()

-- ============================================================
-- ANTI-HIT / ANTI-TRAP
-- ============================================================
-- Anti-hit: intercept Humanoid.Health changes and revert damage
-- Anti-trap: detect CFrame teleports to known trap zones and snap back
local antiHitConn, antiTrapConn
local safeCFrame = nil

local function startAntiHit()
    local hum = getHumanoid()
    if not hum then return end
    antiHitConn = hum.HealthChanged:Connect(function(newHealth)
        if CONFIG.antiHit and newHealth < hum.MaxHealth then
            hum.Health = hum.MaxHealth
        end
    end)
    -- also neutralise direct damage scripts
    local char = getCharacter()
    local forceField = char:FindFirstChildOfClass("ForceField")
    if not forceField then
        forceField = Instance.new("ForceField")
        forceField.Parent = char
    end
end

local function startAntiTrap()
    safeCFrame = getHRP() and getHRP().CFrame
    antiTrapConn = RunService.Heartbeat:Connect(function()
        if not CONFIG.antiTrap then return end
        local hrp = getHRP()
        if not hrp then return end
        -- detect vertical drops (trap pits) or teleports far from safe
        if safeCFrame and distance(hrp, safeCFrame) > 120 then
            hrp.CFrame = safeCFrame
        elseif hrp.Position.Y < -100 then
            hrp.CFrame = safeCFrame or CFrame.new(0, 50, 0)
        end
        -- refresh safe anchor when grounded and stable
        local hum = getHumanoid()
        if hum and hum.FloorMaterial ~= Enum.Material.Air then
            safeCFrame = hrp.CFrame
        end
    end)
end

-- ============================================================
-- AUTO STEAL
-- ============================================================
local lastSteal = 0

local function findNearestEgg()
    local hrp = getHRP()
    if not hrp then return nil end
    local best, bestDist = nil, CONFIG.autoStealRange
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") or obj:IsA("Model") then
            local n = obj.Name:lower()
            if n:find("egg", 1, true) or n:find("pet", 1, true) then
                local part = obj:IsA("BasePart") and obj or obj.PrimaryPart
                if part then
                    local d = distance(hrp, part)
                    if d < bestDist then
                        best, bestDist = obj, d
                    end
                end
            end
        end
    end
    return best
end

local function attemptSteal(egg)
    if not egg then return end
    local hrp = getHRP()
    if not hrp then return end
    local part = egg:IsA("BasePart") and egg or egg.PrimaryPart
    if not part then return end

    -- teleport near egg
    hrp.CFrame = part.CFrame * CFrame.new(0, 3, 4)

    -- fire every discovered steal remote with common argument shapes
    for _, remote in ipairs(STEAL_REMOTES) do
        pcall(function()
            if remote:IsA("RemoteEvent") then
                remote:FireServer(egg)
                remote:FireServer(egg.Name)
                remote:FireServer(part)
            else
                remote:InvokeServer(egg)
                remote:InvokeServer(egg.Name)
            end
        end)
    end

    -- fallback: ProximityPrompt
    local prompt = egg:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then
        for _, d in ipairs(egg:GetDescendants()) do
            if d:IsA("ProximityPrompt") then prompt = d; break end
        end
    end
    if prompt then
        pcall(function()
            fireproximityprompt(prompt)
        end)
    end
end

-- ============================================================
-- AUTO CONVEYOR
-- ============================================================
local lastConveyor = 0

local function autoConveyorTick()
    if not CONFIG.autoConveyor then return end
    if tick() - lastConveyor < CONFIG.autoConveyorSpeed then return end
    lastConveyor = tick()

    local hrp = getHRP()
    if not hrp then return end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find("conveyor", 1, true) then
            if distance(hrp, obj) < 80 then
                hrp.CFrame = obj.CFrame * CFrame.new(0, 3, 0)
                local prompt = obj:FindFirstChildOfClass("ProximityPrompt")
                if prompt then pcall(fireproximityprompt, prompt) end
                for _, remote in ipairs(STEAL_REMOTES) do
                    pcall(function()
                        if remote:IsA("RemoteEvent") then
                            remote:FireServer(obj)
                        else
                            remote:InvokeServer(obj)
                        end
                    end)
                end
            end
        end
    end
end

-- ============================================================
-- PET INVENTORY SCAN
-- ============================================================
local function scanPets()
    local pets = {}
    local containers = {
        LocalPlayer:FindFirstChild("Pets"),
        LocalPlayer:FindFirstChild("Inventory"),
        LocalPlayer:FindFirstChild("OwnedPets"),
        ReplicatedStorage:FindFirstChild("Pets"),
    }
    for _, c in ipairs(containers) do
        if c then
            for _, p in ipairs(c:GetChildren()) do
                local name = p.Name
                local rarity = getRarity(name)
                table.insert(pets, {
                    name = name,
                    rarity = rarity,
                    value = getPetValue(name, rarity),
                    object = p,
                })
            end
        end
    end
    table.sort(pets, function(a, b)
        local ra
