-- LocalScript (StarterGui или StarterPlayerScripts)
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local mouse = localPlayer:GetMouse()
local camera = Workspace.CurrentCamera

-- ===== НАСТРОЙКИ =====
-- AIM
local AIM_KEY = Enum.UserInputType.MouseButton2  -- правая кнопка мыши
local SENSITIVITY = 0.3   -- сила притяжения (0-1)
local MAX_ANGLE = math.rad(2) -- максимальный угол поворота за кадр (~2 градуса)
local RADIUS = 100         -- радиус в пикселях от курсора, в котором ищем цель
local IGNORE_WALLS = true   -- включить проверку видимости через стены
local TEAM_CHECK = true     -- включить проверку команд (не наводиться на своих)

-- HIGHLIGHT
local HIGHLIGHT_ENABLED = true      -- включить обводку противников
local HIGHLIGHT_COLOR = Color3.new(1, 0, 0) -- красный
local HIGHLIGHT_FILL_TRANSPARENCY = 1      -- заливка полностью прозрачна
local HIGHLIGHT_OUTLINE_TRANSPARENCY = 0   -- обводка непрозрачна
-- =======================

local aimActive = false

-- Функция проверки видимости цели (Raycast от камеры до головы)
local function isTargetVisible(targetCharacter, targetHead)
    if not IGNORE_WALLS then return true end

    local cameraPos = camera.CFrame.Position
    local direction = (targetHead.Position - cameraPos).Unit
    local distance = (targetHead.Position - cameraPos).Magnitude

    local raycastParams = RaycastParams.new()
    local ignoreList = {localPlayer.Character, targetCharacter}
    raycastParams.FilterDescendantsInstances = ignoreList
    raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

    local rayResult = Workspace:Raycast(cameraPos, direction * distance, raycastParams)
    if not rayResult then
        return true
    end
    local hitParent = rayResult.Instance:FindFirstAncestorWhichIsA("Model")
    if hitParent == targetCharacter then
        return true
    end
    return false
end

