--[[
    Roblox AIM-ассист + Movement (Fly/Noclip) + Rayfield GUI
    Версия: 3.0 (Final)
    Предупреждение: Только для образовательных целей в изолированной среде.
]]

-- СЕРВИСЫ
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local aimingActive = false

-- НАСТРОЙКИ (сохраняются через Rayfield)
local Settings = {
    AIM_KEY = Enum.UserInputType.MouseButton2,
    SENSITIVITY = 0.3,
    MAX_ANGLE = math.rad(2),
    RADIUS = 100,
    IGNORE_WALLS = true,
    TEAM_CHECK = true,
    HIGHLIGHT_ENABLED = true,
    HIGHLIGHT_MODE = "TeamColor",      -- "Fixed" или "TeamColor"
    HIGHLIGHT_COLOR = Color3.new(1, 0, 0),
    HIGHLIGHT_FILL_TRANSPARENCY = 1,
    HIGHLIGHT_OUTLINE_TRANSPARENCY = 0,
    AIM_ASSIST_ENABLED = true,
    -- Movement
    NOCLIP_ENABLED = false,
    FLY_ENABLED = false,
    FLY_SPEED = 50,
    FLY_ACCELERATION = 15,   -- ускорение (ед./сек²)
    FLY_DRAG = 8,            -- замедление
    WALK_SPEED = 16,
    JUMP_POWER = 50,
}

-- Хранилище Highlight
local highlightMap = {}

-- RaycastParams (переиспользуемый)
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

-- Переменные для полёта (инерция)
local flyBodyGyro = nil
local flyBodyVelocity = nil
local flyConnection = nil
local isFlying = false
local currentHumanoid = nil
local diedConnection = nil
local currentFlyVelocity = Vector3.new(0, 0, 0)
local desiredFlyVelocity = Vector3.new(0, 0, 0)

-- Переменная для noclip
local noclipConnection = nil

-- =====================================================
--                      ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- =====================================================

local function IsEnemy(player)
    if player == localPlayer then return false end
    if not Settings.TEAM_CHECK then return true end
    local localTeam = localPlayer.Team
    local targetTeam = player.Team
    if not localTeam or not targetTeam then return true end
    return localTeam ~= targetTeam
end

local function GetHead(character)
    return character and character:FindFirstChild("Head")
end

local function IsVisible(cameraPos, targetHead, localChar, targetChar)
    if not Settings.IGNORE_WALLS then return true end
    if not localChar or not targetChar then return false end

    local direction = (targetHead.Position - cameraPos).Unit
    local distance = (targetHead.Position - cameraPos).Magnitude
    
    raycastParams.FilterDescendantsInstances = {localChar, targetChar}
    
    local result = Workspace:Raycast(cameraPos, direction * distance, raycastParams)
    if not result then return true end
    
    local hitModel = result.Instance:FindFirstAncestorWhichIsA("Model")
    return hitModel == targetChar
end

local function GetHighlightColorForPlayer(player)
    if Settings.HIGHLIGHT_MODE == "Fixed" then
        return Settings.HIGHLIGHT_COLOR
    else
        local team = player.Team
        if team and team.TeamColor then
            return team.TeamColor.Color
        else
            return Color3.new(0.5, 0.5, 0.5)
        end
    end
end

local function UpdateHighlightForPlayer(player)
    if not Settings.HIGHLIGHT_ENABLED then
        local existing = highlightMap[player]
        if existing then
            existing:Destroy()
            highlightMap[player] = nil
        end
        return
    end
    
    local character = player.Character
    local shouldHave = IsEnemy(player) and character ~= nil
    
    local existing = highlightMap[player]
    if shouldHave and not existing then
        local highlight = Instance.new("Highlight")
        highlight.Name = "AimAssistHighlight"
        local color = GetHighlightColorForPlayer(player)
        highlight.FillColor = color
        highlight.OutlineColor = color
        highlight.FillTransparency = Settings.HIGHLIGHT_FILL_TRANSPARENCY
        highlight.OutlineTransparency = Settings.HIGHLIGHT_OUTLINE_TRANSPARENCY
        highlight.Parent = character
        highlightMap[player] = highlight
    elseif not shouldHave and existing then
        existing:Destroy()
        highlightMap[player] = nil
    elseif shouldHave and existing and existing.Parent ~= character then
        existing.Parent = character
        local color = GetHighlightColorForPlayer(player)
        existing.FillColor = color
        existing.OutlineColor = color
        existing.FillTransparency = Settings.HIGHLIGHT_FILL_TRANSPARENCY
        existing.OutlineTransparency = Settings.HIGHLIGHT_OUTLINE_TRANSPARENCY
    elseif shouldHave and existing then
        local color = GetHighlightColorForPlayer(player)
        existing.FillColor = color
        existing.OutlineColor = color
        existing.FillTransparency = Settings.HIGHLIGHT_FILL_TRANSPARENCY
        existing.OutlineTransparency = Settings.HIGHLIGHT_OUTLINE_TRANSPARENCY
    end
