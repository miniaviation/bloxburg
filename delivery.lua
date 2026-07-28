local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer
local ARROW_NAME  = "GuidingArrow_PizzaDelivery_Customer"
local mouseIgnore = workspace:WaitForChild("MouseIgnore")

-- ── Config ────────────────────────────────────────────────────────────────────
local DOT_SPACING    = 3
local DOT_SIZE       = 0.35
local DOT_COLOR      = Color3.fromRGB(255, 210, 0)
local PATH_Y_OFFSET  = 0.5
local RECOMPUTE_RATE = 1.0

-- Hardcoded return position
local RETURN_POSITION = Vector3.new(-46.484, 5.844, -37.790)

-- Vehicle
local VEHICLE_SPEED       = 28
local WAYPOINT_REACH_DIST = 1.5  -- tighter: don't skip ahead until we're actually AT the waypoint
local ARRIVE_STOP_DIST    = 2
local BASE_ARRIVE_DIST    = 6
local TURN_SPEED          = 18   -- much snappier turning so it doesn't arc wide
local GROUND_HOVER        = 1.5
local GRAVITY             = 60
local MAX_FALL_SPEED      = 80
local GROUND_SEARCH_UP    = 3
local GROUND_SEARCH_DOWN  = 20
local MAX_STEP_UP         = 3.5
local VERTICAL_SMOOTH     = 12

-- Wall probing
local AVOID_PROBE_DIST   = 5
local AVOID_PROBE_HEIGHT = 1.2
local MOPED_HALF_WIDTH   = 2.2

-- Stuck detection
local STUCK_CHECK_INTERVAL = 1.5
local STUCK_MOVE_THRESHOLD = 1.0

-- Unstuck manoeuvre
local UNSTUCK_REVERSE_TIME = 1.2
local UNSTUCK_TURN_TIME    = 1.0

-- Predictive path check
local LOOKAHEAD_WP_COUNT   = 6
local LOOKAHEAD_CHECK_RATE = 0.4

-- Pizza pickup automation
local PICKUP_ATTEMPT_DELAY  = 0.6
local PICKUP_MAX_ATTEMPTS   = 8
local PICKUP_RETRY_INTERVAL = 1.0

-- Delivery confirmation
local DELIVERY_POLL_INTERVAL = 0.25
local DELIVERY_TIMEOUT       = 15.0
-- ─────────────────────────────────────────────────────────────────────────────

local folder = Instance.new("Folder")
folder.Name   = "_PizzaPath"
folder.Parent = workspace

-- ── Dot pool ─────────────────────────────────────────────────────────────────
local dotPool = {}
local function getDot(index)
	if dotPool[index] then return dotPool[index] end
	local d = Instance.new("Part")
	d.Name         = "Dot_" .. index
	d.Shape        = Enum.PartType.Ball
	d.Size         = Vector3.one * DOT_SIZE
	d.Color        = DOT_COLOR
	d.Material     = Enum.Material.Neon
	d.Anchored     = true
	d.CanCollide   = false
	d.CanQuery     = false
	d.CanTouch     = false
	d.CastShadow   = false
	d.Transparency = 1
	d.Parent       = folder
	dotPool[index] = d
	return d
end
local function hideAllDots()
	for _, d in dotPool do d.Transparency = 1 end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getMoped()
	local grp = workspace:FindFirstChild(LocalPlayer.Name)
	if not grp then return nil, nil end
	local model = grp:FindFirstChild("Vehicle_Delivery Moped")
	if not model then return nil, nil end
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	return model, primary
end

local function findAssignedCustomer(playerRoot)
	local arrow = mouseIgnore:FindFirstChild(ARROW_NAME)
	if not arrow then return nil end
	local origin = playerRoot.Position
	local look   = arrow.CFrame.LookVector
	local best, bestPerp = nil, math.huge
	for _, model in CollectionService:GetTagged("PizzaPlanetDeliveryCustomer") do
		local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if root then
			local toRoot = root.Position - origin
			local proj   = toRoot:Dot(look)
			local perp   = (toRoot - look * proj).Magnitude
			if proj > 0 and perp < bestPerp then
				bestPerp = perp
				best     = model
			end
		end
	end
	return best
