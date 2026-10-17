--[[
    AuraVisuals  |  Aura Client MM2
    Тип: LocalScript
    Куда класть: StarterPlayer > StarterPlayerScripts  (или StarterGui)

    Что внутри:
      - плавающая кнопка AV (перетаскивается), по нажатию открывается меню
      - вкладки: Крылья, Аура, Одежда, Время, Небо, Погода, Мир, Элементы, Шейдеры, Интерфейс
      - каждая функция включается и выключается переключателем, при выключении всё убирается
      - окно AuraVisuals с FPS и списком активных визуалов
      - RightShift открывает и закрывает меню

    Всё работает только на стороне клиента.
    Для самых красивых теней и света в Studio: Lighting > Technology = Future
    (из скрипта это свойство менять нельзя).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------
-- НАСТРОЙКИ
------------------------------------------------------------------------
local CONFIG = {
	Title = "AuraVisuals",
	MenuTitle = "Aura Client MM2",
	ToggleKey = Enum.KeyCode.RightShift,

	-- Звуки (необязательно). Вставьте свой id вида "rbxassetid://123456".
	RainSoundId = "",
	ThunderSoundId = "",

	-- Если капли дождя выглядят широкими, а не вытянутыми, поменяйте знак.
	RainSquash = -0.9,
}

local THEME = {
	bg = Color3.fromRGB(14, 14, 22),
	panel = Color3.fromRGB(21, 21, 33),
	row = Color3.fromRGB(28, 28, 43),
	rowHover = Color3.fromRGB(36, 36, 56),
	accent = Color3.fromRGB(124, 92, 255),
	accent2 = Color3.fromRGB(64, 200, 255),
	text = Color3.fromRGB(236, 236, 246),
	sub = Color3.fromRGB(138, 138, 166),
	off = Color3.fromRGB(58, 58, 80),
	danger = Color3.fromRGB(190, 60, 80),
}

local FAST = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

------------------------------------------------------------------------
-- УТИЛИТЫ
------------------------------------------------------------------------
local function cam()
	return Workspace.CurrentCamera
end

local function tween(obj, info, props)
	local t = TweenService:Create(obj, info, props)
	t:Play()
	return t
end

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function kp(t, v)
	return NumberSequenceKeypoint.new(t, v)
end

local function fade(a, b)
	return NumberSequence.new({ kp(0, a), kp(1, b) })
end

local function rainbowSequence()
	local pts = {}
	for i = 0, 6 do
		table.insert(pts, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 7, 0.75, 1)))
	end
	return ColorSequence.new(pts)
end

-- Корзина для очистки: Instance, соединения и функции
local Trash = {}
Trash.__index = Trash

function Trash.new()
	return setmetatable({ items = {} }, Trash)
end

function Trash:add(x)
	table.insert(self.items, x)
	return x
end

function Trash:clean()
	for i = #self.items, 1, -1 do
		local x = self.items[i]
		local t = typeof(x)
		if t == "Instance" then
			pcall(function()
				x:Destroy()
			end)
		elseif t == "RBXScriptConnection" then
			x:Disconnect()
		elseif t == "function" then
			pcall(x)
		end
	end
	table.clear(self.items)
end

------------------------------------------------------------------------
-- МЕНЕДЖЕР ОСВЕЩЕНИЯ (стек значений: выключение возвращает прошлое значение)
------------------------------------------------------------------------
local Env = { orig = {}, stacks = {} }

local function envApply(prop)
	local stack = Env.stacks[prop]
	local top = stack and stack[#stack]
	local value
	if top then
		value = top.value
	else
		value = Env.orig[prop]
	end
	if value ~= nil then
		pcall(function()
			Lighting[prop] = value
		end)
	end
end

function Env.set(owner, prop, value)
	if Env.orig[prop] == nil then
		local ok, cur = pcall(function()
			return Lighting[prop]
		end)
		if not ok then
			return
		end
		Env.orig[prop] = cur
	end
	local stack = Env.stacks[prop]
	if not stack then
		stack = {}
		Env.stacks[prop] = stack
	end
	for _, e in ipairs(stack) do
		if e.owner == owner then
			e.value = value
			envApply(prop)
			return
		end
	end
	table.insert(stack, { owner = owner, value = value })
	envApply(prop)
end

function Env.clear(owner)
	for prop, stack in pairs(Env.stacks) do
		local changed = false
		for i = #stack, 1, -1 do
			if stack[i].owner == owner then
				table.remove(stack, i)
				changed = true
			end
		end
		if changed then
			envApply(prop)
		end
	end
end

-- Слои для Atmosphere и Sky: свои объекты, оригинальные временно прячутся
local function Layered(className, name, defaults)
	local L = { users = {}, order = {}, inst = nil, stashed = {} }

	local function refresh()
		if #L.order == 0 then
			if L.inst then
				L.inst:Destroy()
				L.inst = nil
			end
			for _, o in ipairs(L.stashed) do
				o.Parent = Lighting
			end
			L.stashed = {}
			return
		end
		if not L.inst then
			for _, c in ipairs(Lighting:GetChildren()) do
				if c:IsA(className) then
					table.insert(L.stashed, c)
					c.Parent = nil
				end
			end
			L.inst = Instance.new(className)
			L.inst.Name = name
			L.inst.Parent = Lighting
		end
		for k, v in pairs(defaults) do
			L.inst[k] = v
		end
		for _, owner in ipairs(L.order) do
			for k, v in pairs(L.users[owner]) do
				L.inst[k] = v
			end
		end
	end

	function L.set(owner, props)
		if not L.users[owner] then
			table.insert(L.order, owner)
		end
		L.users[owner] = props
		refresh()
	end

	function L.clear(owner)
		if L.users[owner] then
			L.users[owner] = nil
			table.remove(L.order, table.find(L.order, owner))
			refresh()
		end
	end

	return L
end

local AtmoLayer = Layered("Atmosphere", "AV_Atmosphere", {
	Density = 0.3,
	Offset = 0,
	Color = Color3.fromRGB(199, 170, 107),
	Decay = Color3.fromRGB(92, 60, 13),
	Glare = 0,
	Haze = 0,
})

local SkyLayer = Layered("Sky", "AV_Sky", {
	StarCount = 3000,
	CelestialBodiesShown = true,
	SunAngularSize = 21,
	MoonAngularSize = 11,
})

------------------------------------------------------------------------
-- РЕЕСТР ФУНКЦИЙ
------------------------------------------------------------------------
local Features = {}
local ById = {}
local Changed = Instance.new("BindableEvent")

local CATEGORIES = {
	"Крылья", "Аура", "Одежда", "Время", "Небо",
	"Погода", "Мир", "Элементы", "Шейдеры", "Интерфейс",
}

local function register(def)
	def.enabled = false
	def.ctx = nil
	table.insert(Features, def)
	ById[def.id] = def
end

local function charParts()
	local char = player.Character
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
	local head = char:FindFirstChild("Head")
	if hum and root and torso and head then
		return char, hum, root, torso, head
	end
	return nil
end

local function buildCtx(f)
	local ctx = { feature = f, alive = true, trash = Trash.new() }
	ctx.trash:add(function()
		ctx.alive = false
		Env.clear(ctx)
		AtmoLayer.clear(ctx)
		SkyLayer.clear(ctx)
	end)
	ctx.light = function(prop, value)
		Env.set(ctx, prop, value)
	end
	ctx.atmo = function(props)
		AtmoLayer.set(ctx, props)
	end
	ctx.sky = function(props)
		SkyLayer.set(ctx, props)
	end
	return ctx
end

local function startFeature(f)
	if f.char and not charParts() then
		return true -- соберётся при появлении персонажа
	end
	local ctx = buildCtx(f)
	f.ctx = ctx
	local ok, err = pcall(f.enable, ctx)
	if not ok then
		warn("[AuraVisuals] " .. f.name .. ": " .. tostring(err))
		ctx.trash:clean()
		f.ctx = nil
		return false
	end
	return true
end

local function disableFeature(f)
	if not f.enabled then
		return
	end
	f.enabled = false
	if f.ctx then
		f.ctx.trash:clean()
		f.ctx = nil
	end
	Changed:Fire(f)
end

local function enableFeature(f)
	if f.enabled then
		return
	end
	if f.group then
		for _, other in ipairs(Features) do
			if other ~= f and other.group == f.group and other.enabled then
				disableFeature(other)
			end
		end
	end
	f.enabled = true
	if not startFeature(f) then
		f.enabled = false
	end
	Changed:Fire(f)
end

local function toggleFeature(f)
	if f.enabled then
		disableFeature(f)
	else
		enableFeature(f)
	end
end

local function disableAll()
	for _, f in ipairs(Features) do
		if f.enabled and f.cat ~= "Интерфейс" then
			disableFeature(f)
		end
	end
end

local function onFrame(ctx, fn)
	ctx.trash:add(RunService.RenderStepped:Connect(fn))
end

local function postfx(ctx, className, props)
	local e = Instance.new(className)
	for k, v in pairs(props) do
		e[k] = v
	end
	e.Parent = Lighting
	ctx.trash:add(e)
	return e
end

local function loopSound(ctx, id, volume)
	if id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = volume
	s.Parent = Workspace
	s:Play()
	ctx.trash:add(s)
end

------------------------------------------------------------------------
-- ПОМОЩНИКИ ДЛЯ ПЕРСОНАЖА
------------------------------------------------------------------------
local function mkPart(props)
	local p = Instance.new("Part")
	p.Name = "AV_Part"
	p.Anchored = false
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.Neon
	for k, v in pairs(props) do
		p[k] = v
	end
	return p
end

local function weld(p0, p1, c0)
	local w = Instance.new("Weld")
	w.Part0 = p0
	w.Part1 = p1
	w.C0 = c0 or CFrame.identity
	w.Parent = p1
	return w
end

local function hub(ctx, char, parent, size, c0)
	local p = mkPart({ Name = "AV_Hub", Size = size, Transparency = 1 })
	p.Parent = char
	local w = weld(parent, p, c0)
	ctx.trash:add(p)
	return p, w
end

-- кольцо из сегментов вокруг центра (сегменты вытянуты по касательной, ось Z)
local function ringOf(ctx, char, parent, c0, count, radius, size, color, material)
	local center = mkPart({ Name = "AV_Ring", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1 })
	center.Parent = char
	local w = weld(parent, center, c0)
	ctx.trash:add(center)
	for i = 1, count do
		local a = (i / count) * math.pi * 2
		local seg = mkPart({ Name = "AV_Seg", Size = size, Color = color, Material = material or Enum.Material.Neon })
		seg.Parent = char
		weld(center, seg, CFrame.new(math.cos(a) * radius, 0, math.sin(a) * radius) * CFrame.Angles(0, -a, 0))
	end
	return w
end

local function emitter(parent, cfg)
	local e = Instance.new("ParticleEmitter")
	e.Rate = cfg.rate
	e.Lifetime = NumberRange.new(cfg.life[1], cfg.life[2])
	e.Speed = NumberRange.new(cfg.speed[1], cfg.speed[2])
	e.SpreadAngle = Vector2.new(cfg.spread, cfg.spread)
	e.Size = cfg.size
	e.Color = cfg.color
	e.Transparency = cfg.transparency or fade(0.1, 1)
	e.LightEmission = cfg.light or 1
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-80, 80)
	e.EmissionDirection = cfg.dir or Enum.NormalId.Top
	e.Acceleration = cfg.accel or Vector3.zero
	e.Parent = parent
	return e