end

local function RefreshAllHighlights()
    for _, player in pairs(Players:GetPlayers()) do
        UpdateHighlightForPlayer(player)
    end
end

local function OnCharacterAdded(player, character)
    task.wait(0.1)
    UpdateHighlightForPlayer(player)
end

local function OnPlayerRemoving(player)
    local highlight = highlightMap[player]
    if highlight then
        highlight:Destroy()
        highlightMap[player] = nil
    end
end

local function OnTeamChanged(player)
    UpdateHighlightForPlayer(player)
end

-- =====================================================
--                      MOVEMENT: NOCLIP
-- =====================================================

local function SetNoclip(enabled)
    if enabled then
        if noclipConnection then noclipConnection:Disconnect() end
        noclipConnection = RunService.Stepped:Connect(function()
            local char = localPlayer.Character
            if char then
                for _, part in pairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end
        end)
    else
        if noclipConnection then
            noclipConnection:Disconnect()
            noclipConnection = nil
        end
        local char = localPlayer.Character
        if char then
            for _, part in pairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = true
                end
            end
        end
    end
end

-- =====================================================
--                      MOVEMENT: FLY (GMOD STYLE)
-- =====================================================

local function StopFly()
    if not isFlying then return end
    isFlying = false
    
    if flyConnection then
        flyConnection:Disconnect()
        flyConnection = nil
    end
    
    if flyBodyGyro then
        flyBodyGyro:Destroy()
        flyBodyGyro = nil
    end
    
    if flyBodyVelocity then
        flyBodyVelocity:Destroy()
        flyBodyVelocity = nil
    end
    
    if currentHumanoid and diedConnection then
        diedConnection:Disconnect()
        diedConnection = nil
    end
    
    local char = localPlayer.Character
    if char then
        local humanoid = char:FindFirstChild("Humanoid")
        if humanoid then
            humanoid.PlatformStand = false
        end
    end
    
    currentHumanoid = nil
    currentFlyVelocity = Vector3.new(0, 0, 0)
    desiredFlyVelocity = Vector3.new(0, 0, 0)
end

