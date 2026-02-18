--[[ 
    Project Dark - Auto_Main.lua (Executor Edition)
    
    Uses executor-native HTTP (request/syn.request/http_request)
    instead of HttpService:PostAsync/GetAsync which are BLOCKED.
    
    Features:
    - HMAC-signed token auth via /api/script/validate
    - Remote server joining / teleport
    - Dashboard integration (heartbeat, config, commands, logs)
    - Anti-AFK, auto-respawn, tween-to-target
    - Full error diagnostics in Rayfield UI
]]--

wait(0.5)

-- ============ EXECUTOR HTTP COMPATIBILITY ============
-- Roblox blocks HttpService:PostAsync/GetAsync/UrlEncode in executors.
-- All modern executors provide one of these global functions instead.
local httpRequest = (syn and syn.request) 
    or (http and http.request) 
    or (fluxus and fluxus.request)
    or request 
    or http_request

if not httpRequest then
    -- Last-resort fallback: try to wrap HttpService (will fail in most executors)
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

-- ============ UI SETUP ============
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name = "Project Dark",
    Icon = 0,
    LoadingTitle = "Project Dark",
    LoadingSubtitle = "Initializing...",
    Theme = "Darker",
    ToggleUIKeybind = "K",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "ProjectDark",
        FileName = "Config"
    }
})

-- ============ SERVICES ============
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")  -- Only used for JSONEncode/JSONDecode (NOT blocked)
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer
local respawnRemote = nil
pcall(function()
    respawnRemote = ReplicatedStorage:FindFirstChild("Remotes") 
        and ReplicatedStorage.Remotes:FindFirstChild("Duels") 
        and ReplicatedStorage.Remotes.Duels:FindFirstChild("RespawnNow")
end)

-- ============ AUTO RE-EXECUTE ON SERVER HOP ============
-- Executors provide queue_on_teleport (or syn.queue_on_teleport) which queues
-- a script string to execute automatically when the player arrives in the new server.
local _queueOnTeleport = (syn and syn.queue_on_teleport)
    or queue_on_teleport
    or (fluxus and fluxus.queue_on_teleport)
    or nil

-- IMPORTANT: Replace this URL with your actual raw GitHub script URL
local SCRIPT_REEXEC_URL = "https://raw.githubusercontent.com/Nobody2552/Project-Dark/main/Auto_Main.lua"
-- If you set _G.__ProjectDark_ScriptURL before loading, it will override the fallback
local SELF_URL = _G.__ProjectDark_ScriptURL or nil

-- Build and queue the re‑execution script (preserves token and settings)
local function queueAutoReexecute()
    if not _queueOnTeleport then 
        warn("⚠️ queue_on_teleport not available – auto‑re‑execution disabled")
        return false 
    end
    
    -- Use SELF_URL if available, otherwise fallback to SCRIPT_REEXEC_URL
    local scriptUrl = SELF_URL or SCRIPT_REEXEC_URL
    
    -- Build the re‑exec script that sets globals before loading the main script
    local reexecScript = string.format([[
        -- Project Dark: Auto re‑execute after server hop
        _G.__ProjectDark_AuthToken = %q
        _G.__ProjectDark_Target = %q
        _G.__ProjectDark_Distance = %s
        _G.__ProjectDark_Enabled = %s
        _G.__ProjectDark_KillsPerRound = %s
        _G.__ProjectDark_ScriptURL = %q
        task.wait(2)
        loadstring(game:HttpGet(%q))()
    ]],
        authToken,
        tostring(_G.TargetUsername or ""),
        tostring(_G.Distance or 0),
        tostring(enabled),
        tostring(killsPerRound),
        scriptUrl,           -- store for next hop
        scriptUrl            -- load the script now
    )
    
    local success, err = pcall(function()
        _queueOnTeleport(reexecScript)
    end)
    if success then
        return true
    else
        warn("Failed to queue teleport script:", err)
        return false
    end
