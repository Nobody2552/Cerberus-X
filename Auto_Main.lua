wait(0.5)

local function safeLoadstring(code, chunkname)
    if type(code) ~= "string" then
        warn("Project Dark: loadstring received " .. type(code) .. ", expected string")
        return nil, "Code must be a string"
    end
    if code == "" then
        warn("Project Dark: loadstring received empty string")
        return nil, "Code is empty"
    end
    return loadstring(code, chunkname)
end

local function safeHttpGet(url)
    local success, result = pcall(function()
        return game:HttpGet(url)
    end)
    if not success then
        warn("Project Dark: game:HttpGet failed:", result)
        return nil
    end
    if type(result) ~= "string" or result == "" then
        warn("Project Dark: game:HttpGet returned empty result from", url)
        return nil
    end
    return result
end

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

local rayfieldCode = safeHttpGet("https://sirius.menu/rayfield")
local Rayfield
if rayfieldCode then
    local fn, err = safeLoadstring(rayfieldCode, "Rayfield")
    if fn then
        Rayfield = fn()
    else
        warn("Project Dark: Failed to load Rayfield:", err)
        Rayfield = {
            CreateWindow = function() return { CreateTab = function() return {} end, Notify = function() end } end,
            Notify = function() end,
            LoadConfiguration = function() end
        }
    end
else
    warn("Project Dark: Could not fetch Rayfield UI. Using dummy UI.")
    Rayfield = {
        CreateWindow = function() return { CreateTab = function() return {} end, Notify = function() end } end,
        Notify = function() end,
        LoadConfiguration = function() end
    }
end

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

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer
local respawnRemote = nil
pcall(function()
    respawnRemote = ReplicatedStorage:FindFirstChild("Remotes") 
        and ReplicatedStorage.Remotes:FindFirstChild("Duels") 
        and ReplicatedStorage.Remotes.Duels:FindFirstChild("RespawnNow")
end)

local queueOnTeleport = (syn and syn.queue_on_teleport)
    or queue_on_teleport
    or (fluxus and fluxus.queue_on_teleport)

local SCRIPT_REEXEC_URL = _G.__ProjectDark_ScriptURL or "https://raw.githubusercontent.com/Nobody2552/Cerberus-X/main/Auto_Main.lua"

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

_G.__ProjectDark_AuthToken = nil
_G.__ProjectDark_Target = nil
_G.__ProjectDark_Distance = nil
_G.__ProjectDark_Enabled = nil
_G.__ProjectDark_KillsPerRound = nil
_G.__ProjectDark_ScriptURL = nil

local function queueReExecute()
    if not queueOnTeleport then return end
    local script = string.format([[
        local code = game:HttpGet(%q)
        if type(code) == "string" and code ~= "" then
            local fn, err = loadstring(code)
            if fn then fn() else warn("Project Dark: loadstring error in new server:", err) end
        else
            warn("Project Dark: Failed to fetch script after teleport")
        end
    ]],
        SCRIPT_REEXEC_URL
    )
    local setup = string.format([[
        _G.__ProjectDark_AuthToken = %q
        _G.__ProjectDark_Target = %q
        _G.__ProjectDark_Distance = %s
        _G.__ProjectDark_Enabled = %s
        _G.__ProjectDark_KillsPerRound = %s
        _G.__ProjectDark_ScriptURL = %q
    ]],
        authToken or "",
        tostring(_G.TargetUsername or ""),
        tostring(_G.Distance or 0),
        tostring(enabled),
        tostring(killsPerRound),
        SCRIPT_REEXEC_URL
    )
    pcall(queueOnTeleport, setup .. "\ntask.wait(2)\n" .. script)
end

queueReExecute()

local function refreshReExecute()
    pcall(queueReExecute)
end

TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
    if player ~= LocalPlayer then return end
    sendLog("warn", "Teleport failed: " .. tostring(result) .. " - " .. tostring(errorMessage))
    Rayfield:Notify({
        Title = "Teleport Failed",
        Content = tostring(errorMessage) .. " -- retrying in 5s",
        Duration = 5,
    })
    task.wait(5)
    refreshReExecute()
    pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
    end)
