--[[

context.lua
Tools for generating contexts from user input.
Spritesheets are applied to a context to generate a new image according to rules in the context.

]]

-- currently only for static sprites
magick = require("magick")

--==============================================================================
	--							String parsers
--==============================================================================

local function parseFloat(input)
	return assert(tonumber(input), "Expected number")
end

local function parseInt(input)
	return math.floor(assert(tonumber(input), "Expected number"))
end

local function parsePercentage(input)
	if input:sub(-1) == "%" then input = input:sub(1, -2) end
	return assert(tonumber(input), "Expected number") / 100
end

local parseColor
do
	local colors = {
		none = "#000000", -- transparent
		black = "#000",
		white = "#fff",
		blue = "#1e90ff", -- magick dodgerblue
		red = "#ff0000", -- legends red
		purple = "#cc66ff", -- supporter purple
		
		-- utreborn colors
		sc = "#6AFFFB", -- sacred
		lg = "#DDDD00", -- legendary
		gs = "#D80D38", -- godslayer
		gl = "#E01DBF", -- godly
		
		off = false,
	}
	
	-- TODO: also return alpha if it's there
	parseColor = function(input)
		input = input:lower()
		if colors[input] ~= nil then return colors[input] end
		
		-- #123def
		local color = input:match("^#?([%da-f]+)$")
		if color then
			assert(#color == 3 or #color == 6 or #color == 8, "Not a valid color")
			return "#" .. color
		end
		
		local color = input:match("^%d+,%d+,%d+$") -- the numbers can be anything from 0 to 99999999.....
		if color then
			return ("rgb(%s)"):format(color)
		end
		
		error("Not a valid color")
	end
end

local parseBool
do
	local bool = {
		on = true,
		yes = true,
		["true"] = true,
		
		off = false,
		no = false,
		["false"] = false,
	}
	
	parseBool = function(input)
		local bool = bool[input:lower()]
		assert(bool ~= nil, "Expected on/off")
		return bool
	end
end

local function parseGeometry(input)
	-- WxH+X+Y = X, Y, W, H
	-- +X+Y = X, Y, nil, nil
	-- W = nil, nil, W, nil
	-- xH = nil, nil, nil, H
	assert(not input:match("[^%dx+]"), "Invalid geometry")
	local w, h, x, y = (input):match("(%d*)x?(%d*)+?(%d*)+?(%d*)")
	return tonumber(x), tonumber(y), tonumber(w), tonumber(h) -- returns nil on nonexistent fields
end

--==============================================================================
--								Context modifiers
--==============================================================================

local adjectives = {
	size = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = parsePercentage(input()) * 5 -- 100% -> 5
		assert(input >= 1, "Expected percentage no smaller than 20%")
		assert(input <= 10, "Expected percentage no larger than 200%")
		ctx.scale = input
	end,
	
	scale = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = parseFloat(input())
		assert(input >= 1, "Expected number no smaller than 1") -- remove these
		assert(input <= 10, "Expected number no larger than 10")
		ctx.scale = input
	end,
	
	tile = function(ctx, input)
		x, y, w, h = parseGeometry(assert(input()))
		assert(w, "Please specify a tiling square or rectangle size")
		h = h or w
		assert(w >= 0 and h >= 0, "Tiling dimensions must be no less than one pixel")
		ctx.wtile = w
		ctx.htile = h
	end,
	
	glow = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = assert(input())
		input = parseColor(input)
		ctx.cglow = input
	end,
	
	bg = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = assert(input())
		input = parseColor(input)
		ctx.cbackground = input
	end,
	
	outline = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = assert(input())
		input = parseColor(input)
		ctx.coutline = input
	end,
	
	matte = function(ctx, input)
		input = assert(input, "Incomplete options")
		input = assert(input())
		input = parseColor(input)
		ctx.cmatte = input
	end,
	
	anim = function(ctx, input)
		local token = assert(input())
		if token == "off" then
			ctx.anim = false
		elseif token == "player" then
			error("Player anim not implemented")
		elseif token == "char" then
			error("Char anim not implemented")
		else
			ctx.anim = "tile"
			x, y, w, h = parseGeometry(token) -- x,y unwisely used as anim delay
			assert(w or h, "Please specify a size")
			w, h = w and math.floor(w), h and math.floor(h)
			assert((w and w > 0 or true) and (w and w > 0 or true), "Needs anim dimensions")
			ctx.cbackground = ctx.cbackground or "#7f7f7f"
			ctx.wanim = w or false -- scary, I might be allowing nils into the ctx elsewhere. todo:
			ctx.hanim = h or false
			ctx.tanim = x or false
			ctx.tpsanim = y or false
		end
	end,
	
	-- gradient = function(ctx, input)
		-- input = assert(input, "Incomplete options")
		-- input = assert(input())
		-- input = parseColor(input)
		-- ctx.cgradient = input
	-- end,
	
	-- gradmode = function(ctx, input)
		-- input = assert(input, "Incomplete options")
		-- input = assert(input())
		-- input = ({add = true, sub = false, subtract = false})[input:lower()]
		-- assert(input ~= nil)
		-- ctx.mgradient = input
	-- end,
	
	copy = function(ctx, input)
		input = assert(input, "Incomplete options")
		ctx.sappend = parseBool(assert(input()))
		-- todo: specify cardinal direction or auto or off
	end,
}

--==============================================================================
--								Functions
--==============================================================================

function parseAttributes(ctx, nextToken)
	-- ctx: context key-value table
	-- nextToken: function which returns a string
	-- this function will throw errors, which are handled and expressed a step above
	for attribute in nextToken do
		attribute = adjectives[attribute:lower()]
		if attribute then
			attribute(ctx, nextToken)
		else
			error("Unrecognized option")
		end
		-- todo: . in the beginning of a modifier name optional
	end
	
	return ctx
end

function padding(ctx, border, wsheet, hsheet)
	-- if border == 0 then return end -- already handled in magick.lua
	local gap = border + border
	
	local wtile = ctx.wtile -- 8
	local htile = ctx.htile -- 8
	
	local args = {"-background", "#00000000"} -- "none"
	
	if wsheet > wtile or hsheet > htile then
		
		local wstile = wtile * ctx.scale -- 40
		local hstile = htile * ctx.scale -- 40
		
		local nx = math.ceil(wsheet / wtile) -- - 1
		local ny = math.ceil(hsheet / htile) -- - 1
		local format = ("%sx%s+%%s+%%s"):format(gap, gap) -- "16x16+%s+%s"
		local x, y = wstile, hstile
		wstile, hstile = wstile + gap, hstile + gap
		for i = #args + 1, math.min(nx, ny) * 2, 2 do -- + 2, 2 do
			args[i] = "-splice"
			args[i+1] = format:format(x, y)
			x = x + wstile
			y = y + hstile
		end
		
		if nx ~= ny then
				
			if ny > nx then
				format = ("0x%s+0+%%s"):format(gap) -- "0x16+0+%s"
				x = y
				nx = ny
				wstile = hstile
			else
				format = ("%sx0+%%s+0"):format(gap) -- "16x0+%s+0"
			end
			
			for i = #args + 1, nx * 2, 2 do -- + 2, 2 do
				args[i] = "-splice"
				args[i+1] = format:format(x)
				x = x + wstile
			end
		end
		
	end
	
	-- padding around the sprites
	util.append(args, {
		"-bordercolor", "#00000000",
		"-border", tostring(border),
	})
	
	return args
end

--==============================================================================
--						Default context generators
--==============================================================================

function static()
	return {
		-- rborder = 8 -- optional
		
		scale = 5, -- sprite scaling factor. may not be lower than 1
		zoom = 1, -- zoom factor, same as scale except applied at the end. stub.
		wtile = 8, -- sprite width
		htile = 8, -- and height on the spritesheet in pixels
		anim = false, -- type of animation
		wanim = false, -- width of anim in tiles
		hanim = false, -- height of anim in tiles
		tanim = false, -- ticks each animation frame takes
		tpsanim = false, -- anim ticks per second
		rglow = 8, -- radius of glow. may be odd. stub.
		coutline = "#000000", -- outline color and alpha, disabled if false. alpha is usually 0xcc (204)
		cglow = "#000000", -- glow color, disabled if false
		cmatte = false, -- matte color, replaced with transparency, disabled if false
		cgradient = "#202020", -- gradient color, disabled if false. stub.
		mgradient = false, -- gradient blend mode. false is subtract, true is add. stub.
		cbackground = false, -- background color. disabled if false
		
		autocrop = true, -- whether to autocrop the image before processing it. stub.
		-- crop only in increments of wtile/htile from the left and right!
		sappend = false, -- whether to append the original spritesheet
		
		-- function that modifies this context based on user arguments
		parse = parseAttributes,
		
		-- function that generates the -splice section
		padding = padding,
		
		-- function that processes an image according to this context
		process = magick,
	}
end

return {
	static = static,
	-- animation = animation,
	-- projectile = projectile,
	-- grenade = grenade,
	-- map = map,
}