-- Функция получения ближайшего игрока в пределах RADIUS от курсора,
-- прошедшего проверки видимости и команды
local function getClosestPlayer()
    local closest = nil
    local shortestDist = RADIUS + 1

    for _, player in ipairs(Players:GetPlayers()) do
        if player == localPlayer then continue end
        if TEAM_CHECK and localPlayer.Team and player.Team then
            if localPlayer.Team == player.Team then
                continue
            end
        end

        local character = player.Character
        if not character then continue end

        local humanoid = character:FindFirstChild("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end

        local head = character:FindFirstChild("Head")
        if not head then continue end

        local screenPos, onScreen = camera:WorldToScreenPoint(head.Position)
        if not onScreen then continue end

        if IGNORE_WALLS and not isTargetVisible(character, head) then
            continue
        end

        local mousePos = Vector2.new(mouse.X, mouse.Y)
        local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
        if dist < shortestDist then
            shortestDist = dist
            closest = player
        end
    end

    return closest, shortestDist
end

-- Применяет плавное притяжение к цели
local function applyAimAssist(target)
    if not target or not target.Character then return end

    local head = target.Character:FindFirstChild("Head")
    if not head then return end

    local screenPos, onScreen = camera:WorldToScreenPoint(head.Position)
    if not onScreen then return end

    local targetScreenPos = Vector2.new(screenPos.X, screenPos.Y)
    local currentMousePos = Vector2.new(mouse.X, mouse.Y)
    local delta = targetScreenPos - currentMousePos

    if delta.Magnitude < 2 then return end

    local fov = camera.FieldOfView
    local screenWidth = camera.ViewportSize.X
    local anglePerPixel = (math.rad(fov) / screenWidth) * 2

    local deltaAngleX = -delta.X * anglePerPixel * SENSITIVITY
    local deltaAngleY = -delta.Y * anglePerPixel * SENSITIVITY

    deltaAngleX = math.clamp(deltaAngleX, -MAX_ANGLE, MAX_ANGLE)
    deltaAngleY = math.clamp(deltaAngleY, -MAX_ANGLE, MAX_ANGLE)

    local newCFrame = camera.CFrame * CFrame.Angles(0, deltaAngleX, 0) * CFrame.Angles(deltaAngleY, 0, 0)
    camera.CFrame = newCFrame
end

-- ========== HIGHLIGHT SYSTEM ==========
local function isEnemy(player)
    if player == localPlayer then return false end
    if TEAM_CHECK then
        if localPlayer.Team and player.Team then
            return localPlayer.Team ~= player.Team
        end
        -- если у одного из игроков нет команды, считаем врагом (можно поменять логику)
        return true
    end
    return true -- если TEAM_CHECK выключен, все противники
end

local function addHighlightToCharacter(character)
    if not character or not HIGHLIGHT_ENABLED then return end
    -- если уже есть наш Highlight, не добавляем новый
    if character:FindFirstChild("AimAssistHighlight") then return end

    local highlight = Instance.new("Highlight")
    highlight.Name = "AimAssistHighlight"
    highlight.FillColor = HIGHLIGHT_COLOR
    highlight.OutlineColor = HIGHLIGHT_COLOR
    highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
    highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_TRANSPARENCY
    highlight.Parent = character
end

local function removeHighlightFromCharacter(character)
    local highlight = character and character:FindFirstChild("AimAssistHighlight")
    if highlight then
        highlight:Destroy()
    end
end

-- Обновляет состояние обводки для конкретного игрока (по его персонажу)
local function updateHighlightForPlayer(player)
    if not HIGHLIGHT_ENABLED then return end

    local character = player.Character
    if not character then return end

    if isEnemy(player) then
        addHighlightToCharacter(character)
    else
        removeHighlightFromCharacter(character)
    end
end

-- Обработчик появления персонажа
local function onCharacterAdded(player, character)
    updateHighlightForPlayer(player)
    -- также следим за смертью (Humanoid.Died) – Highlight автоматически удалится при удалении персонажа,
    -- но если нужно очистить именно при смерти до удаления, можно подключиться к Died, но CharacterAdded сработает при респавне.
end

-- Подписка на события
for _, player in ipairs(Players:GetPlayers()) do
    -- для уже существующих игроков
    if player ~= localPlayer then
        updateHighlightForPlayer(player)
        player.CharacterAdded:Connect(function(character)
            onCharacterAdded(player, character)
        end)
    end
end

-- Слушаем добавление новых игроков
Players.PlayerAdded:Connect(function(player)
    if player == localPlayer then return end
    player.CharacterAdded:Connect(function(character)
        onCharacterAdded(player, character)
    end)
    -- если у игрока уже есть персонаж (редко, но бывает при позднем подключении)
    if player.Character then
        onCharacterAdded(player, player.Character)
    end
end)

-- При удалении игрока чистим обводку (если персонаж ещё существует)
Players.PlayerRemoving:Connect(function(player)
    if player.Character then
        removeHighlightFromCharacter(player.Character)
    end
end)

-- Если локальный игрок меняет команду, нужно обновить обводки для всех
local function onLocalTeamChanged()
    if not HIGHLIGHT_ENABLED then return end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            updateHighlightForPlayer(player)
        end
    end
end
if localPlayer.Team then
    localPlayer.Team:GetPropertyChangedSignal("Team"):Connect(onLocalTeamChanged)
else
    -- если команды нет изначально, подождём её появления
    localPlayer:GetPropertyChangedSignal("Team"):Connect(function()
        onLocalTeamChanged()
    end)
end

-- ========== AIM ASSIST LOOP ==========
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == AIM_KEY then
        aimActive = true
    end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if input.UserInputType == AIM_KEY then
        aimActive = false
    end
end)

RunService.RenderStepped:Connect(function()
    if aimActive then
        local target, distance = getClosestPlayer()
        if target and distance <= RADIUS then
            applyAimAssist(target)
        end
    end
end)

print("Aim assist loaded with wall check, team check, and enemy highlight. Hold RMB to activate.")