end)

local BASE_URL = "https://v0-cerberusx.vercel.app/"
local ENDPOINTS = {
    validate  = BASE_URL .. "/api/script/validate",
    heartbeat = BASE_URL .. "/api/script/heartbeat",
    config    = BASE_URL .. "/api/script/config",
    log       = BASE_URL .. "/api/script/log",
    commands  = BASE_URL .. "/api/script/commands",
}

local userId = tostring(LocalPlayer.UserId)
local playerName = LocalPlayer.Name
local displayName = LocalPlayer.DisplayName
local jobId = game.JobId
local placeId = tostring(game.PlaceId)

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cleanToken(raw)
    if not raw then return "" end
    local t = raw
    t = t:gsub("%s+", "")
    t = t:gsub('"', "")
    t = t:gsub("'", "")
    t = t:gsub("\n", "")
    t = t:gsub("\r", "")
    t = t:gsub("\t", "")
    t = t:gsub("%z", "")
    return t
end

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
        refreshReExecute()
        return true, response
    end
    
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

local applyConfig
local fetchAndApplyConfig

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
            refreshReExecute()
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
                refreshReExecute()
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
            refreshReExecute()
        end
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

LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    if authenticated then
        sendLog("info", "Anti-AFK triggered")
    end
end)

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
    local tween = TweenService:Create(localRoot, TweenInfo.new(1, Enum.EasingStyle.Linear), { CFrame = newCF })
    tween:Play()
    tween.Completed:Wait()
end

task.spawn(function()
    while true do
        if enabled and authenticated then
            pcall(tweenToTarget)
        end
        task.wait(0.5)
    end
end)

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
    refreshReExecute()
    return true
end

fetchAndApplyConfig = function()
    local ok, data = getJSON(ENDPOINTS.config .. "?userId=" .. urlEncode(userId))
    if ok and type(data) == "table" and data.hasRemoteConfig then
        applyConfig(data)
        return true
    end
    local ok2, data2 = getJSON(ENDPOINTS.config .. "?userId=" .. urlEncode(playerName))
    if ok2 and type(data2) == "table" and data2.hasRemoteConfig then
        applyConfig(data2)
        return true
    end
    return false
end

task.spawn(function()
    while true do
        task.wait(15)
        if authenticated then
            pcall(fetchAndApplyConfig)
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(8)
        if authenticated then
            local ok, data = getJSON(ENDPOINTS.commands .. "?userId=" .. urlEncode(userId))
            
            if ok and type(data) == "table" and not data.command then
                ok, data = getJSON(ENDPOINTS.commands .. "?userId=" .. urlEncode(playerName))
            end
            
            if ok and type(data) == "table" and data.command then
                local cmd = data.command
                sendLog("info", "Received command: " .. cmd)
                
                if cmd == "joinServer" and data.placeId and data.jobId then
                    sendLog("info", "Joining server: " .. tostring(data.placeId) .. "/" .. tostring(data.jobId))
                    Rayfield:Notify({ Title = "Teleporting", Content = "Joining server...", Duration = 5 })
                    refreshReExecute()
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(tonumber(data.placeId), data.jobId, LocalPlayer)
                    end)
                    
                elseif cmd == "updateConfig" then
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
                    refreshReExecute()
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
                    end)
                end
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(15)
        if authenticated then
            sendHeartbeat()
        end
    end
end)

pcall(function() Rayfield:LoadConfiguration() end)
StatusLabel:Set("Awaiting authentication...")
StatsLabel:Set("Kills: " .. killCount .. " | Deaths: " .. deathCount)
AuthStatus:Set("Paste your token (PD-xxx.xxx) from the dashboard")
Rayfield:Notify({
    Title = "Project Dark",
    Content = "Paste your auth token to connect.\nDashboard: " .. BASE_URL,
    Duration = 10,
})