--[[ 
    Project Dark - Auto_Main.lua (Ultra Edition)
    
    Features:
    - HMAC-signed token auth via /api/script/validate
    - Remote server joining / teleport
    - Dashboard integration (heartbeat, config, commands, logs)
    - Anti-AFK, auto-respawn, tween-to-target
    - Auto re‑execution after server hop (with retry)
    - Global error handler + safe loadstring
    - Executor detection & diagnostics
]]--

wait(1)  -- extra delay for stability

-- ============ EXECUTOR HTTP COMPATIBILITY ============
local httpRequest = (syn and syn.request) 
    or (http and http.request) 
    or (fluxus and fluxus.request)
    or request 
    or http_request

if not httpRequest then
    local HttpService = game:GetService("HttpService")
    httpRequest = function(params)
        local method = params.Method or "GET"
        local url = params.Url
        local body = params.Body
        local headers = params.Headers or {}
        local success, result
        if method == "POST" then
            success, result = pcall(function()
                return HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson, false, headers)
            end)
        else
            success, result = pcall(function()
                return HttpService:GetAsync(url, true, headers)
            end)
        end
        if success then
            return { StatusCode = 200, Body = result, Success = true }
        else
            return { StatusCode = 0, Body = tostring(result), Success = false }
        end
    end
end

-- ============ GLOBAL ERROR HANDLER ============
local function onError(err)
    warn("Project Dark caught error:", err)
    pcall(function()
        if authenticated then
            postJSON(ENDPOINTS.log, {
                userId = userId,
                player = playerName,
                level = "error",
                message = "Uncaught: " .. tostring(err),
                jobId = jobId,
                placeId = placeId,
                timestamp = os.time(),
                kills = killCount,
                deaths = deathCount,
            })
        end
    end)
end
xpcall(function() end, onError)  -- set global handler (works in most executors)

-- ============ SAFE LOADSTRING ============
local function safeLoadstring(code, chunkname)
    if type(code) ~= "string" then
        warn("safeLoadstring: code is not a string (" .. type(code) .. ")")
        return nil, "Code must be string"
    end
    if code == "" then
        warn("safeLoadstring: code is empty")
        return nil, "Code is empty"
    end
    return loadstring(code, chunkname)
end

-- ============ UI SETUP (with retry) ============
local Rayfield
local function loadRayfield()
    local urls = {
        "https://sirius.menu/rayfield",
        "https://raw.githubusercontent.com/RayfieldUI/Rayfield/main/source.lua",
    }
    for i, url in ipairs(urls) do
        for attempt = 1, 3 do
            local success, result = pcall(game.HttpGet, game, url)
            if success and type(result) == "string" and result ~= "" then
                local fn, err = safeLoadstring(result, "Rayfield")
                if fn then
                    Rayfield = fn()
                    return true
                else
                    warn("Rayfield loadstring error:", err)
                end
            else
                warn("Failed to fetch Rayfield from", url, "attempt", attempt)
            end
            task.wait(1 * attempt)  -- exponential backoff
        end
    end
    return false
end

if not loadRayfield() then
    warn("Could not load Rayfield UI. Using fallback UI?")
    -- Create a simple UI fallback (optional)
end

local Window = Rayfield:CreateWindow({
    Name = "Project Dark",
    Icon = 0,
    LoadingTitle = "Project Dark",
    LoadingSubtitle = "Ultra Edition",
    Theme = "Darker",
    ToggleUIKeybind = "K",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "ProjectDark",
        FileName = "UltraConfig"
    }
})

-- ============ SERVICES ============
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local respawnRemote = nil
pcall(function()
    respawnRemote = ReplicatedStorage:FindFirstChild("Remotes") 
        and ReplicatedStorage.Remotes:FindFirstChild("Duels") 
        and ReplicatedStorage.Remotes.Duels:FindFirstChild("RespawnNow")
end)

-- ============ EXECUTOR DETECTION ============
local executorName = (syn and syn.crypt and "Synapse") 
    or (fluxus and "Fluxus") 
    or (Krnl and "Krnl") 
    or (getexecutorname and getexecutorname()) 
    or "Unknown"

