-- Services used for bomber selection and visuals
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- Local player and shared bomber assets
local Player = Players.LocalPlayer

local Modules = ReplicatedStorage:WaitForChild("Module")
local Libraries = Modules:WaitForChild("Libraries")
local bomberData = require(Libraries:WaitForChild("Bombers"))

local Assets = ReplicatedFirst:WaitForChild("Assets")
local RangeMarker = Assets:WaitForChild("RangeMarker")
local Animations = Assets:WaitForChild("Animations")

local angles = CFrame.fromEulerAnglesXYZ

-- Keep track of effects and connections so they can be cleaned up later
local Connections = {}
local DestroyConnections = {}
local Visuals = {}
local ActiveTweens = {}
local Highlights = {}
local HighlightTweens = {}
local Initialized = {}

-- Only one bomber should have its range shown at a time
local ActiveRangeBomber: Model? = nil
local HoveredBomber: Model? = nil
local UsingGamepad = false

-- Ignore the player when checking what the mouse is pointing at
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true

local HIGHLIGHT_IN_TIME = 0.12
local HIGHLIGHT_OUT_TIME = 0.1

local function updateRaycastFilter() -- Update the raycast filter when the character changes
	local character = Player.Character

	if character then
		RayParams.FilterDescendantsInstances = {character}
	else
		RayParams.FilterDescendantsInstances = {}
	end
end

updateRaycastFilter()

Player.CharacterAdded:Connect(updateRaycastFilter)

local function isTargetModel(model: Model?): boolean -- Check if this is a bomber or a placing model
	if not model then
		return false
	end

	return model:HasTag("Bombers") or model:HasTag("Placing")
end

local function getTargetModel(instance: Instance?): Model? -- Find the bomber model from the part we hit
	local current = instance

	while current do
		if current:IsA("Model") and isTargetModel(current) then
			return current
		end

		current = current.Parent
	end

	return nil
end

local function stopTween(inst: Model) -- Stop the range animation if it is still running
	local connection = ActiveTweens[inst]

	if connection then
		connection:Disconnect()
		ActiveTweens[inst] = nil
	end
end

local function removeVisual(inst: Model) -- Remove the range circle from this bomber
	local marker = Visuals[inst]

	if not marker then
		return
	end

	stopTween(inst)

	Visuals[inst] = nil
	marker:Destroy()
end

local function createVisual(inst: Model) -- Show and animate the bomber range circle
	local primaryPart = inst.PrimaryPart

	if not primaryPart then
		warn(inst.Name .. " has no PrimaryPart")
		return
	end

	local data = bomberData[inst.Name]

	if not data then
		warn(inst.Name .. " has no data")
		return
	end

	local marker = Visuals[inst]

	if not marker then
		marker = RangeMarker:Clone() -- Make a separate marker for this bomber

		local baseCFrame =
			CFrame.new(
				primaryPart.Position
				- Vector3.new(0, primaryPart.Size.Y / 2, 0)
			)
			* angles(
				0,
				math.rad(90),
				math.rad(90)
			)

		marker.Size = Vector3.new(0.1, 0, 0)
		marker.Parent = primaryPart
		marker:PivotTo(baseCFrame)

		-- Slowly rotate the decal while the marker exists
		task.spawn(function()
			while marker.Parent and marker:FindFirstChild("Decal") do
				marker.Decal.Rotation += 0.1
				task.wait()
			end
		end)

		Visuals[inst] = marker
	end

	stopTween(inst)

	local targetSize = Vector3.new(
		0.1,
		data.Range,
		data.Range
	)

	-- Make the circle grow a little past its size before settling
	local overshoot = Vector3.new(
		0.1,
		data.Range * 1.08,
		data.Range * 1.08
	)

	local reachedOvershoot = false

	ActiveTweens[inst] = RunService.RenderStepped:Connect(function(dt)
		if not marker.Parent then
			stopTween(inst)
			Visuals[inst] = nil
			return
		end

		local goal = reachedOvershoot and targetSize or overshoot

		marker.Size = marker.Size:Lerp(
			goal,
			math.clamp(dt * 18, 0, 1)
		)

		if not reachedOvershoot then
			if (marker.Size - overshoot).Magnitude < 0.1 then
				reachedOvershoot = true
			end
		else
			if (marker.Size - targetSize).Magnitude < 0.05 then
				marker.Size = targetSize
				stopTween(inst)
			end
		end
	end)