end

------------------------------------------------------------------------
-- КРЫЛЬЯ
------------------------------------------------------------------------
local function wings(id, name, desc, style)
	register({
		id = id, name = name, desc = desc, cat = "Крылья", group = "wings", char = true,
		enable = function(ctx)
			local char, _, root, torso = charParts()
			local pivots, feathers = {}, {}

			for _, side in ipairs({ -1, 1 }) do
				local pivot = mkPart({ Name = "AV_WingPivot", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1 })
				pivot.Parent = char
				ctx.trash:add(pivot)
				local w = weld(torso, pivot, CFrame.identity)
				table.insert(pivots, { weld = w, side = side })

				for i = 1, style.feathers do
					local t = (i - 1) / (style.feathers - 1)
					local ang = math.rad(style.angleStart + t * style.angleSpan)
					local len = style.length * (1 - 0.5 * math.abs(t - 0.5))
					local f = mkPart({
						Name = "AV_Feather",
						Size = Vector3.new(style.width, len, 0.08),
						Material = style.material or Enum.Material.Neon,
						Color = style.color(t, i, 0),
					})
					f.Parent = char
					weld(pivot, f, CFrame.Angles(0, 0, -side * ang) * CFrame.new(0, len / 2, 0))
					table.insert(feathers, { part = f, t = t, i = i })
				end
			end

			local sz = torso.Size
			onFrame(ctx, function()
				local time = os.clock()
				local flat = root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
				local speed = style.flapSpeed * (1 + math.min(flat.Magnitude / 30, 1))
				local flap = math.sin(time * speed) * style.flapAmount
				for _, p in ipairs(pivots) do
					p.weld.C0 = CFrame.new(p.side * 0.35, sz.Y * 0.1, sz.Z / 2 + 0.1)
						* CFrame.Angles(0, -p.side * math.rad(style.base + flap), 0)
				end
				if style.animated then
					for _, f in ipairs(feathers) do
						f.part.Color = style.color(f.t, f.i, time)
					end
				end
			end)
		end,
	})
end

wings("wing_angel", "Крылья ангела", "Светлые крылья с мягким взмахом", {
	feathers = 7, length = 4.4, width = 0.7, angleStart = 5, angleSpan = 95,
	base = 24, flapAmount = 12, flapSpeed = 2.2,
	color = function(t)
		return Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(255, 232, 190), t)
	end,
})

wings("wing_demon", "Крылья демона", "Тёмно-красные острые крылья", {
	feathers = 6, length = 5, width = 0.45, angleStart = 15, angleSpan = 85,
	base = 30, flapAmount = 9, flapSpeed = 1.7,
	color = function(t)
		return Color3.fromRGB(150, 0, 20):Lerp(Color3.fromRGB(35, 0, 8), t)
	end,
})

wings("wing_cyber", "Крылья Cyber", "Переливающиеся неоновые крылья", {
	feathers = 8, length = 4.6, width = 0.55, angleStart = 5, angleSpan = 100,
	base = 26, flapAmount = 14, flapSpeed = 2.6, animated = true,
	color = function(t, i, time)
		return Color3.fromHSV((0.5 + 0.25 * math.sin(time * 0.8 + t * 3)) % 1, 0.75, 1)
	end,
})

wings("wing_fire", "Огненные крылья", "Крылья от жёлтого до красного", {
	feathers = 8, length = 4.8, width = 0.5, angleStart = 8, angleSpan = 95,
	base = 28, flapAmount = 11, flapSpeed = 2.0,
	color = function(t)
		return Color3.fromRGB(255, 220, 70):Lerp(Color3.fromRGB(220, 30, 0), t)
	end,
})

------------------------------------------------------------------------
-- АУРЫ
------------------------------------------------------------------------
local function aura(id, name, desc, cfg)
	register({
		id = id, name = name, desc = desc, cat = "Аура", char = true,
		enable = function(ctx)
			local char, _, root = charParts()
			local h = hub(ctx, char, root, Vector3.new(3, 5, 3), CFrame.identity)
			emitter(h, cfg)
			if cfg.glow then
				new("PointLight", { Color = cfg.glow, Range = 16, Brightness = 2 }, h)
			end
		end,
	})
end

aura("aura_fire", "Огненная аура", "Языки пламени вокруг персонажа", {
	rate = 70, life = { 0.7, 1.3 }, speed = { 3, 6 }, spread = 12, size = fade(1.8, 0.2),
	color = ColorSequence.new(Color3.fromRGB(255, 190, 60), Color3.fromRGB(210, 30, 0)),
	accel = Vector3.new(0, 3, 0), glow = Color3.fromRGB(255, 120, 30),
})