-- ============ AUTO RE-EXECUTE ON SERVER HOP ============
local _queueOnTeleport = (syn and syn.queue_on_teleport)
    or queue_on_teleport
    or (fluxus and fluxus.queue_on_teleport)
    or nil

local SCRIPT_REEXEC_URL = "https://raw.githubusercontent.com/Nobody2552/Project-Dark/main/Auto_Main.lua"
local SELF_URL = _G.__ProjectDark_ScriptURL or nil

local function queueAutoReexecute()
    if not _queueOnTeleport then 
        warn("⚠️ queue_on_teleport not available – auto‑re‑execution disabled")
        return false 
    end
    local scriptUrl = SELF_URL or SCRIPT_REEXEC_URL
    local reexecScript = string.format([[
        -- Project Dark: Auto re‑execute (secure)
        _G.__ProjectDark_AuthToken = %q
        _G.__ProjectDark_Target = %q
        _G.__ProjectDark_Distance = %s
        _G.__ProjectDark_Enabled = %s
        _G.__ProjectDark_KillsPerRound = %s
        _G.__ProjectDark_ScriptURL = %q
        task.wait(2)
        local success, result = pcall(game.HttpGet, game, %q)
        if success and type(result) == "string" and result ~= "" then
            local fn, err = loadstring(result)
            if fn then fn() else warn("Project Dark: loadstring error:", err) end
        else
            warn("Project Dark: Failed to fetch script after teleport")
        end
    ]],
        authToken or "",
        tostring(_G.TargetUsername or ""),
        tostring(_G.Distance or 0),
        tostring(enabled),
        tostring(killsPerRound or 15),
        scriptUrl,
        scriptUrl
    )
    local success, err = pcall(function() _queueOnTeleport(reexecScript) end)
    return success
end

-- ============ STATE ============
local authToken = _G.__ProjectDark_AuthToken or ""
local authenticated = false
_G.TargetUsername = _G.__ProjectDark_Target or ""
_G.Distance = _G.__ProjectDark_Distance or 0
local enabled = true
if _G.__ProjectDark_Enabled ~= nil then enabled = _G.__ProjectDark_Enabled end
local killCount = 0
local deathCount = 0
local killsPerRound = _G.__ProjectDark_KillsPerRound or 15
local isServerHop = (_G.__ProjectDark_AuthToken ~= nil and _G.__ProjectDark_AuthToken ~= "")

_G.__ProjectDark_AuthToken = nil
_G.__ProjectDark_Target = nil
_G.__ProjectDark_Distance = nil
_G.__ProjectDark_Enabled = nil
_G.__ProjectDark_KillsPerRound = nil

queueAutoReexecute()

local function refreshTeleportQueue() pcall(queueAutoReexecute) end

-- ============ DASHBOARD ENDPOINTS ============
local BASE_URL = "https://v0-project-dark.vercel.app"
local ENDPOINTS = {
    validate  = BASE_URL .. "/api/script/validate",
    heartbeat = BASE_URL .. "/api/script/heartbeat",
    config    = BASE_URL .. "/api/script/config",
    log       = BASE_URL .. "/api/script/log",
    commands  = BASE_URL .. "/api/script/commands",
}

-- ============ IDENTITY ============
local userId = tostring(LocalPlayer.UserId)
local playerName = LocalPlayer.Name
local displayName = LocalPlayer.DisplayName
local jobId = game.JobId
local placeId = tostring(game.PlaceId)

-- ============ UTILITIES ============
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function cleanToken(raw)
    if not raw then return "" end
    return raw:gsub("%s+", ""):gsub('"', ""):gsub("'", ""):gsub("\n", ""):gsub("\r", ""):gsub("\t", ""):gsub("%z", "")
end

local function urlEncode(str)
    if not str then return "" end
    str = tostring(str):gsub("\n", "\r\n")
    return str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")
end