end

-- ── Pizza box pickup ──────────────────────────────────────────────────────────
local isPickingUp = false

local function attemptPickupPizza()
	if isPickingUp then return end
	isPickingUp = true

	task.spawn(function()
		task.wait(PICKUP_ATTEMPT_DELAY)

		local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
		local ok, ui   = pcall(function() return PlayerGui:WaitForChild("_interactUI", 5) end)
		if not ok or not ui then
			warn("[PizzaDelivery] _interactUI not found — cannot auto-pick up pizza.")
			isPickingUp = false
			return
		end
		local ok2, btn = pcall(function() return ui:WaitForChild("InteractIndicator", 5) end)
		if not ok2 or not btn then
			warn("[PizzaDelivery] InteractIndicator not found — cannot auto-pick up pizza.")
			isPickingUp = false
			return
		end

		local function fireInteract()
			firesignal(btn.MouseButton1Down,  0, 0)
			firesignal(btn.MouseButton1Up,    0, 0)
			firesignal(btn.MouseButton1Click)
			firesignal(btn.Activated)
		end

		for attempt = 1, PICKUP_MAX_ATTEMPTS do
			fireInteract()
			task.wait(PICKUP_RETRY_INTERVAL)
			if mouseIgnore:FindFirstChild(ARROW_NAME) then
				break
			end
		end

		isPickingUp = false
	end)
end

-- ── Pathfinding ───────────────────────────────────────────────────────────────
local wallCheckParams = RaycastParams.new()
wallCheckParams.FilterType = Enum.RaycastFilterType.Exclude

-- FIX 2: Multi-height corridor check to catch railings, dock edges, thin walls
local function corridorClear(a, b, excludeList)
	wallCheckParams.FilterDescendantsInstances = excludeList
	local diff = b - a
	local dist = diff.Magnitude
	if dist < 0.1 then return true end
	local unit = diff.Unit
	local perp = Vector3.new(-unit.Z, 0, unit.X)

	-- Cast rays at three heights: near ground, mid-body, and top
	local checkHeights = { 0.3, AVOID_PROBE_HEIGHT, AVOID_PROBE_HEIGHT + 1.5 }

	for _, heightOffset in ipairs(checkHeights) do
		local up = Vector3.new(0, heightOffset, 0)
		for _, off in ipairs({ Vector3.zero, perp * MOPED_HALF_WIDTH, perp * -MOPED_HALF_WIDTH }) do
			local hit = workspace:Raycast(a + up + off, unit * dist, wallCheckParams)
			if hit and hit.Instance and hit.Instance.CanCollide then
				return false
			end
		end
	end
	return true
end

-- FIX 1: MAX_SKIP = 0 — disable waypoint pruning entirely.
-- The pruner was causing the moped to cut through dock geometry by skipping
-- waypoints whenever the line-of-sight check passed at a single height.
-- Trust the pathfinder's waypoints exactly.
local MAX_SKIP = 0
local function pruneWaypoints(chain, exclude)
	if MAX_SKIP == 0 or #chain < 2 then return chain end
	local out = { chain[1] }
	local i   = 1
	while i < #chain do
		local jumped = false
		for skip = 1, MAX_SKIP do
			local j = i + skip
			if j > #chain then break end
			if corridorClear(chain[i], chain[j], exclude) then
				table.insert(out, chain[j])
				i = j; jumped = true; break
			end
		end
		if not jumped then
			i = i + 1
			if chain[i] then table.insert(out, chain[i]) end
		end
	end
	return out
end