end

-- Queue immediately on script load so it's ready for the first teleport
queueAutoReexecute()

-- Re-queue whenever state changes (so the re‑exec payload has latest config)
local function refreshTeleportQueue()
    pcall(queueAutoReexecute)
end

-- ============ STATE ============
-- Restore state from previous server hop if available (set by queue_on_teleport)
local authToken = _G.__ProjectDark_AuthToken or ""
local authenticated = false
_G.TargetUsername = _G.__ProjectDark_Target or ""
_G.Distance = _G.__ProjectDark_Distance or 0
local enabled = true
if _G.__ProjectDark_Enabled ~= nil then
    enabled = _G.__ProjectDark_Enabled
end
local killCount = 0
local deathCount = 0
local killsPerRound = _G.__ProjectDark_KillsPerRound or 15
local isServerHop = (_G.__ProjectDark_AuthToken ~= nil and _G.__ProjectDark_AuthToken ~= "")

-- Clean up _G flags so they don't persist beyond this load
_G.__ProjectDark_AuthToken = nil
_G.__ProjectDark_Target = nil
_G.__ProjectDark_Distance = nil
_G.__ProjectDark_Enabled = nil
_G.__ProjectDark_KillsPerRound = nil

-- ============ DASHBOARD ENDPOINTS ============
-- IMPORTANT: Change this URL to your deployed dashboard URL
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

-- ============ STRING UTILITIES ============
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cleanToken(raw)
    if not raw then return "" end
    local t = raw
    t = t:gsub("%s+", "")   -- all whitespace
    t = t:gsub('"', "")     -- double quotes
    t = t:gsub("'", "")     -- single quotes
    t = t:gsub("\n", "")    -- newlines
    t = t:gsub("\r", "")    -- carriage returns
    t = t:gsub("\t", "")    -- tabs
    t = t:gsub("%z", "")    -- null bytes
    return t
end

-- Simple URL encoding (replaces blocked HttpService:UrlEncode)
local function urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

-- ============ HTTP LAYER (executor-native) ============
-- POST JSON to a URL, returns (success: bool, decoded: table|string)
local function postJSON(url, data)
    data.authToken = authToken  -- always inject the token
    
    local jsonBody = HttpService:JSONEncode(data)
    
    local ok, response = pcall(function()
        return httpRequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
                ["User-Agent"] = "ProjectDark/1.0",
                ["X-PD-Token"] = authToken,
            },
            Body = jsonBody,
        })
    end)
    
    if not ok then
        return false, "HTTP error: " .. tostring(response)
    end
    
    if not response then
        return false, "No response from server"
    end
    
    -- Executor request() returns { StatusCode, Body, Success, Headers }
    local statusCode = response.StatusCode or 0
    local body = response.Body or ""
    
    -- Try to decode JSON response
    local decodeOk, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    
    if statusCode >= 200 and statusCode < 300 then
        if decodeOk then
            return true, decoded
        end
        return true, body
    end
    
    -- Error response
    if decodeOk and decoded then
        return false, decoded
    end
    return false, "HTTP " .. tostring(statusCode) .. ": " .. body:sub(1, 200)
end

-- GET JSON from a URL, returns (success: bool, decoded: table|string)
local function getJSON(url)
    -- Append authToken as query parameter
    local separator = url:find("?") and "&" or "?"
    local finalUrl = url .. separator .. "authToken=" .. urlEncode(authToken)
    
    local ok, response = pcall(function()
        return httpRequest({
            Url = finalUrl,
            Method = "GET",
            Headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = "ProjectDark/1.0",
                ["X-PD-Token"] = authToken,
            },
        })
    end)
    
    if not ok then
        return false, "HTTP error: " .. tostring(response)
    end
    
    if not response then
        return false, "No response from server"
    end
    
    local statusCode = response.StatusCode or 0
    local body = response.Body or ""
    
    local decodeOk, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    
    if statusCode >= 200 and statusCode < 300 then
        if decodeOk then
            return true, decoded
        end
        return true, body
    end
    
    if decodeOk and decoded then
        return false, decoded
    end
    return false, "HTTP " .. tostring(statusCode) .. ": " .. body:sub(1, 200)