local function StartFly()
    if isFlying then return end
    
    local char = localPlayer.Character
    if not char then return end
    
    local humanoid = char:FindFirstChild("Humanoid")
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not humanoid or not rootPart then return end
    
    StopFly() -- очистка
    
    humanoid.PlatformStand = true
    currentHumanoid = humanoid
    
    diedConnection = humanoid.Died:Connect(function()
        StopFly()
        Settings.FLY_ENABLED = false
        -- Обновить состояние переключателя в GUI (Rayfield сам не обновит, но настройка сброшена)
    end)
    
    flyBodyGyro = Instance.new("BodyGyro")
    flyBodyGyro.MaxTorque = Vector3.new(1, 1, 1) * 1e6
    flyBodyGyro.P = 1e4
    flyBodyGyro.CFrame = rootPart.CFrame
    flyBodyGyro.Parent = rootPart
    
    flyBodyVelocity = Instance.new("BodyVelocity")
    flyBodyVelocity.MaxForce = Vector3.new(1, 1, 1) * 1e6
    flyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
    flyBodyVelocity.Parent = rootPart
    
    isFlying = true
    currentFlyVelocity = Vector3.new(0, 0, 0)
    desiredFlyVelocity = Vector3.new(0, 0, 0)
    
    flyConnection = RunService.RenderStepped:Connect(function(deltaTime)
        if not isFlying then return end
        
        local currentChar = localPlayer.Character
        if not currentChar then
            StopFly()
            return
        end
        
        local currentRoot = currentChar:FindFirstChild("HumanoidRootPart")
        local currentHumanoidCheck = currentChar:FindFirstChild("Humanoid")
        if not currentRoot or not currentHumanoidCheck then
            StopFly()
            return
        end
        
        -- Обновляем гироскоп
        if flyBodyGyro and flyBodyGyro.Parent then
            flyBodyGyro.CFrame = CFrame.new(currentRoot.Position, currentRoot.Position + camera.CFrame.LookVector * 100)
        end
        
        -- Вычисляем желаемую скорость на основе ввода
        local moveDir = Vector3.new(0, 0, 0)
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then
            moveDir = moveDir + camera.CFrame.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then
            moveDir = moveDir - camera.CFrame.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then
            moveDir = moveDir - camera.CFrame.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then
            moveDir = moveDir + camera.CFrame.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then
            moveDir = moveDir + Vector3.new(0, 1, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
            moveDir = moveDir - Vector3.new(0, 1, 0)
        end
        
        if moveDir.Magnitude > 0 then
            desiredFlyVelocity = moveDir.Unit * Settings.FLY_SPEED
        else
            desiredFlyVelocity = Vector3.new(0, 0, 0)
        end
        
        -- Плавное изменение текущей скорости (инерция)
        local dt = deltaTime or 1/60
        if desiredFlyVelocity.Magnitude > 0 then
            local step = Settings.FLY_ACCELERATION * dt
            currentFlyVelocity = currentFlyVelocity:Lerp(desiredFlyVelocity, step)
        else
            local step = Settings.FLY_DRAG * dt
            currentFlyVelocity = currentFlyVelocity:Lerp(Vector3.new(0, 0, 0), step)
        end
        
        -- Применяем скорость
        if flyBodyVelocity and flyBodyVelocity.Parent then
            flyBodyVelocity.Velocity = currentFlyVelocity
        end
    end)
end

local function SetFly(enabled)
    if enabled then
        StartFly()
    else
        StopFly()
    end
    Settings.FLY_ENABLED = enabled
end

-- =====================================================
--                      ОБРАБОТКА ЛОКАЛЬНОГО ПЕРСОНАЖА
-- =====================================================

local function ApplyMovementSettings(character)
    local humanoid = character:FindFirstChild("Humanoid")
    if humanoid then
        humanoid.WalkSpeed = Settings.WALK_SPEED
        humanoid.JumpPower = Settings.JUMP_POWER
    end
end

local function OnLocalCharacterAdded(character)
    task.wait(0.2)
    ApplyMovementSettings(character)
    -- Сброс скорости полёта при респавне
    currentFlyVelocity = Vector3.new(0, 0, 0)
    desiredFlyVelocity = Vector3.new(0, 0, 0)
    if Settings.FLY_ENABLED then
        StopFly()
        StartFly()
    end
    if Settings.NOCLIP_ENABLED then
        SetNoclip(true)
    end
end

-- =====================================================
--                      ЯДРО AIM-АССИСТА
-- =====================================================

local function FindBestTarget()
    if not Settings.AIM_ASSIST_ENABLED then return nil, nil end
    
    local bestDistance = Settings.RADIUS + 1
    local bestPlayer = nil
    local bestHeadPos = nil
    
    local mousePos = UserInputService:GetMouseLocation()
    local cameraPos = camera.CFrame.Position
    local localChar = localPlayer.Character
    
    for _, player in pairs(Players:GetPlayers()) do
        if player == localPlayer then continue end
        if not IsEnemy(player) then continue end
        
        local character = player.Character
        if not character then continue end
        
        local humanoid = character:FindFirstChild("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end
        
        local head = GetHead(character)
        if not head then continue end
        
        local screenPos, onScreen = camera:WorldToViewportPoint(head.Position)
        if not onScreen then continue end
        
        local deltaX = screenPos.X - mousePos.X
        local deltaY = screenPos.Y - mousePos.Y
        local distance = math.sqrt(deltaX * deltaX + deltaY * deltaY)
        
        if distance < bestDistance and distance <= Settings.RADIUS then
            if Settings.IGNORE_WALLS then
                if not IsVisible(cameraPos, head, localChar, character) then
                    continue
                end
            end
            bestDistance = distance
            bestPlayer = player
            bestHeadPos = head
        end
    end
    
    return bestPlayer, bestHeadPos
end

local function ScreenDeltaToAngles(deltaX, deltaY)
    local fov = math.rad(camera.FieldOfView)
    local screenHeight = camera.ViewportSize.Y
    local angleY = (deltaY / screenHeight) * fov
    local screenWidth = camera.ViewportSize.X
    local aspect = screenWidth / screenHeight
    local angleX = (deltaX / screenWidth) * (fov * aspect)
    return angleX, angleY
end

local function RotateCameraToTarget(targetHead)
    if not targetHead then return end
    
    local mousePos = UserInputService:GetMouseLocation()
    local headScreenPos = camera:WorldToViewportPoint(targetHead.Position)
    
    local deltaX = headScreenPos.X - mousePos.X
    local deltaY = headScreenPos.Y - mousePos.Y
    
    local angleX, angleY = ScreenDeltaToAngles(deltaX, deltaY)
    
    angleX = angleX * Settings.SENSITIVITY
    angleY = angleY * Settings.SENSITIVITY
    
    angleX = math.clamp(angleX, -Settings.MAX_ANGLE, Settings.MAX_ANGLE)
    angleY = math.clamp(angleY, -Settings.MAX_ANGLE, Settings.MAX_ANGLE)
    
    local newCFrame = camera.CFrame
    newCFrame = newCFrame * CFrame.Angles(0, -angleX, 0)
    newCFrame = newCFrame * CFrame.Angles(-angleY, 0, 0)
    camera.CFrame = newCFrame
end

local function OnRenderStep()
    if not aimingActive then return end
    if not Settings.AIM_ASSIST_ENABLED then return end
    
    local bestPlayer, bestHead = FindBestTarget()
    if bestPlayer and bestHead then
        RotateCameraToTarget(bestHead)
    end
end

-- =====================================================
--                      RAYFIELD GUI
-- =====================================================

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "AIM Almihush v3",
    LoadingTitle = "AIM + ESP",
    LoadingSubtitle = "Universal",
    Theme = "Dark",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "AimAssistFinal",
        FileName = "Config"
    },
    KeySystem = false,
})