local function computeRawWaypoints(fromPos, toPos)
	local mopedModel = getMoped()
	local exclude    = { folder, LocalPlayer.Character }
	if mopedModel then table.insert(exclude, mopedModel) end

	local snapParams = RaycastParams.new()
	snapParams.FilterType = Enum.RaycastFilterType.Exclude
	snapParams.FilterDescendantsInstances = exclude
	local function snap(pos)
		local hit = workspace:Raycast(pos + Vector3.new(0,5,0), Vector3.new(0,-15,0), snapParams)
		return hit and hit.Position or pos
	end

	local sFrom = snap(fromPos)
	local sTo   = snap(toPos)

	-- FIX 4: Tightest radius configs first so narrow geometry (docks, alleys)
	-- is handled before falling back to wider agents that clip through edges.
	local configs = {
		{ radius = 1, height = 3, spacing = 4 },
		{ radius = 2, height = 3, spacing = 4 },
		{ radius = 3, height = 4, spacing = 5 },
		{ radius = 4, height = 5, spacing = 4 },
		{ radius = 5, height = 5, spacing = 4 },
	}
	for _, cfg in ipairs(configs) do
		local ok, chain = pcall(function()
			local path = PathfindingService:CreatePath({
				AgentRadius     = cfg.radius,
				AgentHeight     = cfg.height,
				AgentCanJump    = false,
				AgentCanClimb   = false,
				WaypointSpacing = cfg.spacing,
				Costs           = { Water = 100, Fence = 200, Danger = 50 },
			})
			path:ComputeAsync(sFrom, sTo)
			if path.Status ~= Enum.PathStatus.Success then return nil end
			local pts = {}
			for _, wp in path:GetWaypoints() do table.insert(pts, wp.Position) end
			return pts
		end)
		if ok and chain and #chain >= 2 then
			return pruneWaypoints(chain, exclude)
		end
	end

	-- FIX 3: No straight-line fallback. The old fallback ignored all colliders
	-- and would drive straight through docks and walls. If pathfinding fails,
	-- return empty and let the stuck-detection system handle recovery instead.
	warn("[PizzaDelivery] All pathfinding configs failed — returning empty path.")
	return {}
end