end

-- ============ LOG HELPER ============
local function sendLog(level, message)
    -- Fire and forget -- don't block on logging
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
            })
        end)
    end)
end

-- ============ HEARTBEAT ============
local function sendHeartbeat()
    local ok, response = postJSON(ENDPOINTS.heartbeat, {
        jobId = jobId,
        placeId = placeId,
        player = playerName,
        userId = userId,
        timestamp = os.time(),
        serverIp = jobId, -- use jobId as identifier
        serverPort = 0,
        kills = killCount,
        deaths = deathCount,
        scriptName = "Auto_Main.lua",
    })
    return ok, response
end

-- ============ TOKEN VALIDATION ============
local function validateToken(token)
    local cleanedToken = cleanToken(token)
    
    if cleanedToken == "" then
        return false, { error = "Empty token after cleaning" }
    end
    
    if not cleanedToken:match("^PD%-") then
        return false, { error = "Token must start with PD- (got: " .. cleanedToken:sub(1, 10) .. ")" }
    end
    
    if not cleanedToken:find("%.") then
        return false, { error = "Token missing HMAC signature (no dot). Copy the FULL token from the dashboard." }
    end
    
    -- Temporarily set authToken so postJSON includes it
    local previousToken = authToken
    authToken = cleanedToken
    
    local ok, response = postJSON(ENDPOINTS.validate, {
        userId = userId,
        player = playerName,
        displayName = displayName,
        placeId = placeId,
        jobId = jobId,
    })
    
    if ok and type(response) == "table" and response.valid == true then
        -- Keep the cleaned token (already set above)
        return true, response
    end
    
    -- Validation failed -- restore previous token
    authToken = previousToken
    
    local errMsg = "Server rejected token"
    if type(response) == "table" then
        if response.error then
            errMsg = response.error
        end
        if response.debug then
            errMsg = errMsg .. " [len=" .. tostring(response.debug.tokenLength or "?")
            errMsg = errMsg .. " hmac=" .. tostring(response.debug.hmacCheck)
            errMsg = errMsg .. " mem=" .. tostring(response.debug.memoryCheck) .. "]"
        end
    elseif type(response) == "string" then
        errMsg = response
    end
    
    return false, { error = errMsg }
end

-- ============ FORWARD DECLARATIONS ============
local applyConfig
local fetchAndApplyConfig

-- ============ UI TABS AND ELEMENTS ============
local MainTab = Window:CreateTab("Main", nil)
local DebugTab = Window:CreateTab("Debug", nil)  -- New debug tab

-- Status section (created first so auth callback can reference them)
MainTab:CreateSection("Status")
local StatusLabel = MainTab:CreateLabel("Waiting for authentication...")
local StatsLabel = MainTab:CreateLabel("Kills: 0 | Deaths: 0")

-- Auth section
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
        AuthStatus:Set("Validating: " .. cleaned:sub(1, 15) .. "...")
        
        task.spawn(function()
            local valid, response = validateToken(cleaned)
            
            if valid then
                authenticated = true
                local method = (type(response) == "table" and response.authMethod) or "hmac"
                AuthStatus:Set("CONNECTED via " .. method .. " | Server: " .. BASE_URL:gsub("https://", ""))
                sendLog("success", playerName .. " authenticated in place " .. placeId .. " (method: " .. method .. ")")
                Rayfield:Notify({
                    Title = "Authenticated",
                    Content = "Connected to Project Dark dashboard.",
                    Duration = 4,
                })
                -- Queue auto-reexec with the new valid token for server hops
                refreshTeleportQueue()
                -- First heartbeat + initial config fetch
                sendHeartbeat()
                task.spawn(function()
                    task.wait(1)
                    pcall(fetchAndApplyConfig)
                end)
                StatusLabel:Set("ONLINE | Target: " .. tostring(_G.TargetUsername) .. " | Distance: " .. tostring(_G.Distance))
            else
                authenticated = false
                authToken = ""
                local errDetail = "Unknown error"
                if type(response) == "table" and response.error then
                    errDetail = response.error
                elseif type(response) == "string" then
                    errDetail = response
                end
                AuthStatus:Set("FAILED: " .. errDetail)
                Rayfield:Notify({
                    Title = "Auth Failed",
                    Content = errDetail,
                    Duration = 10,
                })
            end
        end)
    end,
})