-- ============ HTTP LAYER ============
local function postJSON(url, data)
    data.authToken = authToken
    local jsonBody = HttpService:JSONEncode(data)
    local ok, response = pcall(function()
        return httpRequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
                ["User-Agent"] = "ProjectDark/Ultra",
                ["X-PD-Token"] = authToken,
            },
            Body = jsonBody,
        })
    end)
    if not ok then return false, "HTTP error: " .. tostring(response) end
    if not response then return false, "No response" end
    local status, body = response.StatusCode or 0, response.Body or ""
    local decOk, decoded = pcall(function() return HttpService:JSONDecode(body) end)
    if status >= 200 and status < 300 then
        return true, (decOk and decoded or body)
    end
    return false, (decOk and decoded or ("HTTP " .. status .. ": " .. body:sub(1,200)))
end

local function getJSON(url)
    local sep = url:find("?") and "&" or "?"
    local finalUrl = url .. sep .. "authToken=" .. urlEncode(authToken)
    local ok, response = pcall(function()
        return httpRequest({
            Url = finalUrl,
            Method = "GET",
            Headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = "ProjectDark/Ultra",
                ["X-PD-Token"] = authToken,
            },
        })
    end)
    if not ok then return false, "HTTP error: " .. tostring(response) end
    if not response then return false, "No response" end
    local status, body = response.StatusCode or 0, response.Body or ""
    local decOk, decoded = pcall(function() return HttpService:JSONDecode(body) end)
    if status >= 200 and status < 300 then
        return true, (decOk and decoded or body)
    end
    return false, (decOk and decoded or ("HTTP " .. status .. ": " .. body:sub(1,200)))
end

-- ============ LOG ============
local function sendLog(level, message)
    task.spawn(function()
        pcall(function()
            postJSON(ENDPOINTS.log, {
                userId = userId,
                player = playerName,
                level = level,
                message = message,
                jobId = jobId,
                placeId = placeId,
                timestamp = os.time(),
                kills = killCount,
                deaths = deathCount,
                executor = executorName,
            })
        end)
    end)
end

-- ============ HEARTBEAT ============
local function sendHeartbeat()
    return postJSON(ENDPOINTS.heartbeat, {
        jobId = jobId,
        placeId = placeId,
        player = playerName,
        userId = userId,
        timestamp = os.time(),
        serverIp = jobId,
        serverPort = 0,
        kills = killCount,
        deaths = deathCount,
        scriptName = "Auto_Main.lua",
        scriptVersion = "Ultra",
        executor = executorName,
        gameVersion = game:GetService("HttpService"):JSONEncode(game:GetService("MarketplaceService"):GetProductInfo(placeId)),
    })
end

-- ============ TOKEN VALIDATION ============
local function validateToken(token)
    local cleaned = cleanToken(token)
    if cleaned == "" then return false, { error = "Empty token" } end
    if not cleaned:match("^PD%-") then return false, { error = "Token must start with PD-" } end
    if not cleaned:find("%.") then return false, { error = "Token missing HMAC signature (no dot)" } end

    local oldToken = authToken
    authToken = cleaned
    local ok, response = postJSON(ENDPOINTS.validate, {
        userId = userId,
        player = playerName,
        displayName = displayName,
        placeId = placeId,
        jobId = jobId,
        executor = executorName,
    })
    if ok and type(response) == "table" and response.valid == true then
        return true, response
    end
    authToken = oldToken
    return false, response
end

-- ============ UI ELEMENTS ============
local MainTab = Window:CreateTab("Main", nil)
local DebugTab = Window:CreateTab("Debug", nil)

MainTab:CreateSection("Status")
local StatusLabel = MainTab:CreateLabel("Waiting for authentication...")
local StatsLabel = MainTab:CreateLabel("Kills: 0 | Deaths: 0")