local function findBlockedSegmentAhead(startIdx, chain, excludeList)
	local limit = math.min(startIdx + LOOKAHEAD_WP_COUNT, #chain)
	for i = startIdx, limit - 1 do
		if not corridorClear(chain[i], chain[i+1], excludeList) then
			return i
		end
	end
	return nil
end

local function buildDotPositions(chain)
	local positions = {}
	if #chain < 2 then return positions end
	local segIdx = 1
	local p0     = chain[1] + Vector3.new(0, PATH_Y_OFFSET, 0)
	local p1     = chain[2] + Vector3.new(0, PATH_Y_OFFSET, 0)
	local segVec = p1 - p0
	local segLen = segVec.Magnitude
	local segDir = segLen > 0 and segVec.Unit or Vector3.new(0,0,1)
	local walked = DOT_SPACING * 0.5
	local done   = false
	while segIdx < #chain and not done do
		while walked >= segLen do
			walked  = walked - segLen
			segIdx  = segIdx + 1
			if segIdx >= #chain then done = true break end
			p0      = chain[segIdx]     + Vector3.new(0, PATH_Y_OFFSET, 0)
			p1      = chain[segIdx + 1] + Vector3.new(0, PATH_Y_OFFSET, 0)
			segVec  = p1 - p0
			segLen  = segVec.Magnitude
			segDir  = segLen > 0 and segVec.Unit or segDir
		end
		if not done then
			table.insert(positions, p0 + segDir * walked)
			walked = walked + DOT_SPACING
		end
	end
	return positions
end

-- ── State ─────────────────────────────────────────────────────────────────────
local activeWaypoints    = {}
local activeDotPositions = {}
local lastRecompute      = 0
local lastCustomer       = nil
local clock              = 0
local isComputing        = false

local driveWpIndex = 1
local isDriving    = false
local verticalVel  = 0
local isGrounded   = false

local isReturning     = false
local returnRecompute = 0

local isWaitingDelivery = false
local deliveryWaitStart = 0

local lastStuckCheck         = 0
local lastStuckPos           = nil
local stuckRecomputeCooldown = 0
local stuckPhase             = nil
local stuckPhaseTimer        = 0
local stuckTurnYaw           = 0
local stuckTurnDir           = 1

local activeTarget    = nil
local prevWaypointPos = nil

local lastLookaheadCheck = 0

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local avoidParams = RaycastParams.new()
avoidParams.FilterType = Enum.RaycastFilterType.Exclude

-- ── Ground snap ───────────────────────────────────────────────────────────────
local function resolveGroundY(mopedModel, mopedPart, newX, newZ, dt)
	groundParams.FilterDescendantsInstances = { folder, mopedModel, LocalPlayer.Character }
	local origin = Vector3.new(newX, mopedPart.Position.Y + GROUND_SEARCH_UP, newZ)
	local hit    = workspace:Raycast(origin, Vector3.new(0, -(GROUND_SEARCH_UP + GROUND_SEARCH_DOWN), 0), groundParams)
	if hit then
		local targetY  = hit.Position.Y + GROUND_HOVER
		local currentY = mopedPart.Position.Y
		if targetY > currentY then targetY = math.min(targetY, currentY + MAX_STEP_UP * dt) end
		verticalVel = 0
		isGrounded  = true
		return currentY + (targetY - currentY) * math.min(1, VERTICAL_SMOOTH * dt)
	else
		isGrounded  = false
		verticalVel = math.max(verticalVel - GRAVITY * dt, -MAX_FALL_SPEED)
		return mopedPart.Position.Y + verticalVel * dt
	end
end

-- ── Path steering ─────────────────────────────────────────────────────────────
-- Steer directly at the exact waypoint position — no blending, no early turn.
-- This is what makes the moped actually follow the dotted path.
local function pathFollowDirection(mopedPos, wpTarget)
	local toWp = Vector3.new(wpTarget.X - mopedPos.X, 0, wpTarget.Z - mopedPos.Z)
	if toWp.Magnitude < 0.01 then return nil end
	return toWp.Unit
end

-- ── Per-frame wall probe ──────────────────────────────────────────────────────
local function probeWalls(mopedModel, mopedPart, intendedDir)
	avoidParams.FilterDescendantsInstances = { folder, mopedModel, LocalPlayer.Character }
	local origin = mopedPart.Position + Vector3.new(0, AVOID_PROBE_HEIGHT, 0)
	local perp   = Vector3.new(-intendedDir.Z, 0, intendedDir.X)
	local probes = {
		{ dir = intendedDir,                          steer = 0  },
		{ dir = (intendedDir + perp * 0.7).Unit,      steer = -1 },
		{ dir = (intendedDir + perp * -0.7).Unit,     steer =  1 },
		{ dir = perp,                                 steer = -1 },
		{ dir = -perp,                                steer =  1 },
	}
	local steer   = 0
	local blocked = false
	for _, p in ipairs(probes) do
		local hit = workspace:Raycast(origin, p.dir * AVOID_PROBE_DIST, avoidParams)
		if hit and hit.Instance and hit.Instance.CanCollide then
			local closeness = 1 - (hit.Distance / AVOID_PROBE_DIST)
			steer = steer + p.steer * closeness * 2.0
			if p.steer == 0 then blocked = true end
		end
	end
	if steer == 0 and not blocked then return intendedDir, false end
	local angle = math.clamp(steer, -math.pi*0.35, math.pi*0.35)
	local c, s  = math.cos(angle), math.sin(angle)
	local steered = Vector3.new(
		intendedDir.X*c - intendedDir.Z*s,
		0,
		intendedDir.X*s + intendedDir.Z*c
	)
	return steered.Magnitude > 0 and steered.Unit or intendedDir, blocked
end

-- ── Interact + delivery confirmation ─────────────────────────────────────────
local function fireInteractButton()
	task.spawn(function()
		task.wait(0.3)
		local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
		local ok,  ui  = pcall(function() return PlayerGui:WaitForChild("_interactUI", 5) end)
		if not ok or not ui then return end
		local ok2, btn = pcall(function() return ui:WaitForChild("InteractIndicator", 5) end)
		if not ok2 or not btn then return end
		firesignal(btn.MouseButton1Down, 0, 0)
		firesignal(btn.MouseButton1Up,   0, 0)
		firesignal(btn.MouseButton1Click)
		firesignal(btn.Activated)
	end)
end

local function waitForDeliveryThenReturn()
	if isWaitingDelivery then return end
	isWaitingDelivery = true
	deliveryWaitStart = tick()
	task.spawn(function()
		while isWaitingDelivery do
			local arrowGone = mouseIgnore:FindFirstChild(ARROW_NAME) == nil
			if arrowGone or (tick() - deliveryWaitStart) >= DELIVERY_TIMEOUT then
				isWaitingDelivery    = false
				task.wait(0.5)
				_G._pizzaReturnReady = true
				return
			end
			task.wait(DELIVERY_POLL_INTERVAL)
		end
	end)
end

-- ── Recompute helper ──────────────────────────────────────────────────────────
local function triggerRecompute(fromPos, toPos, isNewDest)
	if isComputing then return end
	isComputing  = true
	activeTarget = toPos
	task.spawn(function()
		local chain = computeRawWaypoints(fromPos, toPos)
		activeWaypoints    = chain
		activeDotPositions = buildDotPositions(chain)
		if isNewDest then
			driveWpIndex    = 1
			verticalVel     = 0
			isGrounded      = false
			stuckPhase      = nil
			stuckPhaseTimer = 0
			prevWaypointPos = nil
		else
			local _, mp = getMoped()
			if mp and #chain > 0 then
				local best, bestD = 1, math.huge
				for i, wp in ipairs(chain) do
					local d = (mp.Position - wp).Magnitude
					if d < bestD then bestD = d; best = i end
				end
				driveWpIndex    = math.max(driveWpIndex, best)
				prevWaypointPos = best > 1 and chain[best-1] or nil
			end
		end
		isDriving   = #chain > 0
		isComputing = false
	end)
end

-- ── Begin return trip ─────────────────────────────────────────────────────────
local function beginReturn()
	local _, mp = getMoped()
	if not mp then isReturning = false return end
	isReturning     = true
	returnRecompute = tick()
	triggerRecompute(mp.Position, RETURN_POSITION, true)
end

-- ── Drive step ────────────────────────────────────────────────────────────────
local function stepVehicleDrive(dt, targetPos, arriveStopDist, onArrived)
	local mopedModel, mopedPart = getMoped()
	if not mopedPart then return end

	if (mopedPart.Position - targetPos).Magnitude <= arriveStopDist then
		isDriving       = false
		stuckPhase      = nil
		verticalVel     = 0
		prevWaypointPos = nil
		if onArrived then onArrived() end
		return
	end

	-- ── Unstuck phases ────────────────────────────────────────────────────────
	if stuckPhase then
		stuckPhaseTimer = stuckPhaseTimer + dt
		local _, yaw, _ = mopedPart.CFrame:ToEulerAnglesYXZ()

		if stuckPhase == "reverse" then
			local cf   = CFrame.new(mopedPart.Position) * CFrame.fromEulerAnglesYXZ(0, yaw, 0)
			local step = -cf.LookVector * (VEHICLE_SPEED * 0.5) * dt
			local nx   = mopedPart.Position.X + step.X
			local nz   = mopedPart.Position.Z + step.Z
			local ny   = resolveGroundY(mopedModel, mopedPart, nx, nz, dt)
			mopedPart.CFrame = CFrame.new(nx, ny, nz) * CFrame.fromEulerAnglesYXZ(0, yaw, 0)
			if stuckPhaseTimer >= UNSTUCK_REVERSE_TIME then
				stuckTurnDir    = (math.random(0,1)==0) and 1 or -1
				stuckTurnYaw    = yaw + stuckTurnDir * (math.pi * 0.85)
				stuckPhase      = "turn"
				stuckPhaseTimer = 0
			end

		elseif stuckPhase == "turn" then
			local rate  = math.pi * 3.5
			local delta = ((stuckTurnYaw - yaw + math.pi) % (math.pi*2)) - math.pi
			local step  = math.clamp(delta, -rate*dt, rate*dt)
			local ny    = resolveGroundY(mopedModel, mopedPart, mopedPart.Position.X, mopedPart.Position.Z, dt)
			mopedPart.CFrame = CFrame.new(mopedPart.Position.X, ny, mopedPart.Position.Z)
				* CFrame.fromEulerAnglesYXZ(0, yaw+step, 0)
			if stuckPhaseTimer >= UNSTUCK_TURN_TIME then
				stuckPhase             = nil
				stuckPhaseTimer        = 0
				stuckRecomputeCooldown = tick()
				lastStuckPos           = mopedPart.Position
				lastStuckCheck         = tick()
				prevWaypointPos        = nil
				if activeTarget then
					triggerRecompute(mopedPart.Position, activeTarget, true)
				else
					lastRecompute   = 0
					returnRecompute = 0
				end
			end
		end
		return
	end

	-- ── Normal drive ─────────────────────────────────────────────────────────
	if #activeWaypoints == 0 then return end
	driveWpIndex = math.min(driveWpIndex, #activeWaypoints)

	while driveWpIndex < #activeWaypoints do
		local wp = activeWaypoints[driveWpIndex]
		local fd = Vector2.new(mopedPart.Position.X - wp.X, mopedPart.Position.Z - wp.Z).Magnitude
		if fd < WAYPOINT_REACH_DIST then
			driveWpIndex = driveWpIndex + 1
		else
			break
		end
	end

	local wp          = activeWaypoints[driveWpIndex]
	local intendedDir = pathFollowDirection(mopedPart.Position, wp)
	if not intendedDir then return end

	local finalDir, wallAhead = probeWalls(mopedModel, mopedPart, intendedDir)

	local speed = wallAhead and (VEHICLE_SPEED * 0.5) or VEHICLE_SPEED

	-- Rotate toward finalDir at TURN_SPEED (radians/sec), capped to max turn per frame.
	-- No CFrame lerp — lerp causes the early-arc problem. We rotate by a fixed angular
	-- rate each frame so the moped always hugs the path tightly.
	local _, curYaw, _ = mopedPart.CFrame:ToEulerAnglesYXZ()
	-- Roblox YXZ euler: yaw=0 faces -Z, increases CCW when viewed from above
	local targetYaw = math.atan2(-finalDir.X, -finalDir.Z)
	-- shortest-path yaw delta
	local delta   = ((targetYaw - curYaw + math.pi) % (math.pi * 2)) - math.pi
	local maxTurn = TURN_SPEED * dt
	local newYaw  = curYaw + math.clamp(delta, -maxTurn, maxTurn)

	local fwd = Vector3.new(-math.sin(newYaw), 0, -math.cos(newYaw))
	local move = fwd * speed * dt
	local nx   = mopedPart.Position.X + move.X
	local nz   = mopedPart.Position.Z + move.Z
	local ny   = resolveGroundY(mopedModel, mopedPart, nx, nz, dt)
	mopedPart.CFrame = CFrame.new(nx, ny, nz) * CFrame.fromEulerAnglesYXZ(0, newYaw, 0)
end

-- ── Dot rendering ─────────────────────────────────────────────────────────────
local function renderDots()
	local count = #activeDotPositions
	if count == 0 then hideAllDots() return end
	for i = 1, count do
		local dot   = getDot(i)
		local alpha = math.clamp((i-1)/count * count * 0.3 + 0.1, 0, 1)
		dot.Position     = activeDotPositions[i]
		dot.Size         = Vector3.one * DOT_SIZE * (0.6 + 0.4*alpha)
		dot.Transparency = 1 - alpha
	end
	for i = count+1, #dotPool do dotPool[i].Transparency = 1 end
end

-- ── Stuck detection ───────────────────────────────────────────────────────────
local function checkStuck(now)
	if not isDriving or stuckPhase ~= nil then return end
	if (now - lastStuckCheck) < STUCK_CHECK_INTERVAL then return end
	local _, mp = getMoped()
	if not mp then return end
	if lastStuckPos then
		local moved = (mp.Position - lastStuckPos).Magnitude
		if moved < STUCK_MOVE_THRESHOLD and (now - stuckRecomputeCooldown) > 3 then
			stuckPhase      = "reverse"
			stuckPhaseTimer = 0
			stuckTurnDir    = (math.random(0,1)==0) and 1 or -1
		end
	end
	lastStuckPos   = mp.Position
	lastStuckCheck = now
end

-- ── Predictive lookahead check ────────────────────────────────────────────────
local function checkLookahead(now)
	if not isDriving or stuckPhase ~= nil or isComputing then return end
	if (now - lastLookaheadCheck) < LOOKAHEAD_CHECK_RATE then return end
	lastLookaheadCheck = now
	if #activeWaypoints < 2 then return end

	local mopedModel = getMoped()
	local exclude    = { folder, LocalPlayer.Character }
	if mopedModel then table.insert(exclude, mopedModel) end

	local blockedAt = findBlockedSegmentAhead(driveWpIndex, activeWaypoints, exclude)
	if blockedAt then
		local _, mp = getMoped()
		if mp and activeTarget then
			triggerRecompute(mp.Position, activeTarget, false)
		end
	end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
	clock = clock + dt
	local now = tick()

	if _G._pizzaReturnReady then
		_G._pizzaReturnReady = false
		beginReturn()
	end

	-- Return-to-base
	if isReturning then
		if (now - returnRecompute) >= RECOMPUTE_RATE then
			returnRecompute = now
			local _, mp = getMoped()
			if mp then triggerRecompute(mp.Position, RETURN_POSITION, false) end
		end

		checkStuck(now)
		checkLookahead(now)

		if isDriving then
			stepVehicleDrive(dt, RETURN_POSITION, BASE_ARRIVE_DIST, function()
				isReturning  = false
				lastCustomer = nil
				hideAllDots()
				activeWaypoints            = {}
				activeDotPositions         = {}
				activeTarget               = nil
				_G._pizzaDeliveryInteracted = false
				attemptPickupPizza()
			end)
		end

		renderDots()
		return
	end

	-- Waiting for pizza confirmation
	if isWaitingDelivery then return end

	-- Normal delivery
	local root  = getRoot()
	local arrow = root and mouseIgnore:FindFirstChild(ARROW_NAME)

	if not root or not arrow then
		hideAllDots()
		activeWaypoints    = {}
		activeDotPositions = {}
		lastCustomer       = nil
		isDriving          = false
		return
	end

	local customer = findAssignedCustomer(root)
	if not customer then
		hideAllDots()
		activeWaypoints    = {}
		activeDotPositions = {}
		isDriving          = false
		return
	end

	local custRoot = customer.PrimaryPart or customer:FindFirstChild("HumanoidRootPart")
	if not custRoot then hideAllDots() return end

	local isNew = customer ~= lastCustomer
	if isNew or (now - lastRecompute) >= RECOMPUTE_RATE then
		lastCustomer  = customer
		lastRecompute = now
		_G._pizzaDeliveryInteracted = false
		local _, mp = getMoped()
		triggerRecompute(mp and mp.Position or root.Position, custRoot.Position, isNew)
	end

	checkStuck(now)
	checkLookahead(now)

	if isDriving then
		stepVehicleDrive(dt, custRoot.Position, ARRIVE_STOP_DIST, function()
			if not _G._pizzaDeliveryInteracted then
				_G._pizzaDeliveryInteracted = true
				fireInteractButton()
				waitForDeliveryThenReturn()
			end
		end)
	end

	renderDots()
end)

LocalPlayer.CharacterRemoving:Connect(function()
	hideAllDots()
	activeWaypoints            = {}
	activeDotPositions         = {}
	lastCustomer               = nil
	isDriving                  = false
	isReturning                = false
	isWaitingDelivery          = false
	isPickingUp                = false
	lastStuckPos               = nil
	verticalVel                = 0
	isGrounded                 = false
	stuckPhase                 = nil
	stuckPhaseTimer            = 0
	prevWaypointPos            = nil
	activeTarget               = nil
	_G._pizzaDeliveryInteracted = false
	_G._pizzaReturnReady        = false
end)