-- Controls section
MainTab:CreateSection("Controls")

local EnabledToggle = MainTab:CreateToggle({
    Name = "Enabled",
    CurrentValue = enabled,
    Flag = "EnabledToggle",
    Callback = function(v)
        enabled = v
        StatusLabel:Set("Enabled: " .. tostring(v) .. " | Target: " .. tostring(_G.TargetUsername))
        if authenticated then
            sendLog("info", "Toggle: " .. tostring(v))
            refreshTeleportQueue()   -- re‑queue with new state
        end
    end,
})

local TargetInput = MainTab:CreateInput({
    Name = "Target Username",
    PlaceholderText = "Enter username to follow",
    RemoveTextAfterFocusLost = false,
    Flag = "TargetInput",
    Callback = function(text)
        if text and text ~= "" then
            _G.TargetUsername = text
            StatusLabel:Set("Target: " .. text)
            if authenticated then
                sendLog("info", "Target changed: " .. text)
                refreshTeleportQueue()
            end
        end
    end,
})

local DistanceSlider = MainTab:CreateSlider({
    Name = "Distance",
    Range = {-20, 20},
    Increment = 0.5,
    Suffix = " studs",
    CurrentValue = _G.Distance,
    Flag = "DistanceSlider",
    Callback = function(v)
        _G.Distance = v
        StatusLabel:Set("Distance: " .. v)
        if authenticated then
            refreshTeleportQueue()
        end
    end,
})

-- Info section
MainTab:CreateSection("Info")

MainTab:CreateButton({
    Name = "Refresh Status",
    Callback = function()
        local authStr = authenticated and "ONLINE" or "OFFLINE"
        StatusLabel:Set(authStr .. " | Enabled: " .. tostring(enabled) .. " | Target: " .. tostring(_G.TargetUsername) .. " | Dist: " .. tostring(_G.Distance))
        StatsLabel:Set("Kills: " .. killCount .. " | Deaths: " .. deathCount)
        Rayfield:Notify({ Title = "Status", Content = "Refreshed.", Duration = 2 })
    end,
})

MainTab:CreateButton({
    Name = "Force Heartbeat",
    Callback = function()
        if not authenticated then
            Rayfield:Notify({ Title = "Error", Content = "Not authenticated!", Duration = 3 })
            return
        end
        task.spawn(function()
            local ok, resp = sendHeartbeat()
            local msg = ok and "Heartbeat sent!" or ("Heartbeat failed: " .. tostring(resp))
            Rayfield:Notify({ Title = "Heartbeat", Content = msg, Duration = 3 })
        end)
    end,
})

-- Debug tab
DebugTab:CreateSection("Teleport Debug")
local TeleportStatus = DebugTab:CreateLabel("queue_on_teleport: " .. tostring(_queueOnTeleport ~= nil))

DebugTab:CreateButton({
    Name = "Re‑queue Teleport Script",
    Callback = function()
        local ok = queueAutoReexecute()
        if ok then
            Rayfield:Notify({ Title = "Queued", Content = "Auto‑exec script queued for next teleport.", Duration = 3 })
        else
            Rayfield:Notify({ Title = "Failed", Content = "queue_on_teleport not available.", Duration = 5 })
        end
    end,
})