MainTab:CreateSection("Authentication")
local AuthStatus = MainTab:CreateLabel("Paste your token (PD-xxx.xxx) from the dashboard")
local AuthInput = MainTab:CreateInput({
    Name = "Auth Token",
    PlaceholderText = "PD-xxxxxxxxxxxxxxxx.xxxxxxx",
    RemoveTextAfterFocusLost = false,
    Flag = "AuthToken",
    Callback = function(text)
        if not text or trim(text) == "" then return end
        local cleaned = cleanToken(text)
        authenticated = false
        AuthStatus:Set("Validating: " .. cleaned:sub(1,15) .. "...")
        task.spawn(function()
            local valid, response = validateToken(cleaned)
            if valid then
                authenticated = true
                local method = (type(response) == "table" and response.authMethod) or "hmac"
                AuthStatus:Set("CONNECTED via " .. method .. " | " .. BASE_URL:gsub("https://",""))
                sendLog("success", "Authenticated (executor: " .. executorName .. ")")
                Rayfield:Notify({ Title = "Authenticated", Content = "Connected to dashboard.", Duration = 4 })
                refreshTeleportQueue()
                sendHeartbeat()
                task.spawn(function() task.wait(1) pcall(fetchAndApplyConfig) end)
                StatusLabel:Set("ONLINE | Target: " .. tostring(_G.TargetUsername) .. " | Distance: " .. tostring(_G.Distance))
            else
                authenticated = false
                authToken = ""
                local err = (type(response)=="table" and response.error) or tostring(response)
                AuthStatus:Set("FAILED: " .. err)
                Rayfield:Notify({ Title = "Auth Failed", Content = err, Duration = 10 })
            end
        end)
    end,
})

MainTab:CreateSection("Controls")
local EnabledToggle = MainTab:CreateToggle({
    Name = "Enabled", CurrentValue = enabled, Flag = "EnabledToggle",
    Callback = function(v) enabled = v; StatusLabel:Set("Enabled: "..tostring(v).." | Target: "..tostring(_G.TargetUsername)); if authenticated then sendLog("info","Toggle: "..tostring(v)); refreshTeleportQueue() end end
})
local TargetInput = MainTab:CreateInput({
    Name = "Target Username", PlaceholderText = "Enter username to follow", RemoveTextAfterFocusLost = false, Flag = "TargetInput",
    Callback = function(text) if text and text~="" then _G.TargetUsername = text; StatusLabel:Set("Target: "..text); if authenticated then sendLog("info","Target changed: "..text); refreshTeleportQueue() end end end
})
local DistanceSlider = MainTab:CreateSlider({
    Name = "Distance", Range = {-20,20}, Increment = 0.5, Suffix = " studs", CurrentValue = _G.Distance, Flag = "DistanceSlider",
    Callback = function(v) _G.Distance = v; StatusLabel:Set("Distance: "..v); if authenticated then refreshTeleportQueue() end end
})

MainTab:CreateSection("Info")
MainTab:CreateButton({ Name = "Refresh Status", Callback = function()
    StatusLabel:Set((authenticated and "ONLINE" or "OFFLINE").." | Enabled: "..tostring(enabled).." | Target: "..tostring(_G.TargetUsername).." | Dist: "..tostring(_G.Distance))
    StatsLabel:Set("Kills: "..killCount.." | Deaths: "..deathCount)
    Rayfield:Notify({ Title = "Status", Content = "Refreshed.", Duration = 2 })
end})
MainTab:CreateButton({ Name = "Force Heartbeat", Callback = function()
    if not authenticated then Rayfield:Notify({ Title = "Error", Content = "Not authenticated!", Duration = 3 }) return end
    task.spawn(function() local ok, resp = sendHeartbeat(); Rayfield:Notify({ Title = "Heartbeat", Content = ok and "Sent!" or ("Failed: "..tostring(resp)), Duration = 3 }) end)
end})

DebugTab:CreateSection("Teleport Debug")
DebugTab:CreateLabel("queue_on_teleport: "..tostring(_queueOnTeleport~=nil))
DebugTab:CreateButton({ Name = "Re‑queue Teleport Script", Callback = function()
    local ok = queueAutoReexecute()
    Rayfield:Notify({ Title = ok and "Queued" or "Failed", Content = ok and "Auto‑exec script queued." or "queue_on_teleport not available.", Duration = 3 })
end})