aura("aura_energy", "Энергетическая аура", "Голубые частицы энергии", {
	rate = 55, life = { 1, 1.8 }, speed = { 1, 3 }, spread = 30, size = fade(0.55, 0),
	color = ColorSequence.new(Color3.fromRGB(90, 220, 255), Color3.fromRGB(80, 90, 255)),
	accel = Vector3.new(0, 4, 0), glow = Color3.fromRGB(80, 180, 255),
})

aura("aura_dark", "Тёмная аура", "Фиолетовый дым", {
	rate = 30, life = { 1.5, 2.5 }, speed = { 0.5, 1.5 }, spread = 60, size = fade(3, 5),
	color = ColorSequence.new(Color3.fromRGB(100, 0, 170), Color3.fromRGB(10, 0, 20)),
	transparency = fade(0.55, 1), light = 0.2, glow = Color3.fromRGB(120, 0, 200),
})

aura("aura_stars", "Звёздная пыль", "Золотые искры вокруг тела", {
	rate = 45, life = { 1.5, 2.5 }, speed = { 0, 1 }, spread = 180, size = fade(0.35, 0),
	color = ColorSequence.new(Color3.fromRGB(255, 215, 90), Color3.fromRGB(255, 255, 255)),
	accel = Vector3.new(0, 1.5, 0), glow = Color3.fromRGB(255, 210, 90),
})

aura("aura_ice", "Ледяная аура", "Холодные снежинки", {
	rate = 40, life = { 1.5, 2.5 }, speed = { 1, 2 }, spread = 90, size = fade(0.6, 0),
	color = ColorSequence.new(Color3.fromRGB(210, 245, 255), Color3.fromRGB(110, 190, 255)),
	accel = Vector3.new(0, -2, 0), glow = Color3.fromRGB(150, 210, 255),
})

register({
	id = "aura_orbs", name = "Орбиты", desc = "Три светящихся шара летают вокруг", cat = "Аура", char = true,
	enable = function(ctx)
		local char, _, root = charParts()
		local colors = { Color3.fromRGB(124, 92, 255), Color3.fromRGB(64, 200, 255), Color3.fromRGB(255, 90, 190) }
		local orbs = {}
		for i = 1, 3 do
			local orb = mkPart({
				Name = "AV_Orb", Shape = Enum.PartType.Ball, Size = Vector3.new(0.7, 0.7, 0.7), Color = colors[i],
			})
			orb.Parent = char
			ctx.trash:add(orb)
			local w = weld(root, orb, CFrame.identity)
			local a0 = new("Attachment", { Position = Vector3.new(0, 0.3, 0) }, orb)
			local a1 = new("Attachment", { Position = Vector3.new(0, -0.3, 0) }, orb)
			new("Trail", {
				Attachment0 = a0, Attachment1 = a1, Lifetime = 0.6, LightEmission = 1,
				Color = ColorSequence.new(colors[i]), Transparency = fade(0, 1), FaceCamera = true,
			}, orb)
			new("PointLight", { Color = colors[i], Range = 8, Brightness = 1.5 }, orb)
			orbs[i] = w
		end
		onFrame(ctx, function()
			local t = os.clock()
			for i, w in ipairs(orbs) do
				local a = t * 1.8 + (i - 1) * 2.094
				w.C0 = CFrame.new(math.cos(a) * 3.6, math.sin(t * 2 + i) * 0.8, math.sin(a) * 3.6)
			end
		end)
	end,
})

register({
	id = "aura_rings", name = "Энергетические кольца", desc = "Два вращающихся кольца света", cat = "Аура", char = true,
	enable = function(ctx)
		local char, _, root = charParts()
		local r1 = ringOf(ctx, char, root, CFrame.identity, 36, 3.2, Vector3.new(0.12, 0.12, 0.6), Color3.fromRGB(64, 200, 255))
		local r2 = ringOf(ctx, char, root, CFrame.identity, 44, 4, Vector3.new(0.12, 0.12, 0.6), Color3.fromRGB(150, 100, 255))
		onFrame(ctx, function()
			local t = os.clock()
			r1.C0 = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(18), t * 1.4, 0)
			r2.C0 = CFrame.new(0, 0.4, 0) * CFrame.Angles(math.rad(-22), -t * 1.0, math.rad(10))
		end)
	end,
})

register({
	id = "aura_trail", name = "Радужный шлейф", desc = "Яркий след при движении", cat = "Аура", char = true,
	enable = function(ctx)
		local _, _, root = charParts()
		local a0 = new("Attachment", { Name = "AV_T0", Position = Vector3.new(0, 1.2, 0) }, root)
		local a1 = new("Attachment", { Name = "AV_T1", Position = Vector3.new(0, -1.2, 0) }, root)
		ctx.trash:add(a0)
		ctx.trash:add(a1)
		local tr = new("Trail", {
			Attachment0 = a0, Attachment1 = a1, Lifetime = 0.8, LightEmission = 1, MinLength = 0.05,
			Color = rainbowSequence(), Transparency = fade(0.1, 1), FaceCamera = true,
		}, root)
		ctx.trash:add(tr)
	end,
})

register({
	id = "aura_outline", name = "Светящийся контур", desc = "Переливающаяся обводка персонажа", cat = "Аура", char = true,
	enable = function(ctx)
		local char = charParts()
		local hl = new("Highlight", {
			Adornee = char, FillTransparency = 0.8, OutlineTransparency = 0,
			DepthMode = Enum.HighlightDepthMode.Occluded,
		}, char)
		ctx.trash:add(hl)
		onFrame(ctx, function()
			local h = (os.clock() * 0.15) % 1
			hl.FillColor = Color3.fromHSV(h, 0.7, 1)
			hl.OutlineColor = Color3.fromHSV((h + 0.1) % 1, 0.5, 1)
		end)
	end,
})

------------------------------------------------------------------------
-- ВИЗУАЛЬНАЯ ОДЕЖДА
------------------------------------------------------------------------
local function suit(id, name, desc, apply)
	register({
		id = id, name = name, desc = desc, cat = "Одежда", group = "suit", char = true,
		enable = function(ctx)
			local char = charParts()
			local saved = {}
			for _, p in ipairs(char:GetChildren()) do
				if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" and p.Name:sub(1, 3) ~= "AV_" then
					saved[p] = { Color = p.Color, Material = p.Material, Transparency = p.Transparency }
					apply(p)
				end
			end
			ctx.trash:add(function()
				for p, s in pairs(saved) do
					p.Color = s.Color
					p.Material = s.Material
					p.Transparency = s.Transparency
				end
			end)
		end,
	})
end

suit("suit_gold", "Золотой костюм", "Тело покрывается золотым металлом", function(p)
	p.Color = Color3.fromRGB(255, 200, 70)
	p.Material = Enum.Material.Metal
end)

suit("suit_neon", "Неоновый костюм", "Светящееся голубое тело", function(p)
	p.Color = Color3.fromRGB(64, 200, 255)
	p.Material = Enum.Material.Neon
end)

suit("suit_ghost", "Призрачный костюм", "Полупрозрачное энергетическое тело", function(p)
	p.Color = Color3.fromRGB(170, 140, 255)
	p.Material = Enum.Material.ForceField
	p.Transparency = 0.25
end)

register({
	id = "cloth_cape", name = "Королевская накидка", desc = "Накидка, реагирующая на бег", cat = "Одежда", char = true,
	enable = function(ctx)
		local char, _, root, torso = charParts()
		local cape = mkPart({
			Name = "AV_Cape", Size = Vector3.new(2.1, 3.4, 0.1),
			Color = Color3.fromRGB(125, 10, 35), Material = Enum.Material.Fabric,
		})
		cape.Parent = char
		ctx.trash:add(cape)
		local trim = mkPart({ Name = "AV_CapeTrim", Size = Vector3.new(2.1, 0.15, 0.14), Color = Color3.fromRGB(255, 205, 80) })
		trim.Parent = char
		weld(cape, trim, CFrame.new(0, -1.7, 0))
		local topY = torso.Size.Y / 2 - 0.15
		local backZ = torso.Size.Z / 2 + 0.1
		local w = weld(torso, cape, CFrame.new(0, topY, backZ))
		onFrame(ctx, function()
			local flat = (root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
			local k = math.min(flat / 16, 1.4)
			local swing = -(k * 0.55 + 0.08 + math.sin(os.clock() * 3) * 0.04 * (1 + k))
			w.C0 = CFrame.new(0, topY, backZ) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, -1.7, 0)
		end)
	end,
})