local MainTab = Window:CreateTab("AIM", nil)
local VisualsTab = Window:CreateTab("ESP", nil)
local MovementTab = Window:CreateTab("Movement", nil)

-- Основные настройки
MainTab:CreateToggle({
    Name = "Включить AIM",
    CurrentValue = Settings.AIM_ASSIST_ENABLED,
    Flag = "AimEnable",
    Callback = function(Value)
        Settings.AIM_ASSIST_ENABLED = Value
    end
})

MainTab:CreateSlider({
    Name = "Радиус прицеливания (пиксели)",
    Range = {0, 500},
    Increment = 5,
    Suffix = "px",
    CurrentValue = Settings.RADIUS,
    Flag = "Radius",
    Callback = function(Value)
        Settings.RADIUS = Value
    end
})

MainTab:CreateSlider({
    Name = "Чувствительность (сила притяжения)",
    Range = {0, 1},
    Increment = 0.05,
    Suffix = "",
    CurrentValue = Settings.SENSITIVITY,
    Flag = "Sensitivity",
    Callback = function(Value)
        Settings.SENSITIVITY = Value
    end
})

MainTab:CreateSlider({
    Name = "Макс. угол за кадр (градусы)",
    Range = {0, 10},
    Increment = 0.5,
    Suffix = "°",
    CurrentValue = math.deg(Settings.MAX_ANGLE),
    Flag = "MaxAngle",
    Callback = function(Value)
        Settings.MAX_ANGLE = math.rad(Value)
    end
})

MainTab:CreateToggle({
    Name = "Wall Check",
    CurrentValue = Settings.IGNORE_WALLS,
    Flag = "IgnoreWalls",
    Callback = function(Value)
        Settings.IGNORE_WALLS = Value
    end
})

MainTab:CreateToggle({
    Name = "Team Check",
    CurrentValue = Settings.TEAM_CHECK,
    Flag = "TeamCheck",
    Callback = function(Value)
        Settings.TEAM_CHECK = Value
        RefreshAllHighlights()
    end
})

-- Визуальные настройки
VisualsTab:CreateToggle({
    Name = "ESP",
    CurrentValue = Settings.HIGHLIGHT_ENABLED,
    Flag = "HighlightEnable",
    Callback = function(Value)
        Settings.HIGHLIGHT_ENABLED = Value
        RefreshAllHighlights()
    end
})

VisualsTab:CreateDropdown({
    Name = "Mode",
    Options = {"Фиксированный цвет", "Цвет команды"},
    CurrentOption = (Settings.HIGHLIGHT_MODE == "Fixed") and "Фиксированный цвет" or "Цвет команды",
    Flag = "HighlightMode",
    Callback = function(Option)
        if Option == "Фиксированный цвет" then
            Settings.HIGHLIGHT_MODE = "Fixed"
        else
            Settings.HIGHLIGHT_MODE = "TeamColor"
        end
        RefreshAllHighlights()
    end
})

