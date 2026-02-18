--[[ 
    Project Dark - Auto_Main.lua (Xeno / Executor Edition)
    
    Uses executor-native HTTP (request/syn.request/http_request)
    instead of HttpService:PostAsync/GetAsync which are BLOCKED.
    Xeno: game:HttpGet is unblocked natively and used for Rayfield.
    
    Features:
    - HMAC-signed token auth via /api/script/validate
    - Remote config push/poll with dual userId + username lookup
    - Instant config via updateConfig command with inline data
    - Remote server joining / teleport commands
    - Auto re-execute after server hop (queue_on_teleport)
    - Auto-reconnect with carried auth token on hop
    - Anti-AFK, auto-respawn, randomized tween-to-target (3-8s)
    - Teleport failure retry
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
-- game:HttpGet works natively in Xeno and most executors
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

-- ============ STATE ============
-- Restore state from a previous server hop if _G flags were set by queue_on_teleport
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

-- Clean up _G hop flags so they don't persist
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
    
    if not ok then return false, "HTTP error: " .. tostring(response) end
    if not response then return false, "No response from server" end
    
    local statusCode = response.StatusCode or 0
    local body = response.Body or ""
    
    local decodeOk, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    
    if statusCode >= 200 and statusCode < 300 then
        if decodeOk then return true, decoded end
        return true, body
    end
    
    if decodeOk and decoded then return false, decoded end
    return false, "HTTP " .. tostring(statusCode) .. ": " .. body:sub(1, 200)
end

local function getJSON(url)
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
    
    if not ok then return false, "HTTP error: " .. tostring(response) end
    if not response then return false, "No response from server" end
    
    local statusCode = response.StatusCode or 0
    local body = response.Body or ""
    
    local decodeOk, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    
    if statusCode >= 200 and statusCode < 300 then
        if decodeOk then return true, decoded end
        return true, body
    end
    
    if decodeOk and decoded then return false, decoded end
    return false, "HTTP " .. tostring(statusCode) .. ": " .. body:sub(1, 200)
end

-- ============ LOG HELPER ============
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
        serverIp = jobId,
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
        return false, { error = "Token missing HMAC signature (no dot). Copy the FULL token." }
    end
    
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
        return true, response
    end
    
    authToken = previousToken
    
    local errMsg = "Server rejected token"
    if type(response) == "table" then
        if response.error then errMsg = response.error end
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

-- ============ AUTO RE-EXECUTE ON SERVER HOP ============
-- queue_on_teleport queues a script string to run after teleport completes.
local _queueOnTeleport = nil
pcall(function() if syn and syn.queue_on_teleport then _queueOnTeleport = syn.queue_on_teleport end end)
if not _queueOnTeleport then pcall(function() if queue_on_teleport then _queueOnTeleport = queue_on_teleport end end) end
if not _queueOnTeleport then pcall(function() if fluxus and fluxus.queue_on_teleport then _queueOnTeleport = fluxus.queue_on_teleport end end) end

local SELF_URL = _G.__ProjectDark_ScriptURL or nil

local function queueAutoReexecute()
    if not _queueOnTeleport then return false end
    
    local scriptUrl = SELF_URL or (BASE_URL .. "/scripts/Auto_Main.lua")
    
    -- The queued script uses game:HttpGet which works in Xeno and most executors.
    -- It sets _G flags to carry state, then loads the main script fresh.
    local reexecScript = string.format([[
        _G.__ProjectDark_AuthToken = %q
        _G.__ProjectDark_Target = %q
        _G.__ProjectDark_Distance = %s
        _G.__ProjectDark_Enabled = %s
        _G.__ProjectDark_KillsPerRound = %s
        _G.__ProjectDark_ScriptURL = %q
        task.wait(2)
        loadstring(game:HttpGet(%q))()
    ]],
        authToken or "",
        tostring(_G.TargetUsername or ""),
        tostring(_G.Distance or 0),
        tostring(enabled),
        tostring(killsPerRound),
        scriptUrl,
        scriptUrl
    )
    
    pcall(function() _queueOnTeleport(reexecScript) end)
    return true
end

-- Queue on first load so it's ready for the first teleport
queueAutoReexecute()

local function refreshTeleportQueue()
    pcall(queueAutoReexecute)
end

-- ============ FORWARD DECLARATIONS ============
local applyConfig
local fetchAndApplyConfig

-- ============ UI TABS AND ELEMENTS ============
local MainTab = Window:CreateTab("Main", nil)

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
                -- Queue reexec with fresh token
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
            refreshTeleportQueue()
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
        if authenticated then refreshTeleportQueue() end
    end,
})

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

MainTab:CreateButton({
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
TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
    if player ~= LocalPlayer then return end
    sendLog("warn", "Teleport failed: " .. tostring(result) .. " - " .. tostring(errorMessage))
    Rayfield:Notify({
        Title = "Teleport Failed",
        Content = tostring(errorMessage) .. " -- retrying in 5s",
        Duration = 5,
    })
    task.wait(5)
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

-- ============ TWEEN TO TARGET (Randomized 3-8s) ============
math.randomseed(tick() * 1000 + LocalPlayer.UserId)

local function randomTweenDuration()
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
    refreshTeleportQueue()
    return true
end

-- ============ FETCH CONFIG FROM SERVER ============
fetchAndApplyConfig = function()
    -- Try with numeric userId first (dashboard stores config under robloxUserId)
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
            -- Poll commands with numeric userId first
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
                    refreshTeleportQueue()
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(tonumber(data.placeId), data.jobId, LocalPlayer)
                    end)
                    
                elseif cmd == "updateConfig" then
                    -- Apply inline data from command (instant, no extra fetch needed)
                    local inlineData = data.data
                    if inlineData and type(inlineData) == "table" then
                        local configPayload = {
                            hasRemoteConfig = true,
                            enabled = inlineData.enabled,
                            target = inlineData.target,
                            distance = inlineData.distance,
                            killsPerRound = inlineData.killsPerRound,
                        }
                        applyConfig(configPayload)
                    end
                    -- Also fetch from config endpoint as backup confirmation
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

-- ============ HEARTBEAT LOOP (~22s) ============
task.spawn(function()
    while true do
        task.wait(22)
        if authenticated then
            sendHeartbeat()
        end
    end
end)

-- ============ INIT ============
pcall(function() Rayfield:LoadConfiguration() end)
StatsLabel:Set("Kills: " .. killCount .. " | Deaths: " .. deathCount)

if isServerHop and authToken ~= "" then
    -- AUTO-AUTHENTICATE after server hop with carried token
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
            refreshTeleportQueue()
            task.spawn(function()
                task.wait(1)
                pcall(fetchAndApplyConfig)
            end)
            StatusLabel:Set("ONLINE (hop) | Target: " .. tostring(_G.TargetUsername) .. " | Dist: " .. tostring(_G.Distance))
            -- Restore UI to match carried state
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
            -- Token expired or invalid, fall back to manual auth
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