register({
	id = "cloth_pads", name = "Наплечники", desc = "Светящиеся наплечники с шипами", cat = "Одежда", char = true,
	enable = function(ctx)
		local char, _, _, torso = charParts()
		for _, side in ipairs({ -1, 1 }) do
			local pad = mkPart({
				Name = "AV_Pad", Shape = Enum.PartType.Ball, Size = Vector3.new(1.3, 1.3, 1.3),
				Color = Color3.fromRGB(124, 92, 255),
			})
			pad.Parent = char
			ctx.trash:add(pad)
			weld(torso, pad, CFrame.new(side * (torso.Size.X / 2 + 0.45), torso.Size.Y / 2 - 0.1, 0))
			local spike = mkPart({ Name = "AV_Spike", Size = Vector3.new(0.25, 0.9, 0.25), Color = Color3.fromRGB(64, 200, 255) })
			spike.Parent = char
			weld(pad, spike, CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, -side * 0.35))
		end
	end,
})

register({
	id = "cloth_halo", name = "Нимб", desc = "Вращающееся золотое кольцо над головой", cat = "Одежда", char = true,
	enable = function(ctx)
		local char, _, _, _, head = charParts()
		local base = CFrame.new(0, head.Size.Y / 2 + 0.9, 0)
		local w = ringOf(ctx, char, head, base, 24, 1.1, Vector3.new(0.12, 0.1, 0.32), Color3.fromRGB(255, 220, 110))
		onFrame(ctx, function()
			w.C0 = base * CFrame.Angles(math.rad(6), os.clock() * 1.2, 0)
		end)
	end,
})

register({
	id = "cloth_crown", name = "Золотая корона", desc = "Корона с острыми зубцами", cat = "Одежда", char = true,
	enable = function(ctx)
		local char, _, _, _, head = charParts()
		local gold = Color3.fromRGB(255, 205, 80)
		ringOf(ctx, char, head, CFrame.new(0, head.Size.Y / 2 + 0.25, 0), 16, 0.78, Vector3.new(0.12, 0.3, 0.31), gold)
		ringOf(ctx, char, head, CFrame.new(0, head.Size.Y / 2 + 0.7, 0), 8, 0.78, Vector3.new(0.14, 0.7, 0.2), gold)
	end,
})

------------------------------------------------------------------------
-- ВРЕМЯ СУТОК
------------------------------------------------------------------------
local presets = {
	{ "time_dawn", "Рассвет", "Утро, 6:00", 6 },
	{ "time_day", "День", "Яркий день, 13:00", 13 },
	{ "time_sunset", "Закат", "Золотой час, 17:50", 17.83 },
	{ "time_night", "Ночь", "Полночь, 0:00", 0 },
}
for _, p in ipairs(presets) do
	register({
		id = p[1], name = p[2], desc = p[3], cat = "Время", group = "time",
		enable = function(ctx)
			ctx.light("ClockTime", p[4])
		end,
	})
end

register({
	id = "time_flow", name = "Течение времени", desc = "День и ночь сменяют друг друга", cat = "Время",
	enable = function(ctx)
		local t = Lighting.ClockTime
		ctx.trash:add(RunService.Heartbeat:Connect(function(dt)
			t = (t + dt * 0.25) % 24
			ctx.light("ClockTime", t)
		end))
	end,
})

------------------------------------------------------------------------
-- НЕБО
------------------------------------------------------------------------
register({
	id = "sky_real", name = "Реалистичное небо", desc = "Атмосфера, звёзды, мягкий свет", cat = "Небо", group = "sky",
	enable = function(ctx)
		ctx.sky({ StarCount = 5000, CelestialBodiesShown = true, SunAngularSize = 18, MoonAngularSize = 14 })
		ctx.atmo({
			Density = 0.32, Offset = 0.2, Color = Color3.fromRGB(199, 215, 235),
			Decay = Color3.fromRGB(106, 112, 125), Glare = 0.35, Haze = 1.6,
		})
		ctx.light("EnvironmentDiffuseScale", 1)
		ctx.light("EnvironmentSpecularScale", 1)
	end,
})

register({
	id = "sky_golden", name = "Золотой закат", desc = "Тёплая атмосфера и длинный свет", cat = "Небо", group = "sky",
	enable = function(ctx)
		ctx.light("ClockTime", 17.7)
		ctx.sky({ StarCount = 3000, SunAngularSize = 26 })
		ctx.atmo({
			Density = 0.4, Offset = 0.35, Color = Color3.fromRGB(255, 190, 140),
			Decay = Color3.fromRGB(255, 110, 60), Glare = 0.8, Haze = 2.2,
		})
	end,
})

register({
	id = "sky_night", name = "Звёздная ночь", desc = "Тёмное небо с тысячами звёзд", cat = "Небо", group = "sky",
	enable = function(ctx)
		ctx.light("ClockTime", 0)
		ctx.light("OutdoorAmbient", Color3.fromRGB(55, 65, 100))
		ctx.sky({ StarCount = 5000, MoonAngularSize = 22 })
		ctx.atmo({
			Density = 0.15, Offset = 0, Color = Color3.fromRGB(80, 100, 160),
			Decay = Color3.fromRGB(10, 15, 35), Glare = 0, Haze = 0.3,
		})
	end,
})

register({
	id = "sky_space", name = "Космос", desc = "Чёрное небо без атмосферы", cat = "Небо", group = "sky",
	enable = function(ctx)
		ctx.light("ClockTime", 0)
		ctx.light("OutdoorAmbient", Color3.fromRGB(70, 70, 110))
		ctx.light("Ambient", Color3.fromRGB(40, 40, 65))
		ctx.sky({ StarCount = 5000, CelestialBodiesShown = false })
		ctx.atmo({ Density = 0, Offset = 0, Glare = 0, Haze = 0 })
	end,
})

register({
	id = "sky_synth", name = "Синтвейв", desc = "Розово-фиолетовое неоновое небо", cat = "Небо", group = "sky",
	enable = function(ctx)
		ctx.light("ClockTime", 18.4)
		ctx.sky({ StarCount = 4000, SunAngularSize = 34 })
		ctx.atmo({
			Density = 0.42, Offset = 0.3, Color = Color3.fromRGB(255, 90, 200),
			Decay = Color3.fromRGB(90, 30, 200), Glare = 1, Haze = 2.4,
		})
	end,
})