DebugTab:CreateSection("Script URL")
local UrlStatus = DebugTab:CreateLabel("Using: " .. (SELF_URL or SCRIPT_REEXEC_URL))
if not SELF_URL and SCRIPT_REEXEC_URL:find("YOUR_USER") then
    UrlStatus:Set("⚠️ WARNING: Script URL is still the placeholder! Replace it.")
end

DebugTab:CreateButton({
    Name = "Test HTTP Connection",
    Callback = function()
        Rayfield:Notify({ Title = "Testing...", Content = "Sending test request to server...", Duration = 2 })
        task.spawn(function()
            local ok, resp = pcall(function()
                return httpRequest({
                    Url = BASE_URL .. "/api/script/validate",
                    Method = "POST",
                    Headers = {
                        ["Content-Type"] = "application/json",
                        ["Accept"] = "application/json",
                    },
                    Body = HttpService:JSONEncode({ authToken = "PD-TEST.test", userId = "test" }),
                })
            end)
            if ok and resp then
                local status = resp.StatusCode or "?"
                local bodyPreview = (resp.Body or ""):sub(1, 100)
                Rayfield:Notify({
                    Title = "HTTP Result: " .. tostring(status),
                    Content = "Response: " .. bodyPreview,
                    Duration = 8,
                })
            else
                Rayfield:Notify({
                    Title = "HTTP Failed",
                    Content = "Error: " .. tostring(resp),
                    Duration = 8,
                })
            end
        end)
    end,
})

-- ============ TELEPORT FAILURE RETRY ============
-- If a teleport fails (server full, network error, etc.), automatically retry
TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
    if player ~= LocalPlayer then return end
    sendLog("warn", "Teleport failed: " .. tostring(result) .. " - " .. tostring(errorMessage))
    Rayfield:Notify({
        Title = "Teleport Failed",
        Content = tostring(errorMessage) .. " -- retrying in 5s",
        Duration = 5,
    })
    task.wait(5)
    -- Retry: re-queue and attempt again
    refreshTeleportQueue()
    pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
    end)
end)

-- ============ ANTI-AFK ============
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    if authenticated then
        sendLog("info", "Anti-AFK triggered")
    end
end)

-- ============ RESPAWN + DEATH TRACKING ============
local function setupRespawn(character)
    local humanoid = character:WaitForChild("Humanoid")
    humanoid.Died:Connect(function()
        deathCount = deathCount + 1
        StatsLabel:Set("Kills: " .. killCount .. " | Deaths: " .. deathCount)
        if authenticated then
            sendLog("warn", playerName .. " died (#" .. deathCount .. ")")
        end
        task.wait(0.5)
        if respawnRemote then
            pcall(function() respawnRemote:FireServer() end)
        end
    end)
end
LocalPlayer.CharacterAdded:Connect(setupRespawn)
if LocalPlayer.Character then setupRespawn(LocalPlayer.Character) end

-- ============ TWEEN TO TARGET ============
-- Randomized tween duration between 3-8 seconds per movement
-- Uses math.random seeded with tick() for better entropy
math.randomseed(tick() * 1000 + LocalPlayer.UserId)

local function randomTweenDuration()
    -- Returns a float between 3.0 and 8.0 (e.g. 4.72, 6.13, etc.)
    return 3.0 + (math.random() * 5.0)
end

local function tweenToTarget()
    if not enabled then return end
    if _G.TargetUsername == "" then return end
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

    local duration = randomTweenDuration()
    local tween = TweenService:Create(
        localRoot,
        TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
        { CFrame = newCF }
    )
    tween:Play()
    tween.Completed:Wait()
end

task.spawn(function()
    while true do
        if enabled and authenticated then
            pcall(tweenToTarget)
            -- Small buffer after tween completes before starting the next one
            task.wait(0.3 + math.random() * 0.4)
        else
            task.wait(1)
        end
    end
end)