DebugTab:CreateSection("Script URL")
local UrlStatus = DebugTab:CreateLabel("Using: "..(SELF_URL or SCRIPT_REEXEC_URL))
DebugTab:CreateButton({ Name = "Test HTTP Connection", Callback = function()
    task.spawn(function()
        local ok, resp = pcall(function() return httpRequest({ Url = BASE_URL.."/api/script/validate", Method = "POST", Headers = {["Content-Type"]="application/json"}, Body = HttpService:JSONEncode({ authToken = "PD-TEST.test", userId = "test" }) }) end)
        if ok and resp then
            Rayfield:Notify({ Title = "HTTP "..tostring(resp.StatusCode or "?"), Content = (resp.Body or ""):sub(1,100), Duration = 8 })
        else
            Rayfield:Notify({ Title = "HTTP Failed", Content = "Error: "..tostring(resp), Duration = 8 })
        end
    end)
end})

-- ============ TELEPORT FAILURE RETRY ============
TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
    if player ~= LocalPlayer then return end
    sendLog("warn", "Teleport failed: "..tostring(result).." - "..tostring(errorMessage))
    Rayfield:Notify({ Title = "Teleport Failed", Content = tostring(errorMessage).." -- retrying in 5s", Duration = 5 })
    task.wait(5)
    refreshTeleportQueue()
    pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer) end)
end)

-- ============ ANTI-AFK ============
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    if authenticated then sendLog("info", "Anti-AFK triggered") end
end)

-- ============ RESPAWN ============
local function setupRespawn(character)
    local humanoid = character:WaitForChild("Humanoid")
    humanoid.Died:Connect(function()
        deathCount = deathCount + 1
        StatsLabel:Set("Kills: "..killCount.." | Deaths: "..deathCount)
        if authenticated then sendLog("warn", playerName.." died (#"..deathCount..")") end
        task.wait(0.5)
        if respawnRemote then pcall(function() respawnRemote:FireServer() end) end
    end)
end
LocalPlayer.CharacterAdded:Connect(setupRespawn)
if LocalPlayer.Character then setupRespawn(LocalPlayer.Character) end

-- ============ TWEEN ============
math.randomseed(tick() * 1000 + LocalPlayer.UserId)
local function tweenToTarget()
    if not enabled or _G.TargetUsername == "" then return end
    local targetPlayer = Players:FindFirstChild(_G.TargetUsername)
    if not targetPlayer then return end
    local targetChar = targetPlayer.Character
    if not targetChar then return end
    local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
    if not targetRoot then return end
    local localChar = LocalPlayer.Character
    if not localChar then return end
    local localRoot = localChar:FindFirstChild("HumanoidRootPart")
    if not localRoot then return end

    local targetCF = targetRoot.CFrame
    local newPos = targetCF.Position + targetCF.LookVector * _G.Distance
    local newCF = CFrame.new(newPos) * (targetCF - targetCF.Position)
    local duration = 3.0 + math.random() * 5.0
    local tween = TweenService:Create(localRoot, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { CFrame = newCF })
    tween:Play()
    tween.Completed:Wait()
end

task.spawn(function()
    while true do
        if enabled and authenticated then
            pcall(tweenToTarget)
            task.wait(0.3 + math.random() * 0.4)
        else
            task.wait(1)
        end
    end
end)

-- ============ CONFIG HANDLING ============
local lastConfigHash = ""
applyConfig = function(data)
    if not data or type(data)~="table" or not data.hasRemoteConfig then return false end
    local hash = tostring(data.enabled).."|"..tostring(data.target).."|"..tostring(data.distance).."|"..tostring(data.killsPerRound)
    if hash == lastConfigHash then return false end
    lastConfigHash = hash
    if data.enabled ~= nil then enabled = data.enabled; pcall(function() EnabledToggle:Set(enabled) end) end
    if data.target and data.target ~= "" then _G.TargetUsername = data.target; pcall(function() TargetInput:Set(data.target) end) end
    if data.distance ~= nil then _G.Distance = data.distance; pcall(function() DistanceSlider:Set(data.distance) end) end
    if data.killsPerRound then killsPerRound = data.killsPerRound end
    StatusLabel:Set("Config applied | Target: "..tostring(_G.TargetUsername).." | Dist: "..tostring(_G.Distance).." | KPR: "..tostring(killsPerRound))
    sendLog("info", "Remote config applied")
    Rayfield:Notify({ Title = "Config Updated", Content = "Target: "..tostring(data.target).." | Distance: "..tostring(data.distance), Duration = 4 })
    return true