register({
	id = "blackhole", name = "Чёрная дыра", desc = "Огромная чёрная дыра в небе (лучше ночью)", cat = "Небо",
	enable = function(ctx)
		local folder = Instance.new("Folder")
		folder.Name = "AV_BlackHole"
		folder.Parent = Workspace
		ctx.trash:add(folder)

		local function part(props)
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.CastShadow = false
			for k, v in pairs(props) do
				p[k] = v
			end
			p.Parent = folder
			return p
		end

		local core = part({
			Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.new(130, 130, 130),
			Color = Color3.new(0, 0, 0), Material = Enum.Material.SmoothPlastic,
		})
		local halo = part({
			Name = "Halo", Shape = Enum.PartType.Ball, Size = Vector3.new(158, 158, 158),
			Color = Color3.fromRGB(255, 140, 40), Material = Enum.Material.Neon, Transparency = 0.86,
		})
		local disk = part({
			Name = "Disk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 480, 480),
			Transparency = 1,
		})

		local gradients = {}
		local function addRing(gui, scale, thickness, c1, c2, transparency)
			local ring = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(scale, scale), BackgroundTransparency = 1,
			}, gui)
			new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
			local stroke = new("UIStroke", { Thickness = thickness, Transparency = transparency, Color = Color3.new(1, 1, 1) }, ring)
			local g = new("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, c1), ColorSequenceKeypoint.new(0.5, c2), ColorSequenceKeypoint.new(1, c1),
				}),
			}, stroke)
			table.insert(gradients, g)
		end

		for _, face in ipairs({ Enum.NormalId.Right, Enum.NormalId.Left }) do
			local gui = new("SurfaceGui", {
				Face = face, SizingMode = Enum.SurfaceGuiSizingMode.FixedSize, CanvasSize = Vector2.new(1024, 1024),
				LightInfluence = 0, Brightness = 2, ResetOnSpawn = false,
			}, disk)
			addRing(gui, 0.34, 6, Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 220, 170), 0.05)
			addRing(gui, 0.42, 46, Color3.fromRGB(255, 240, 210), Color3.fromRGB(255, 160, 60), 0.15)
			addRing(gui, 0.58, 70, Color3.fromRGB(255, 170, 60), Color3.fromRGB(230, 60, 20), 0.35)
			addRing(gui, 0.8, 50, Color3.fromRGB(230, 70, 30), Color3.fromRGB(120, 20, 60), 0.65)
		end

		local dir = Vector3.new(0.45, 0.28, -0.85).Unit
		local DIST = 1000
		onFrame(ctx, function()
			local c = cam()
			if not c then
				return
			end
			local pos = c.CFrame.Position + dir * DIST
			core.CFrame = CFrame.new(pos)
			halo.CFrame = CFrame.new(pos)
			disk.CFrame = CFrame.new(pos) * CFrame.Angles(0.5, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2)
			local t = os.clock()
			for i, g in ipairs(gradients) do
				g.Rotation = (t * (18 + (i % 4) * 12) * (i % 2 == 0 and 1 or -1)) % 360
			end
		end)
	end,
})

------------------------------------------------------------------------
-- ПОГОДА
------------------------------------------------------------------------
local function overcast(ctx, k)
	ctx.atmo({
		Density = 0.3 + 0.2 * k, Offset = 0, Color = Color3.fromRGB(150, 155, 165),
		Decay = Color3.fromRGB(110, 115, 125), Glare = 0, Haze = 2 + 2 * k,
	})
	ctx.light("Brightness", 1.5 - 0.7 * k)
	ctx.light("OutdoorAmbient", Color3.fromRGB(70 - 15 * k, 78 - 15 * k, 92 - 15 * k))
	ctx.light("FogColor", Color3.fromRGB(95 - 20 * k, 102 - 20 * k, 115 - 20 * k))
	ctx.light("FogStart", 0)
	ctx.light("FogEnd", 900 - 350 * k)
	postfx(ctx, "ColorCorrectionEffect", { Saturation = -0.12 - 0.12 * k, Brightness = -0.03 * k, Contrast = 0.05 })
end

local function precip(ctx, cfg)
	local p = Instance.new("Part")
	p.Name = "AV_Precip"
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(cfg.area, 1, cfg.area)
	p.Parent = Workspace
	ctx.trash:add(p)
	local e = emitter(p, cfg.emitter)
	e.LockedToPart = false
	if cfg.orientation then
		e.Orientation = cfg.orientation
	end
	if cfg.squash then
		e.Squash = NumberSequence.new(cfg.squash)
	end
	onFrame(ctx, function()
		local c = cam()
		if c then
			p.CFrame = CFrame.new(c.CFrame.Position + Vector3.new(0, cfg.height, 0))
		end
	end)
end

local function rainEmitter(rate, speed)
	return {
		rate = rate, life = { 0.8, 1 }, speed = { speed, speed + 25 }, spread = 2, size = NumberSequence.new(0.45),
		color = ColorSequence.new(Color3.fromRGB(190, 205, 225)), transparency = fade(0.35, 0.6), light = 0.2,
		dir = Enum.NormalId.Bottom, accel = Vector3.new(-6, -30, 0),
	}
end

register({
	id = "wx_rain", name = "Реалистичный дождь", desc = "Дождь, пасмурное небо и туман", cat = "Погода",
	enable = function(ctx)
		overcast(ctx, 0.5)
		precip(ctx, {
			area = 120, height = 42, orientation = Enum.ParticleOrientation.VelocityParallel, squash = CONFIG.RainSquash,
			emitter = rainEmitter(2200, 95),
		})
		loopSound(ctx, CONFIG.RainSoundId, 0.5)
	end,
})

register({
	id = "wx_storm", name = "Гроза", desc = "Ливень, тьма и вспышки молний", cat = "Погода",
	enable = function(ctx)
		overcast(ctx, 1)
		precip(ctx, {
			area = 130, height = 42, orientation = Enum.ParticleOrientation.VelocityParallel, squash = CONFIG.RainSquash,
			emitter = rainEmitter(3600, 110),
		})
		loopSound(ctx, CONFIG.RainSoundId, 0.8)
		local flash = postfx(ctx, "ColorCorrectionEffect", { Brightness = 0 })
		task.spawn(function()
			while ctx.alive do
				task.wait(math.random(50, 110) / 10)
				if not ctx.alive then
					break
				end
				for _ = 1, math.random(1, 3) do
					tween(flash, TweenInfo.new(0.05), { Brightness = 0.55 })
					task.wait(0.07)
					tween(flash, TweenInfo.new(0.25), { Brightness = 0 })
					task.wait(math.random(8, 20) / 100)
				end
				if CONFIG.ThunderSoundId ~= "" and ctx.alive then
					local s = Instance.new("Sound")
					s.SoundId = CONFIG.ThunderSoundId
					s.Volume = 1
					s.Parent = Workspace
					s:Play()
					game:GetService("Debris"):AddItem(s, 12)
				end
			end
		end)
	end,
})

register({
	id = "wx_snow", name = "Снегопад", desc = "Мягкий снег и светлая дымка", cat = "Погода",
	enable = function(ctx)
		ctx.atmo({
			Density = 0.4, Offset = 0.1, Color = Color3.fromRGB(215, 225, 240),
			Decay = Color3.fromRGB(180, 195, 215), Glare = 0, Haze = 3,
		})
		ctx.light("OutdoorAmbient", Color3.fromRGB(120, 130, 150))
		ctx.light("FogColor", Color3.fromRGB(200, 210, 225))
		ctx.light("FogStart", 0)
		ctx.light("FogEnd", 650)
		precip(ctx, {
			area = 120, height = 36,
			emitter = {
				rate = 900, life = { 4, 5 }, speed = { 6, 10 }, spread = 6, size = fade(0.35, 0.3),
				color = ColorSequence.new(Color3.fromRGB(255, 255, 255)), transparency = fade(0.05, 0.2),
				light = 0.3, dir = Enum.NormalId.Bottom, accel = Vector3.new(3, 0, 2),
			},
		})
	end,
})

register({
	id = "wx_fog", name = "Густой туман", desc = "Плотный серый туман", cat = "Погода",
	enable = function(ctx)
		ctx.atmo({
			Density = 0.55, Offset = 0, Color = Color3.fromRGB(190, 195, 205),
			Decay = Color3.fromRGB(150, 155, 165), Glare = 0, Haze = 4,
		})
		ctx.light("FogColor", Color3.fromRGB(190, 195, 205))
		ctx.light("FogStart", 0)
		ctx.light("FogEnd", 550)
	end,
})

------------------------------------------------------------------------
-- МИР: ЦВЕТОВЫЕ ТОНА
------------------------------------------------------------------------
local function grade(id, name, desc, props)
	register({
		id = id, name = name, desc = desc, cat = "Мир", group = "grade",
		enable = function(ctx)
			postfx(ctx, "ColorCorrectionEffect", props)
		end,
	})
end

grade("grade_cold", "Холодный тон", "Синеватая цветокоррекция", {
	TintColor = Color3.fromRGB(205, 225, 255), Saturation = 0.05, Contrast = 0.1,
})
grade("grade_warm", "Тёплый тон", "Оранжевый вечерний оттенок", {
	TintColor = Color3.fromRGB(255, 225, 190), Saturation = 0.15, Contrast = 0.08,
})
grade("grade_bw", "Чёрно-белый мир", "Классическое кино", {
	Saturation = -1, Contrast = 0.2,
})
grade("grade_acid", "Кислотный мир", "Сверхнасыщенные цвета", {
	TintColor = Color3.fromRGB(235, 255, 235), Saturation = 0.8, Contrast = 0.2,
})