end

local function stopHighlightTween(inst: Model) -- Cancel any old hover tween
	local tween = HighlightTweens[inst]

	if tween then
		tween:Cancel()
		HighlightTweens[inst] = nil
	end
end

local function createHighlight(inst: Model) -- Fade in the outline when hovering
	local highlight = Highlights[inst]

	if not highlight then
		highlight = Instance.new("Highlight")

		highlight.Name = "HoverHighlight"
		highlight.Adornee = inst
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded

		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1

		highlight.Parent = inst

		Highlights[inst] = highlight
	end

	stopHighlightTween(inst)

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(
			HIGHLIGHT_IN_TIME,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 1,
			OutlineTransparency = 0
		}
	)

	HighlightTweens[inst] = tween

	tween.Completed:Connect(function()
		if HighlightTweens[inst] == tween then
			HighlightTweens[inst] = nil
		end
	end)

	tween:Play()
end

local function removeHighlight(inst: Model) -- Fade out the outline when leaving
	local highlight = Highlights[inst]

	if not highlight then
		return
	end

	stopHighlightTween(inst)

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(
			HIGHLIGHT_OUT_TIME,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.In
		),
		{
			FillTransparency = 1,
			OutlineTransparency = 1
		}
	)

	HighlightTweens[inst] = tween

	tween.Completed:Connect(function()
		if Highlights[inst] ~= highlight then
			return
		end

		Highlights[inst] = nil
		HighlightTweens[inst] = nil

		highlight:Destroy()
	end)

	tween:Play()
end

local function setHoveredBomber(model: Model?) -- Switch the hovered bomber without duplicate highlights
	if HoveredBomber == model then
		return
	end

	if HoveredBomber then
		removeHighlight(HoveredBomber)
	end

	HoveredBomber = model

	if HoveredBomber then
		createHighlight(HoveredBomber)
	end
end

local function clearRange() -- Hide the currently selected range
	local active = ActiveRangeBomber

	ActiveRangeBomber = nil

	if active and active.Parent then
		active:SetAttribute("RangeHighlight", false)
	end
end

local function setRange(model: Model?) -- Toggle the range on the selected bomber
	if not model then
		clearRange()
		return
	end

	if model:GetAttribute("Placing") then
		return
	end

	if ActiveRangeBomber == model then
		clearRange()
		return
	end

	local previous = ActiveRangeBomber

	ActiveRangeBomber = model

	if previous and previous.Parent then
		previous:SetAttribute("RangeHighlight", false)
	end

	model:SetAttribute("RangeHighlight", true)
end

local function updateVisual(inst: Instance) -- Set up visuals and listeners for a bomber
	if not inst:IsA("Model") then
		return
	end

	if Initialized[inst] then
		return
	end

	Initialized[inst] = true -- Avoid setting up the same model twice

	if inst:GetAttribute("RangeHighlight") then
		if not ActiveRangeBomber then
			ActiveRangeBomber = inst
		else
			inst:SetAttribute("RangeHighlight", false)
		end
	end

	if inst:GetAttribute("RangeHighlight") then
		createVisual(inst)
	end

	-- Play its idle animation if it has a humanoid
	local visual = inst:FindFirstChild("Visual")

	if visual and not inst:GetAttribute("Placing") then
		local humanoid = visual:FindFirstChildOfClass("Humanoid")

		if humanoid then
			local animation = Animations:FindFirstChild(
				inst.Name .. "Idle"
			)

			if animation and animation:IsA("Animation") then
				local animator =
					humanoid:FindFirstChildOfClass("Animator")

				if not animator then
					animator = Instance.new("Animator")
					animator.Parent = humanoid
				end

				local track = animator:LoadAnimation(animation)
				track:Play()
			end
		end
	end

	-- Update the range circle whenever its attribute changes
	Connections[inst] =
		inst:GetAttributeChangedSignal("RangeHighlight"):Connect(function()
			if inst:GetAttribute("RangeHighlight") then
				if ActiveRangeBomber ~= inst then
					if ActiveRangeBomber then
						ActiveRangeBomber:SetAttribute(
							"RangeHighlight",
							false
						)
					end

					ActiveRangeBomber = inst
				end

				createVisual(inst)
			else
				if ActiveRangeBomber == inst then
					ActiveRangeBomber = nil
				end

				removeVisual(inst)
			end
		end)

	-- Clean everything up when this bomber is destroyed
	DestroyConnections[inst] = inst.Destroying:Connect(function()
		if HoveredBomber == inst then
			HoveredBomber = nil
		end

		if ActiveRangeBomber == inst then
			ActiveRangeBomber = nil
		end

		stopTween(inst)
		stopHighlightTween(inst)
		removeVisual(inst)
		removeHighlight(inst)

		local connection = Connections[inst]

		if connection then
			connection:Disconnect()
			Connections[inst] = nil
		end

		local destroyConnection = DestroyConnections[inst]

		if destroyConnection then
			destroyConnection:Disconnect()
			DestroyConnections[inst] = nil
		end

		Initialized[inst] = nil
	end)