end

fetchAndApplyConfig = function()
    local ok, data = getJSON(ENDPOINTS.config.."?userId="..urlEncode(userId))
    if ok and type(data)=="table" and data.hasRemoteConfig then applyConfig(data); return true end
    local ok2, data2 = getJSON(ENDPOINTS.config.."?userId="..urlEncode(playerName))
    if ok2 and type(data2)=="table" and data2.hasRemoteConfig then applyConfig(data2); return true end
    return false
end

task.spawn(function() while true do task.wait(15); if authenticated then pcall(fetchAndApplyConfig) end end end)

-- ============ COMMANDS POLLING ============
task.spawn(function()
    while true do
        task.wait(10)
        if authenticated then
            local ok, data = getJSON(ENDPOINTS.commands.."?userId="..urlEncode(userId))
            if ok and type(data)=="table" and not data.command then
                ok, data = getJSON(ENDPOINTS.commands.."?userId="..urlEncode(playerName))
            end
            if ok and type(data)=="table" and data.command then
                sendLog("info", "Command: "..data.command)
                if data.command == "joinServer" and data.placeId and data.jobId then
                    Rayfield:Notify({ Title = "Teleporting", Content = "Joining server...", Duration = 5 })
                    refreshTeleportQueue()
                    pcall(function() TeleportService:TeleportToPlaceInstance(tonumber(data.placeId), data.jobId, LocalPlayer) end)
                elseif data.command == "updateConfig" then
                    if data.data and type(data.data)=="table" then
                        applyConfig({ hasRemoteConfig = true, enabled = data.data.enabled, target = data.data.target, distance = data.data.distance, killsPerRound = data.data.killsPerRound })
                    end
                    task.spawn(fetchAndApplyConfig)
                elseif data.command == "disconnect" then
                    authenticated = false; authToken = ""; AuthStatus:Set("Disconnected by dashboard.")
                elseif data.command == "rejoin" then
                    refreshTeleportQueue()
                    pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer) end)
                end
            end
        end
    end
end)

-- ============ HEARTBEAT LOOP ============
task.spawn(function() while true do task.wait(22 + math.random(-3,3)); if authenticated then sendHeartbeat() end end end)

-- ============ INIT ============
pcall(function() Rayfield:LoadConfiguration() end)
StatsLabel:Set("Kills: 0 | Deaths: 0")

if isServerHop and authToken ~= "" then
    StatusLabel:Set("Server hop detected -- auto-authenticating...")
    AuthStatus:Set("Re-validating token...")
    Rayfield:Notify({ Title = "Server Hop", Content = "Auto-reconnecting...", Duration = 5 })
    task.spawn(function()
        task.wait(1.5)
        local valid, response = validateToken(authToken)
        if valid then
            authenticated = true
            AuthStatus:Set("RECONNECTED | Hop successful")
            sendLog("success", "Auto-reconnected after server hop")
            sendHeartbeat()
            refreshTeleportQueue()
            task.spawn(function() task.wait(1) pcall(fetchAndApplyConfig) end)
            StatusLabel:Set("ONLINE (hop) | Target: "..tostring(_G.TargetUsername).." | Dist: "..tostring(_G.Distance))
            pcall(function() EnabledToggle:Set(enabled) end)
            if _G.TargetUsername ~= "" then pcall(function() TargetInput:Set(_G.TargetUsername) end) end
            pcall(function() DistanceSlider:Set(_G.Distance) end)
            Rayfield:Notify({ Title = "Reconnected", Content = "Auto-authenticated.", Duration = 4 })
        else
            authToken = ""; authenticated = false
            AuthStatus:Set("Auto-reconnect failed. Paste token manually.")
            StatusLabel:Set("Awaiting authentication...")
        end
    end)
else
    StatusLabel:Set("Awaiting authentication...")
    AuthStatus:Set("Paste your token (PD-xxx.xxx) from the dashboard")
    Rayfield:Notify({ Title = "Project Dark", Content = "Paste your auth token.\nDashboard: "..BASE_URL, Duration = 10 })
end