register({
	id = "grade_rainbow", name = "Радужный мир", desc = "Цвета плавно меняются по кругу", cat = "Мир", group = "grade",
	enable = function(ctx)
		local cc = postfx(ctx, "ColorCorrectionEffect", { Saturation = 0.2 })
		onFrame(ctx, function()
			cc.TintColor = Color3.fromHSV((os.clock() * 0.08) % 1, 0.4, 1)
		end)
	end,
})

------------------------------------------------------------------------
-- ЭЛЕМЕНТЫ В МИРЕ
------------------------------------------------------------------------
register({
	id = "el_crystals", name = "Парящие кристаллы", desc = "Кристаллы кружатся вокруг игрока", cat = "Элементы",
	enable = function(ctx)
		local folder = Instance.new("Folder")
		folder.Name = "AV_Crystals"
		folder.Parent = Workspace
		ctx.trash:add(folder)
		local items = {}
		for i = 1, 14 do
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Size = Vector3.new(0.6, 1.4 + math.random() * 0.8, 0.6)
			p.Color = Color3.fromHSV((0.5 + i * 0.045) % 1, 0.7, 1)
			p.Parent = folder
			if i % 3 == 0 then
				new("PointLight", { Color = p.Color, Range = 10, Brightness = 1.5 }, p)
			end
			items[i] = {
				part = p, radius = 7 + math.random() * 9, height = 2 + math.random() * 8,
				speed = 0.25 + math.random() * 0.3, phase = math.random() * 6.28,
			}
		end
		onFrame(ctx, function()
			local char, _, root = charParts()
			local center = root and root.Position or (cam() and cam().CFrame.Position) or Vector3.zero
			local t = os.clock()
			for i, it in ipairs(items) do
				local a = it.phase + t * it.speed
				local pos = center + Vector3.new(math.cos(a) * it.radius, it.height + math.sin(t * 1.5 + i) * 1.2, math.sin(a) * it.radius)
				it.part.CFrame = CFrame.new(pos) * CFrame.Angles(t * 1.3 + i, t + i, 0)
			end
		end)
	end,
})

register({
	id = "el_islands", name = "Парящие острова", desc = "Острова зависают высоко в небе", cat = "Элементы",
	enable = function(ctx)
		local folder = Instance.new("Folder")
		folder.Name = "AV_Islands"
		folder.Parent = Workspace
		ctx.trash:add(folder)

		local _, _, root = charParts()
		local origin = root and root.Position or (cam() and cam().CFrame.Position) or Vector3.zero
		local models = {}

		local function layer(model, base, y, height, diameter, color, material)
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.Shape = Enum.PartType.Cylinder
			p.Size = Vector3.new(height, diameter, diameter)
			p.Color = color
			p.Material = material
			p.CFrame = CFrame.new(base + Vector3.new(0, y, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			p.Parent = model
		end

		for i = 1, 7 do
			local ang = (i / 7) * math.pi * 2 + math.random() * 0.6
			local dist = 150 + math.random() * 120
			local base = origin + Vector3.new(math.cos(ang) * dist, 80 + math.random() * 90, math.sin(ang) * dist)
			local model = Instance.new("Model")
			model.Name = "AV_Island"
			model.Parent = folder
			local s = 0.7 + math.random() * 0.6
			layer(model, base, 0, 2 * s, 31 * s, Color3.fromRGB(88, 150, 70), Enum.Material.Grass)
			layer(model, base, -8 * s, 14 * s, 30 * s, Color3.fromRGB(96, 84, 78), Enum.Material.Slate)
			layer(model, base, -21 * s, 12 * s, 17 * s, Color3.fromRGB(82, 72, 68), Enum.Material.Slate)
			layer(model, base, -32 * s, 10 * s, 7 * s, Color3.fromRGB(70, 62, 60), Enum.Material.Slate)
			local gem = Instance.new("Part")
			gem.Anchored = true
			gem.CanCollide = false
			gem.CanQuery = false
			gem.Material = Enum.Material.Neon
			gem.Color = Color3.fromHSV(math.random(), 0.6, 1)
			gem.Size = Vector3.new(2 * s, 5 * s, 2 * s)
			gem.CFrame = CFrame.new(base + Vector3.new(0, 4 * s, 0)) * CFrame.Angles(0.3, 0.7, 0.2)
			gem.Parent = model
			model.WorldPivot = CFrame.new(base)
			table.insert(models, { model = model, pos = base, phase = math.random() * 6.28 })
		end

		onFrame(ctx, function()
			local t = os.clock()
			for _, m in ipairs(models) do
				m.model:PivotTo(
					CFrame.new(m.pos + Vector3.new(0, math.sin(t * 0.6 + m.phase) * 3, 0)) * CFrame.Angles(0, t * 0.03 + m.phase, 0)
				)
			end
		end)
	end,
})

register({
	id = "el_fireflies", name = "Светлячки", desc = "Мерцающие огоньки в воздухе", cat = "Элементы",
	enable = function(ctx)
		local p = Instance.new("Part")
		p.Name = "AV_Fireflies"
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Transparency = 1
		p.Size = Vector3.new(60, 18, 60)
		p.Parent = Workspace
		ctx.trash:add(p)
		emitter(p, {
			rate = 28, life = { 4, 6 }, speed = { 0.5, 2 }, spread = 180, size = fade(0.5, 0.3),
			color = ColorSequence.new(Color3.fromRGB(220, 255, 130), Color3.fromRGB(255, 230, 120)),
			transparency = NumberSequence.new({ kp(0, 1), kp(0.2, 0.1), kp(0.8, 0.1), kp(1, 1) }),
			dir = Enum.NormalId.Top,
		})
		onFrame(ctx, function()
			local c = cam()
			if c then
				p.CFrame = CFrame.new(c.CFrame.Position + Vector3.new(0, 4, 0))
			end
		end)
	end,
})

------------------------------------------------------------------------
-- ШЕЙДЕРЫ
------------------------------------------------------------------------
local overlayGui = nil -- создаётся ниже вместе с интерфейсом

register({
	id = "sh_real", name = "Реалистичные шейдеры", desc = "Bloom, лучи, глубина резкости, цветокоррекция", cat = "Шейдеры", group = "shpreset",
	enable = function(ctx)
		postfx(ctx, "BloomEffect", { Intensity = 0.35, Size = 28, Threshold = 0.9 })
		postfx(ctx, "SunRaysEffect", { Intensity = 0.12, Spread = 0.8 })
		postfx(ctx, "ColorCorrectionEffect", {
			Contrast = 0.1, Saturation = 0.12, TintColor = Color3.fromRGB(255, 250, 245),
		})
		postfx(ctx, "DepthOfFieldEffect", { FarIntensity = 0.15, FocusDistance = 90, InFocusRadius = 60, NearIntensity = 0 })
		ctx.light("ExposureCompensation", 0.15)
		ctx.light("EnvironmentDiffuseScale", 1)
		ctx.light("EnvironmentSpecularScale", 1)
		ctx.light("GlobalShadows", true)
		ctx.light("ShadowSoftness", 0.15)
	end,
})

register({
	id = "sh_cine", name = "Кинематографичный режим", desc = "Чёрные полосы, плёночный тон, размытие дали", cat = "Шейдеры", group = "shpreset",
	enable = function(ctx)
		postfx(ctx, "ColorCorrectionEffect", {
			Contrast = 0.2, Saturation = -0.05, TintColor = Color3.fromRGB(255, 235, 215),
		})
		postfx(ctx, "BloomEffect", { Intensity = 0.5, Size = 40, Threshold = 0.8 })
		postfx(ctx, "DepthOfFieldEffect", { FarIntensity = 0.25, FocusDistance = 70, InFocusRadius = 40, NearIntensity = 0.1 })
		ctx.light("ExposureCompensation", -0.1)
		for _, top in ipairs({ true, false }) do
			local bar = new("Frame", {
				AnchorPoint = Vector2.new(0, top and 0 or 1), Position = UDim2.fromScale(0, top and 0 or 1),
				Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
			}, overlayGui)
			ctx.trash:add(bar)
			tween(bar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(1, 0, 0.1, 0) })
		end
	end,
})

register({
	id = "sh_neon", name = "Неоновое свечение", desc = "Сильный bloom и насыщенные цвета", cat = "Шейдеры", group = "shpreset",
	enable = function(ctx)
		postfx(ctx, "BloomEffect", { Intensity = 1.2, Size = 40, Threshold = 0.6 })
		postfx(ctx, "ColorCorrectionEffect", { Saturation = 0.35, Contrast = 0.15 })
	end,
})

register({
	id = "sh_bloom", name = "Свечение (Bloom)", desc = "Мягкое свечение ярких объектов", cat = "Шейдеры",
	enable = function(ctx)
		postfx(ctx, "BloomEffect", { Intensity = 0.6, Size = 30, Threshold = 0.85 })
	end,
})

register({
	id = "sh_rays", name = "Солнечные лучи", desc = "Лучи света от солнца", cat = "Шейдеры",
	enable = function(ctx)
		postfx(ctx, "SunRaysEffect", { Intensity = 0.25, Spread = 1 })
	end,
})

register({
	id = "sh_dof", name = "Глубина резкости", desc = "Размытие дальнего плана", cat = "Шейдеры",
	enable = function(ctx)
		postfx(ctx, "DepthOfFieldEffect", { FarIntensity = 0.4, FocusDistance = 55, InFocusRadius = 30, NearIntensity = 0 })
	end,
})

register({
	id = "sh_motion", name = "Размытие движения", desc = "Размытие при быстром повороте камеры", cat = "Шейдеры",
	enable = function(ctx)
		local blur = postfx(ctx, "BlurEffect", { Size = 0 })
		local last = cam() and cam().CFrame.LookVector or Vector3.zAxis
		onFrame(ctx, function()
			local c = cam()
			if not c then
				return
			end
			local look = c.CFrame.LookVector
			local d = (look - last).Magnitude
			last = look
			blur.Size = blur.Size + (math.clamp(d * 450, 0, 18) - blur.Size) * 0.25
		end)
	end,
})

register({
	id = "sh_vignette", name = "Виньетка", desc = "Затемнение по краям экрана", cat = "Шейдеры",
	enable = function(ctx)
		local specs = {
			{ UDim2.fromScale(0, 0), UDim2.fromScale(0.16, 1), 0 },
			{ UDim2.fromScale(0.84, 0), UDim2.fromScale(0.16, 1), 180 },
			{ UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.22), 90 },
			{ UDim2.fromScale(0, 0.78), UDim2.fromScale(1, 0.22), 270 },
		}
		for _, s in ipairs(specs) do
			local f = new("Frame", { Position = s[1], Size = s[2], BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0 }, overlayGui)
			new("UIGradient", { Rotation = s[3], Transparency = fade(0.25, 1) }, f)
			ctx.trash:add(f)
		end
	end,
})