VisualsTab:CreateColorPicker({
    Name = "Фиксированный цвет обводки",
    Color = Settings.HIGHLIGHT_COLOR,
    Flag = "HighlightColor",
    Callback = function(Value)
        Settings.HIGHLIGHT_COLOR = Value
        if Settings.HIGHLIGHT_MODE == "Fixed" then
            RefreshAllHighlights()
        end
    end
})

VisualsTab:CreateSlider({
    Name = "Прозрачность заливки",
    Range = {0, 1},
    Increment = 0.05,
    Suffix = "",
    CurrentValue = Settings.HIGHLIGHT_FILL_TRANSPARENCY,
    Flag = "FillTrans",
    Callback = function(Value)
        Settings.HIGHLIGHT_FILL_TRANSPARENCY = Value
        for _, highlight in pairs(highlightMap) do
            if highlight then highlight.FillTransparency = Value end
        end
    end
})

VisualsTab:CreateSlider({
    Name = "Прозрачность контура",
    Range = {0, 1},
    Increment = 0.05,
    Suffix = "",
    CurrentValue = Settings.HIGHLIGHT_OUTLINE_TRANSPARENCY,
    Flag = "OutlineTrans",
    Callback = function(Value)
        Settings.HIGHLIGHT_OUTLINE_TRANSPARENCY = Value
        for _, highlight in pairs(highlightMap) do
            if highlight then highlight.OutlineTransparency = Value end
        end
    end
})

-- Movement вкладка
MovementTab:CreateToggle({
    Name = "Noclip",
    CurrentValue = Settings.NOCLIP_ENABLED,
    Flag = "NoclipToggle",
    Callback = function(Value)
        Settings.NOCLIP_ENABLED = Value
        SetNoclip(Value)
    end
})

MovementTab:CreateToggle({
    Name = "FLY",
    CurrentValue = Settings.FLY_ENABLED,
    Flag = "FlyToggle",
    Callback = function(Value)
        SetFly(Value)
    end
})

MovementTab:CreateSlider({
    Name = "Speed",
    Range = {10, 200},
    Increment = 5,
    Suffix = "u/s",
    CurrentValue = Settings.FLY_SPEED,
    Flag = "FlySpeed",
    Callback = function(Value)
        Settings.FLY_SPEED = Value
    end
})

VisualsTab:CreateButton({
    Name = "Controls",
    Callback = function()
        Rayfield:Notify({
            Title = "Управление",
            Content = "Клавиша активации AIM - правая кнопка мыши. Управление полётом: WASD + E/Q.",
            Duration = 4,
        })
    end
})

-- =====================================================
--                      ОБРАБОТЧИКИ СОБЫТИЙ
-- =====================================================

local function OnInputBegan(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Settings.AIM_KEY then
        aimingActive = true
    end
end

local function OnInputEnded(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Settings.AIM_KEY then
        aimingActive = false
    end
end

local function OnCameraChanged()
    camera = Workspace.CurrentCamera
end

-- =====================================================
--                      ИНИЦИАЛИЗАЦИЯ
-- =====================================================

local function SetupEventHandlers()
    UserInputService.InputBegan:Connect(OnInputBegan)
    UserInputService.InputEnded:Connect(OnInputEnded)
    Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(OnCameraChanged)
    
    -- Локальный персонаж
    if localPlayer.Character then
        OnLocalCharacterAdded(localPlayer.Character)
    end
    localPlayer.CharacterAdded:Connect(OnLocalCharacterAdded)
    
    -- Другие игроки для обводки
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            if player.Character then
                task.wait(0.1)
                UpdateHighlightForPlayer(player)
            end
            player.CharacterAdded:Connect(function(character)
                OnCharacterAdded(player, character)
            end)
            player:GetPropertyChangedSignal("Team"):Connect(function()
                OnTeamChanged(player)
            end)
        end
    end
    
    Players.PlayerAdded:Connect(function(player)
        if player == localPlayer then return end
        player.CharacterAdded:Connect(function(character)
            OnCharacterAdded(player, character)
        end)
        player:GetPropertyChangedSignal("Team"):Connect(function()
            OnTeamChanged(player)
        end)
        UpdateHighlightForPlayer(player)
    end)
    
    Players.PlayerRemoving:Connect(OnPlayerRemoving)
    
    localPlayer:GetPropertyChangedSignal("Team"):Connect(function()
        RefreshAllHighlights()
    end)
end

local function Start()
    print("AIM-ассист + Movement (GMod Fly) + Rayfield GUI загружен. Нажмите K для открытия меню.")
    SetupEventHandlers()
    RunService.RenderStepped:Connect(OnRenderStep)
    RefreshAllHighlights()
end

Start()