-- ============ APPLY CONFIG HELPER ============
local lastConfigHash = ""
applyConfig = function(data)
    if not data or type(data) ~= "table" then return false end
    if not data.hasRemoteConfig then return false end
    
    -- Build a simple hash to avoid re-applying identical config
    local hash = tostring(data.enabled) .. "|" .. tostring(data.target) .. "|" .. tostring(data.distance) .. "|" .. tostring(data.killsPerRound)
    if hash == lastConfigHash then return false end
    lastConfigHash = hash
    
    if data.enabled ~= nil then
        enabled = data.enabled
        pcall(function() EnabledToggle:Set(enabled) end)
    end
    if data.target and data.target ~= "" then
        _G.TargetUsername = data.target
        pcall(function() TargetInput:Set(data.target) end)
    end
    if data.distance ~= nil then
        _G.Distance = data.distance
        pcall(function() DistanceSlider:Set(data.distance) end)
    end
    if data.killsPerRound then
        killsPerRound = data.killsPerRound
    end
    StatusLabel:Set("Config applied | Target: " .. tostring(_G.TargetUsername) .. " | Dist: " .. tostring(_G.Distance) .. " | KPR: " .. tostring(killsPerRound))
    sendLog("info", "Remote config applied: target=" .. tostring(data.target) .. " dist=" .. tostring(data.distance))
    Rayfield:Notify({
        Title = "Config Updated",
        Content = "Target: " .. tostring(data.target) .. " | Distance: " .. tostring(data.distance) .. " | KPR: " .. tostring(data.killsPerRound),
        Duration = 4,
    })
    return true
end

-- ============ FETCH CONFIG FROM SERVER ============
fetchAndApplyConfig = function()
    -- Try with numeric userId first (this is what the dashboard stores under)
    local ok, data = getJSON(ENDPOINTS.config .. "?userId=" .. urlEncode(userId))
    if ok and type(data) == "table" and data.hasRemoteConfig then
        applyConfig(data)
        return true
    end
    -- Fallback: try with username (dashboard also stores under username)
    local ok2, data2 = getJSON(ENDPOINTS.config .. "?userId=" .. urlEncode(playerName))
    if ok2 and type(data2) == "table" and data2.hasRemoteConfig then
        applyConfig(data2)
        return true
    end
    return false
end

-- ============ CONFIG POLLING (15s) ============
task.spawn(function()
    while true do
        task.wait(15)
        if authenticated then
            pcall(fetchAndApplyConfig)
        end
    end
end)

-- ============ COMMANDS POLLING (10s) ============
task.spawn(function()
    while true do
        task.wait(10)
        if authenticated then
            -- Poll commands with both userId (numeric) and playerName
            local ok, data = getJSON(ENDPOINTS.commands .. "?userId=" .. urlEncode(userId))
            
            -- If no command found under numeric userId, try by username
            if ok and type(data) == "table" and not data.command then
                ok, data = getJSON(ENDPOINTS.commands .. "?userId=" .. urlEncode(playerName))
            end
            
            if ok and type(data) == "table" and data.command then
                local cmd = data.command
                sendLog("info", "Received command: " .. cmd)
                
                if cmd == "joinServer" and data.placeId and data.jobId then
                    sendLog("info", "Joining server: " .. tostring(data.placeId) .. "/" .. tostring(data.jobId))
                    Rayfield:Notify({ Title = "Teleporting", Content = "Joining server...", Duration = 5 })
                    refreshTeleportQueue() -- ensure auto-reexec is queued with latest state
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(tonumber(data.placeId), data.jobId, LocalPlayer)
                    end)
                    
                elseif cmd == "updateConfig" then
                    -- First try to apply inline data from the command itself
                    local inlineData = data.data
                    if inlineData and type(inlineData) == "table" then
                        -- The dashboard sends the config values directly in the command data
                        local configPayload = {
                            hasRemoteConfig = true,
                            enabled = inlineData.enabled,
                            target = inlineData.target,
                            distance = inlineData.distance,
                            killsPerRound = inlineData.killsPerRound,
                        }
                        applyConfig(configPayload)
                    end
                    -- Also fetch from config endpoint as backup/confirmation
                    task.spawn(fetchAndApplyConfig)
                    
                elseif cmd == "disconnect" then
                    sendLog("info", "Disconnected by dashboard")
                    Rayfield:Notify({ Title = "Disconnected", Content = "Dashboard sent disconnect.", Duration = 5 })
                    authenticated = false
                    authToken = ""
                    AuthStatus:Set("Disconnected by dashboard. Re-enter token to reconnect.")
                    
                elseif cmd == "rejoin" then
                    sendLog("info", "Rejoining server")
                    Rayfield:Notify({ Title = "Rejoining", Content = "Teleporting...", Duration = 3 })
                    refreshTeleportQueue()
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
                    end)
                end
            end
        end
    end