register({
	id = "sh_reflect", name = "Отражения и тени", desc = "Усиленные отражения и мягкие тени", cat = "Шейдеры",
	enable = function(ctx)
		ctx.light("EnvironmentDiffuseScale", 1)
		ctx.light("EnvironmentSpecularScale", 1)
		ctx.light("GlobalShadows", true)
		ctx.light("ShadowSoftness", 0.4)
	end,
})

------------------------------------------------------------------------
-- ИНТЕРФЕЙС
------------------------------------------------------------------------
register({ id = "hud_window", name = "Окно AuraVisuals", desc = "Небольшое окно с названием", cat = "Интерфейс", enable = function() end })
register({ id = "hud_fps", name = "Показывать FPS", desc = "Счётчик кадров в секунду", cat = "Интерфейс", enable = function() end })
register({ id = "hud_list", name = "Список визуалов", desc = "Названия включённых визуалов", cat = "Интерфейс", enable = function() end })

------------------------------------------------------------------------
-- ИНТЕРФЕЙС: ПОСТРОЕНИЕ
------------------------------------------------------------------------
local old = playerGui:FindFirstChild("AuraVisuals")
if old then
	old:Destroy()
end
local oldOverlay = playerGui:FindFirstChild("AV_Overlay")
if oldOverlay then
	oldOverlay:Destroy()
end

local screen = new("ScreenGui", {
	Name = "AuraVisuals", ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 100,
}, playerGui)

overlayGui = new("ScreenGui", {
	Name = "AV_Overlay", ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50,
}, playerGui)

local function makeDraggable(handle, target, onClick)
	local dragging, moved = false, false
	local dragStart, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			dragStart, startPos = input.Position, target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if not moved and onClick then
						onClick()
					end
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			if d.Magnitude > 6 then
				moved = true
			end
			if moved then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end
	end)
end

local function gradientText(label)
	new("UIGradient", {
		Color = ColorSequence.new(THEME.accent, THEME.accent2),
	}, label)
end

-- Плавающая кнопка AV -------------------------------------------------
local fab = new("Frame", {
	Name = "Floating", Size = UDim2.fromOffset(58, 58), Position = UDim2.new(1, -86, 0.5, -29), BackgroundTransparency = 1,
}, screen)

local fabBtn = new("TextButton", {
	Size = UDim2.fromScale(1, 1), BackgroundColor3 = THEME.panel, Text = "AV", Font = Enum.Font.GothamBold,
	TextSize = 20, TextColor3 = THEME.text, AutoButtonColor = false,
}, fab)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, fabBtn)
local fabStroke = new("UIStroke", { Thickness = 2.5, Color = Color3.new(1, 1, 1) }, fabBtn)
local fabGradient = new("UIGradient", { Color = ColorSequence.new(THEME.accent, THEME.accent2) }, fabStroke)
local fabScale = new("UIScale", { Scale = 1 }, fabBtn)

fabBtn.MouseEnter:Connect(function()
	tween(fabScale, FAST, { Scale = 1.1 })
end)
fabBtn.MouseLeave:Connect(function()
	tween(fabScale, FAST, { Scale = 1 })
end)

RunService.RenderStepped:Connect(function()
	local t = os.clock()
	fabBtn.Position = UDim2.fromOffset(0, math.sin(t * 2) * 4)
	fabGradient.Rotation = (t * 80) % 360
end)

-- Меню -------------------------------------------------------------------
local vp = (cam() and cam().ViewportSize) or Vector2.new(1280, 720)
local W = math.min(600, vp.X - 30)
local H = math.min(400, vp.Y - 30)

local menu = new("CanvasGroup", {
	Name = "Menu", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(W, H), BackgroundColor3 = THEME.bg, BorderSizePixel = 0,
	GroupTransparency = 1, Visible = false,
}, screen)
new("UICorner", { CornerRadius = UDim.new(0, 14) }, menu)
local menuScale = new("UIScale", { Scale = 0.92 }, menu)

local header = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = THEME.panel, BorderSizePixel = 0 }, menu)
local title = new("TextLabel", {
	BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 7), Size = UDim2.new(1, -80, 0, 24),
	Font = Enum.Font.GothamBold, TextSize = 19, TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.new(1, 1, 1), Text = CONFIG.MenuTitle,
}, header)
gradientText(title)
new("TextLabel", {
	BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 29), Size = UDim2.new(1, -80, 0, 16),
	Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = THEME.sub, Text = CONFIG.Title .. "  -  визуалы и мир",
}, header)

local closeBtn = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = THEME.row, Text = "X", Font = Enum.Font.GothamBold, TextSize = 14,
	TextColor3 = THEME.sub, AutoButtonColor = false,
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, closeBtn)
closeBtn.MouseEnter:Connect(function()
	tween(closeBtn, FAST, { BackgroundColor3 = THEME.danger, TextColor3 = Color3.new(1, 1, 1) })
end)
closeBtn.MouseLeave:Connect(function()
	tween(closeBtn, FAST, { BackgroundColor3 = THEME.row, TextColor3 = THEME.sub })
end)