end

local function raycastAtScreenPosition(screenPosition: Vector2): Model? -- Check which bomber is under the cursor
	local camera = workspace.CurrentCamera

	if not camera then
		return nil
	end

	local ray = camera:ViewportPointToRay(
		screenPosition.X,
		screenPosition.Y
	)

	local result = workspace:Raycast(
		ray.Origin,
		ray.Direction * 1000,
		RayParams
	)

	if not result then
		return nil
	end

	return getTargetModel(result.Instance)
end

local function getCenterScreenPosition(): Vector2 -- Gamepad uses the middle of the screen
	local camera = workspace.CurrentCamera

	if not camera then
		return Vector2.zero
	end

	local viewportSize = camera.ViewportSize

	return Vector2.new(
		viewportSize.X * 0.5,
		viewportSize.Y * 0.5
	)
end

-- Detect when the player switches between gamepad, mouse, and touch
UserInputService.LastInputTypeChanged:Connect(function(inputType)
	UsingGamepad =
		inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
		or inputType == Enum.UserInputType.Gamepad5
		or inputType == Enum.UserInputType.Gamepad6
		or inputType == Enum.UserInputType.Gamepad7
		or inputType == Enum.UserInputType.Gamepad8

	if UsingGamepad then
		return
	end

	if inputType == Enum.UserInputType.Touch then
		setHoveredBomber(nil)
	end
end)

-- Update the hover outline as the mouse moves
UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if UsingGamepad then
		return
	end

	if input.UserInputType ~= Enum.UserInputType.MouseMovement then
		return
	end

	local model = raycastAtScreenPosition(
		UserInputService:GetMouseLocation()
	)

	if model and model:GetAttribute("Placing") then
		setHoveredBomber(nil)
		return
	end

	setHoveredBomber(model)
end)

-- Select bombers with mouse click or the gamepad A button
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local model = raycastAtScreenPosition(
			UserInputService:GetMouseLocation()
		)

		if model and model:GetAttribute("Placing") then
			return
		end

		setRange(model)

		return
	end

	if input.KeyCode == Enum.KeyCode.ButtonA then
		local model = raycastAtScreenPosition(
			getCenterScreenPosition()
		)

		if model and model:GetAttribute("Placing") then
			return
		end

		setRange(model)
	end
end)

-- Allow mobile players to tap a bomber to see its range
UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
	if gameProcessed then
		return
	end

	local screenPosition = touchPositions[1]

	if not screenPosition then
		return
	end

	local model = raycastAtScreenPosition(screenPosition)

	if model and model:GetAttribute("Placing") then
		return
	end

	setRange(model)
end)

-- Limit gamepad hover checks to around 30 times per second
local gamepadAccumulator = 0

RunService.RenderStepped:Connect(function(dt)
	if not UsingGamepad then
		return
	end

	gamepadAccumulator += dt

	if gamepadAccumulator < 1 / 30 then
		return
	end

	gamepadAccumulator = 0

	local model = raycastAtScreenPosition(
		getCenterScreenPosition()
	)

	if model and model:GetAttribute("Placing") then
		setHoveredBomber(nil)
		return
	end

	setHoveredBomber(model)
end)

-- Set up bombers that already exist in the workspace
for _, bomber in CollectionService:GetTagged("Bombers") do
	updateVisual(bomber)
end

for _, bomber in CollectionService:GetTagged("Placing") do
	updateVisual(bomber)
end

-- Also set up any bombers added later
CollectionService:GetInstanceAddedSignal("Bombers"):Connect(updateVisual)
CollectionService:GetInstanceAddedSignal("Placing"):Connect(updateVisual)