end)

-- ============ HEARTBEAT LOOP (randomized ~22s) ============
task.spawn(function()
    while true do
        task.wait(22 + math.random(-3, 3))  -- slight randomization
        if authenticated then
            sendHeartbeat()
        end
    end
end)

-- ============ INIT ============
pcall(function() Rayfield:LoadConfiguration() end)
StatsLabel:Set("Kills: " .. killCount .. " | Deaths: " .. deathCount)

if isServerHop and authToken ~= "" then
    -- AUTO-AUTHENTICATE: We arrived from a server hop with a saved token
    StatusLabel:Set("Server hop detected -- auto-authenticating...")
    AuthStatus:Set("Re-validating token from previous server...")
    Rayfield:Notify({
        Title = "Server Hop",
        Content = "Auto-reconnecting to dashboard...",
        Duration = 5,
    })
    task.spawn(function()
        task.wait(1.5) -- let the new server settle
        local valid, response = validateToken(authToken)
        if valid then
            authenticated = true
            local method = (type(response) == "table" and response.authMethod) or "hmac"
            AuthStatus:Set("RECONNECTED via " .. method .. " | Hop successful")
            sendLog("success", playerName .. " auto-reconnected after server hop (place " .. placeId .. ")")
            sendHeartbeat()
            -- Refresh the teleport queue with current state for the next hop
            refreshTeleportQueue()
            -- Apply any config updates
            task.spawn(function()
                task.wait(1)
                pcall(fetchAndApplyConfig)
            end)
            StatusLabel:Set("ONLINE (hop) | Target: " .. tostring(_G.TargetUsername) .. " | Dist: " .. tostring(_G.Distance))
            -- Restore UI elements to match carried state
            pcall(function() EnabledToggle:Set(enabled) end)
            if _G.TargetUsername ~= "" then
                pcall(function() TargetInput:Set(_G.TargetUsername) end)
            end
            pcall(function() DistanceSlider:Set(_G.Distance) end)
            Rayfield:Notify({
                Title = "Reconnected",
                Content = "Auto-authenticated after server hop. All systems online.",
                Duration = 4,
            })
        else
            -- Auto-auth failed, fall back to manual
            authToken = ""
            authenticated = false
            AuthStatus:Set("Auto-reconnect failed. Paste token manually.")
            StatusLabel:Set("Awaiting authentication...")
            Rayfield:Notify({
                Title = "Reconnect Failed",
                Content = "Token expired or invalid. Please paste a new token.",
                Duration = 8,
            })
        end
    end)
else
    -- Normal startup (no server hop)
    StatusLabel:Set("Awaiting authentication...")
    AuthStatus:Set("Paste your token (PD-xxx.xxx) from the dashboard")
    Rayfield:Notify({
        Title = "Project Dark",
        Content = "Paste your auth token to connect.\nDashboard: " .. BASE_URL,
        Duration = 10,
    })
end