local sidebar = new("Frame", {
	Position = UDim2.fromOffset(0, 52), Size = UDim2.new(0, 150, 1, -52), BackgroundColor3 = THEME.panel, BorderSizePixel = 0,
}, menu)
local tabList = new("ScrollingFrame", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -50), BorderSizePixel = 0, ScrollBarThickness = 0,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, sidebar)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabList)
new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, tabList)

local offAll = new("TextButton", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, -8), Size = UDim2.new(1, -16, 0, 34),
	BackgroundColor3 = THEME.row, Text = "Выключить всё", Font = Enum.Font.GothamMedium, TextSize = 13,
	TextColor3 = THEME.text, AutoButtonColor = false,
}, sidebar)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, offAll)
offAll.MouseEnter:Connect(function()
	tween(offAll, FAST, { BackgroundColor3 = THEME.danger })
end)
offAll.MouseLeave:Connect(function()
	tween(offAll, FAST, { BackgroundColor3 = THEME.row })
end)
offAll.MouseButton1Click:Connect(disableAll)

local content = new("Frame", {
	Position = UDim2.fromOffset(158, 60), Size = UDim2.new(1, -166, 1, -68), BackgroundTransparency = 1,
}, menu)

local pages, tabButtons, rowSync = {}, {}, {}
local currentTab = nil

local function showTab(name)
	currentTab = name
	for cat, page in pairs(pages) do
		page.Visible = (cat == name)
	end
	for cat, b in pairs(tabButtons) do
		local active = cat == name
		tween(b, FAST, {
			BackgroundColor3 = active and THEME.accent or THEME.panel,
			BackgroundTransparency = active and 0 or 1,
			TextColor3 = active and Color3.new(1, 1, 1) or THEME.sub,
		})
	end
end

local function buildRow(f, page, order)
	local row = new("Frame", {
		Name = f.id, Size = UDim2.new(1, 0, 0, 58), BackgroundColor3 = THEME.row, BorderSizePixel = 0, LayoutOrder = order,
	}, page)
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, row)
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 9), Size = UDim2.new(1, -90, 0, 18),
		Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.text, Text = f.name,
	}, row)
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -90, 0, 24),
		Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, TextColor3 = THEME.sub, Text = f.desc,
	}, row)

	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(46, 24),
		BackgroundColor3 = THEME.off, BorderSizePixel = 0,
	}, row)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, track)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

	local hit = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 3 }, row)
	hit.MouseEnter:Connect(function()
		tween(row, FAST, { BackgroundColor3 = THEME.rowHover })
	end)
	hit.MouseLeave:Connect(function()
		tween(row, FAST, { BackgroundColor3 = THEME.row })
	end)
	hit.MouseButton1Click:Connect(function()
		toggleFeature(f)
	end)

	rowSync[f.id] = function(on)
		tween(track, FAST, { BackgroundColor3 = on and THEME.accent or THEME.off })
		tween(knob, FAST, { Position = on and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
	end
end

for i, cat in ipairs(CATEGORIES) do
	local tabBtn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34), LayoutOrder = i, BackgroundColor3 = THEME.panel, BackgroundTransparency = 1,
		Text = "   " .. cat, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.sub, AutoButtonColor = false,
	}, tabList)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, tabBtn)
	tabBtn.MouseButton1Click:Connect(function()
		showTab(cat)
	end)
	tabButtons[cat] = tabBtn

	local page = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = THEME.accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
	}, content)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 4) }, page)
	pages[cat] = page

	local order = 0
	for _, f in ipairs(Features) do
		if f.cat == cat then
			order += 1
			buildRow(f, page, order)
		end
	end
end

local menuOpen = false
local function setMenu(open)
	menuOpen = open
	if open then
		menu.Visible = true
		tween(menuScale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		tween(menu, TweenInfo.new(0.22, Enum.EasingStyle.Quad), { GroupTransparency = 0 })
	else
		tween(menuScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.92 })
		tween(menu, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { GroupTransparency = 1 })
		task.delay(0.22, function()
			if not menuOpen then
				menu.Visible = false
			end
		end)
	end
end

closeBtn.MouseButton1Click:Connect(function()
	setMenu(false)
end)
makeDraggable(fabBtn, fab, function()
	setMenu(not menuOpen)
end)
makeDraggable(header, menu)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == CONFIG.ToggleKey then
		setMenu(not menuOpen)
	end
end)

showTab(CATEGORIES[1])

-- Окно AuraVisuals (FPS и список) ----------------------------------------
local hud = new("Frame", {
	Name = "HUD", Position = UDim2.fromOffset(16, 64), Size = UDim2.fromOffset(210, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = THEME.bg, BackgroundTransparency = 0.12, BorderSizePixel = 0, Visible = false,
}, screen)
new("UICorner", { CornerRadius = UDim.new(0, 12) }, hud)
new("UIStroke", { Color = THEME.accent, Transparency = 0.45, Thickness = 1.5 }, hud)
new("UIPadding", {
	PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
}, hud)
new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, hud)

local hudTitle = new("TextLabel", {
	LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
	TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.new(1, 1, 1), Text = CONFIG.Title,
}, hud)
gradientText(hudTitle)
makeDraggable(hudTitle, hud)

local fpsLabel = new("TextLabel", {
	LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
	TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = THEME.text, Text = "FPS  --",
}, hud)

local listFrame = new("Frame", {
	LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
}, hud)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)

local function refreshHud()
	hud.Visible = ById.hud_window.enabled
	fpsLabel.Visible = ById.hud_fps.enabled
	listFrame.Visible = ById.hud_list.enabled

	for _, c in ipairs(listFrame:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end

	local order = 0
	local function line(text, color, size)
		order += 1
		new("TextLabel", {
			LayoutOrder = order, Size = UDim2.new(1, 0, 0, size + 3), BackgroundTransparency = 1, Font = Enum.Font.Gotham,
			TextSize = size, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = color, Text = text,
		}, listFrame)
	end

	line("Активные визуалы", THEME.sub, 12)
	local any = false
	for _, f in ipairs(Features) do
		if f.enabled and f.cat ~= "Интерфейс" then
			any = true
			line(f.name, THEME.text, 13)
		end
	end
	if not any then
		line("Нет", THEME.sub, 13)
	end
end

Changed.Event:Connect(function(f)
	local sync = rowSync[f.id]
	if sync then
		sync(f.enabled)
	end
	refreshHud()
end)

do
	local frames, elapsed = 0, 0
	RunService.RenderStepped:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed >= 0.5 then
			local fps = math.floor(frames / elapsed + 0.5)
			frames, elapsed = 0, 0
			fpsLabel.Text = "FPS  " .. fps
			fpsLabel.TextColor3 = fps >= 50 and Color3.fromRGB(110, 230, 140)
				or (fps >= 30 and Color3.fromRGB(255, 210, 90) or Color3.fromRGB(255, 100, 110))
		end
	end)
end

------------------------------------------------------------------------
-- РЕСПАВН ПЕРСОНАЖА
------------------------------------------------------------------------
player.CharacterRemoving:Connect(function()
	for _, f in ipairs(Features) do
		if f.enabled and f.char and f.ctx then
			f.ctx.trash:clean()
			f.ctx = nil
		end
	end
end)

local function rebuildChar()
	local char = player.Character
	if not char then
		return
	end
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then
		return
	end
	local torsoName = hum.RigType == Enum.HumanoidRigType.R15 and "UpperTorso" or "Torso"
	char:WaitForChild(torsoName, 10)
	char:WaitForChild("HumanoidRootPart", 10)
	char:WaitForChild("Head", 10)
	task.wait(0.4)
	for _, f in ipairs(Features) do
		if f.enabled and f.char then
			if f.ctx then
				f.ctx.trash:clean()
				f.ctx = nil
			end
			startFeature(f)
		end
	end
end

player.CharacterAdded:Connect(function()
	task.spawn(rebuildChar)
end)

------------------------------------------------------------------------
-- СТАРТ
------------------------------------------------------------------------
enableFeature(ById.hud_window)
enableFeature(ById.hud_fps)
enableFeature(ById.hud_list)
refreshHud()
