local bit32 = require("bit")

local interrupts = require("gameboy/interrupts")
local io = require("gameboy/io")
local memory = require("gameboy/memory")
local timers = require("gameboy/timers")

local graphics = {}

graphics.cache = require("cache")
graphics.palette = require("palette")
graphics.registers = require("registers")

--just for shortening access
local ports = io.ports

-- Internal Variables
graphics.vblank_count = 0
graphics.last_edge = 0

graphics.game_screen = {}

graphics.clear_screen = function()
  for y = 0, 143 do
    graphics.game_screen[y] = {}
    for x = 0, 159 do
      graphics.game_screen[y][x] = {255, 255, 255}
    end
  end
end

graphics.lcd = {}

-- Initialize VRAM blocks in main memory
graphics.vram = memory.generate_block(16 * 2 * 1024, 0x8000)
graphics.vram.bank = 0
graphics.vram_map = {}
graphics.vram_map.mt = {}
graphics.vram_map.mt.__index = function(table, address)
  return graphics.vram[address + (16 * 1024 * graphics.vram.bank)]
end
graphics.vram_map.mt.__newindex = function(table, address, value)
  graphics.vram[address + (16 * 1024 * graphics.vram.bank)] = value
  if address >= 0x8000 and address <= 0x97FF then
    -- Update the cached tile data
    local tile_index = math.floor((address - 0x8000) / 16) + (384 * graphics.vram.bank)
    local y = math.floor((address % 16) / 2)
    -- kill the lower bit
    address = bit32.band(address, 0xFFFE)
    local lower_bits = graphics.vram[address]
    local upper_bits = graphics.vram[address + 1]
    for x = 0, 7 do
      local palette_index = bit32.band(bit32.rshift(lower_bits, 7 - x), 0x1) + (bit32.band(bit32.rshift(upper_bits, 7 - x), 0x1) * 2)
      graphics.cache.tiles[tile_index][x][y] = palette_index
    end
  end
  if address >= 0x9800 and address <= 0x9BFF then
    local x = address % 32
    local y = math.floor((address - 0x9800) / 32)
    if graphics.vram.bank == 0 then
      graphics.cache.map_0[x][y] = value
    else
      graphics.cache.map_0_attr[x][y].palette = bit32.band(value, 0x07)
      graphics.cache.map_0_attr[x][y].bank = bit32.rshift(bit32.band(value, 0x08), 3)
      graphics.cache.map_0_attr[x][y].horizontal_flip = bit32.rshift(bit32.band(value, 0x20), 5)
      graphics.cache.map_0_attr[x][y].vertical_flip = bit32.rshift(bit32.band(value, 0x40), 6)
      graphics.cache.map_0_attr[x][y].priority = bit32.rshift(bit32.band(value, 0x80), 7)
    end
  end
  if address >= 0x9C00 and address <= 0x9FFF then
    local x = address % 32
    local y = math.floor((address - 0x9C00) / 32)
    if graphics.vram.bank == 0 then
      graphics.cache.map_1[x][y] = value
    else
      graphics.cache.map_1_attr[x][y].palette = bit32.band(value, 0x07)
      graphics.cache.map_1_attr[x][y].bank = bit32.rshift(bit32.band(value, 0x08), 3)
      graphics.cache.map_1_attr[x][y].horizontal_flip = bit32.rshift(bit32.band(value, 0x20), 5)
      graphics.cache.map_1_attr[x][y].vertical_flip = bit32.rshift(bit32.band(value, 0x40), 6)
      graphics.cache.map_1_attr[x][y].priority = bit32.rshift(bit32.band(value, 0x80), 7)
    end
  end
end
setmetatable(graphics.vram_map, graphics.vram_map.mt)
memory.map_block(0x80, 0x9F, graphics.vram_map, 0)

graphics.oam = memory.generate_block(0xA0, 0xFE00)
graphics.oam.mt = {}
graphics.oam.mt.__index = function(table, address)
  -- out of range? So sorry, return nothing
  return 0x00
end
graphics.oam.mt.__newindex = function(table, address, byte)
  -- out of range? So sorry, discard the write
  return
end
setmetatable(graphics.oam, graphics.oam.mt)
memory.map_block(0xFE, 0xFE, graphics.oam, 0)

io.write_logic[0x4F] = function(byte)
  if graphics.gameboy.type == graphics.gameboy.types.color then
    io.ram[0x4F] = bit32.band(0x1, byte)
    graphics.vram.bank = bit32.band(0x1, byte)
  else
    -- Not sure if the write mask should apply in DMG / SGB mode
    io.ram[0x4F] = byte
  end
end

graphics.initialize = function(gameboy)
  graphics.gameboy = gameboy
  graphics.registers.Status.SetMode(2)
  graphics.clear_screen()
  graphics.reset()
end

graphics.reset = function()
  -- zero out all of VRAM:
  for i = 0x8000, 0x9FFF do
    graphics.vram[i] = 0
  end

  -- zero out all of OAM
  for i = 0xFE00, 0xFE9F do
    graphics.oam[i] = 0
  end

  graphics.vblank_count = 0
  graphics.last_edge = 0
  graphics.vram.bank = 0

  graphics.clear_screen()
  graphics.registers.Status.SetMode(2)

  graphics.cache.reset()
end

graphics.save_state = function()
  local state = {}

  state.vram = {}
  for i = 0x8000, 0x9FFF do
    state.vram[i] = graphics.vram[i]
  end

  state.oam = {}
  for i = 0xFE00, 0xFE9F do
    state.oam[i] = graphics.oam[i]
  end

  state.vblank_count = graphics.vblank_count
  state.last_edge = graphics.last_edge

  state.palette = {}
  state.palette.bg   = graphics.palette.bg
  state.palette.obj0 = graphics.palette.obj0
  state.palette.obj1 = graphics.palette.obj1

  return state
end

graphics.load_state = function(state)
  for i = 0x8000, 0x9FFF do
    graphics.vram[i] = state.vram[i]
  end
  for i = 0xFE00, 0xFE9F do
    graphics.oam[i] = state.oam[i]
  end
  graphics.vblank_count = state.vblank_count
  graphics.last_edge = state.last_edge

  graphics.cache.reset()
  graphics.cache.refreshAll()

  graphics.palette.bg   = state.palette.bg
  graphics.palette.obj0 = state.palette.obj0
  graphics.palette.obj1 = state.palette.obj1
end

local time_at_this_mode = function()
  return timers.system_clock - graphics.last_edge
end

-- HBlank: Period between scanlines
local handle_mode = {}
handle_mode[0] = function()
  if timers.system_clock - graphics.last_edge > 204 then
    graphics.last_edge = graphics.last_edge + 204
    io.ram[ports.LY] = io.ram[ports.LY] + 1
    -- If enabled, fire an HBlank interrupt
    if bit32.band(io.ram[ports.STAT], 0x08) ~= 0 then
      request_interrupt(interrupts.LCDStat)
    end
    if io.ram[ports.LY] == io.ram[ports.LYC] then
      -- set the LY compare bit
      io.ram[ports.STAT] = bit32.bor(io.ram[ports.STAT], 0x4)
      if bit32.band(io.ram[ports.STAT], 0x40) ~= 0 then
        request_interrupt(interrupts.LCDStat)
      end
    else
      -- clear the LY compare bit
      io.ram[ports.STAT] = bit32.band(io.ram[ports.STAT], 0xFB)
    end
    if io.ram[ports.LY] >= 144 then
      graphics.registers.Status.SetMode(1)
      graphics.vblank_count = graphics.vblank_count + 1
      request_interrupt(interrupts.VBlank)
      if bit32.band(io.ram[ports.STAT], 0x10) ~= 0 then
        -- This is weird; LCDStat mirrors VBlank?
        request_interrupt(interrupts.LCDStat)
      end
      -- TODO: Draw the real screen here?
    else
      graphics.registers.Status.SetMode(2)
      if bit32.band(io.ram[ports.STAT], 0x20) ~= 0 then
        request_interrupt(interrupts.LCDStat)
      end
    end
  end
end

--VBlank: nothing to do except wait for the next frame
handle_mode[1] = function()
  if timers.system_clock - graphics.last_edge > 456 then
    graphics.last_edge = graphics.last_edge + 456
    io.ram[ports.LY] = io.ram[ports.LY] + 1
  end
  if io.ram[ports.LY] >= 154 then
    io.ram[ports.LY] = 0
    graphics.registers.Status.SetMode(2)
    if bit32.band(io.ram[ports.STAT], 0x20) ~= 0 then
      request_interrupt(interrupts.LCDStat)
    end
  end
  if io.ram[ports.LY] == io.ram[ports.LYC] then
    -- set the LY compare bit
    io.ram[ports.STAT] = bit32.bor(io.ram[ports.STAT], 0x4)
    if bit32.band(io.ram[ports.STAT], 0x40) ~= 0 then
      request_interrupt(interrupts.LCDStat)
    end
  else
    -- clear the LY compare bit
    io.ram[ports.STAT] = bit32.band(io.ram[ports.STAT], 0xFB)
  end
end

-- OAM Read: OAM cannot be accessed
handle_mode[2] = function()
  if timers.system_clock - graphics.last_edge > 80 then
    graphics.last_edge = graphics.last_edge + 80
    graphics.registers.Status.SetMode(3)
  end
end
-- VRAM Read: Neither VRAM, OAM, nor CGB palettes can be read
handle_mode[3] = function()
  if timers.system_clock - graphics.last_edge > 172 then
    graphics.last_edge = graphics.last_edge + 172
    graphics.registers.Status.SetMode(0)
    if graphics.registers.LCD_Control.DisplayEnabled() then
      graphics.draw_scanline(io.ram[ports.LY])
    end
  end
end

graphics.update = function()
  if graphics.registers.LCD_Control.DisplayEnabled() then
    handle_mode[graphics.registers.Status.Mode()]()
  else
    -- erase our clock debt, so we don't do stupid timing things when the
    -- display is enabled again later
    graphics.last_edge = timers.system_clock
    graphics.registers.Status.SetMode(0)
    io.ram[ports.LY] = 0
  end
end

local function plot_pixel(buffer, x, y, r, g, b)
  buffer[y][x][1] = r
  buffer[y][x][2] = g
  buffer[y][x][3] = b
end

local function debug_draw_screen()
  for i = 0, 143 do
    graphics.draw_scanline(i)
  end
end

graphics.getColorFromIndex = function(index, palette)
  palette = palette or 0xE4
  while index > 0 do
    palette = bit32.rshift(palette, 2)
    index = index - 1
  end
  return screen_colors[bit32.band(palette, 0x3)]
end

graphics.getIndexFromTilemap = function(map, tile_data, x, y)
  local tile_x = bit32.rshift(x, 3)
  local tile_y = bit32.rshift(y, 3)
  local tile_index = map[tile_x][tile_y]
  if tile_data == 0x9000 then
    if tile_index > 127 then
      tile_index = tile_index - 256
    end
    -- add offset to re-root at tile 256 (so effectively, we read from tile 192 - 384)
    tile_index = tile_index + 256
  end

  local subpixel_x = x - (tile_x * 8)
  local subpixel_y = y - (tile_y * 8)

  return graphics.cache.tiles[tile_index][subpixel_x][subpixel_y]
end

local function draw_sprites_into_scanline(scanline, bg_index)
  if not graphics.registers.LCD_Control.SpritesEnabled() then
    return
  end
  local active_sprites = {}
  local sprite_size = 8
  if graphics.registers.LCD_Control.LargeSprites() then
    sprite_size = 16
  end

  -- Collect up to the 10 highest priority sprites in a list.
  -- Sprites have priority first by their X coordinate, then by their index
  -- in the list.
  local i = 0
  while i < 40 do
    -- is this sprite being displayed on this scanline? (respect to Y coordinate)
    local sprite_y = graphics.oam[0xFE00 + i * 4]
    local sprite_lower = sprite_y - 16
    local sprite_upper = sprite_y - 16 + sprite_size
    if scanline >= sprite_lower and scanline < sprite_upper then
      if #active_sprites < 10 then
        table.insert(active_sprites, i)
      else
        -- There are more than 10 sprites in the table, so we need to pick
        -- a candidate to vote off the island (possibly this one)
        local lowest_priority = i
        local lowest_priotity_index = nil
        for j = 1, #active_sprites do
          local lowest_x = graphics.oam[0xFE00 + lowest_priority * 4 + 1]
          local candidate_x = graphics.oam[0xFE00 + active_sprites[j] * 4 + 1]
          if candidate_x > lowest_x then
            lowest_priority = active_sprites[j]
            lowest_priority_index = j
          end
        end
        if lowest_priority_index then
          active_sprites[lowest_priority_index] = i
        end
      end
    end
    i = i + 1
  end

  -- now, for every sprite in the list, display it on the current scanline
  for i = #active_sprites, 1, -1 do
    local sprite_address = 0xFE00 + active_sprites[i] * 4
    local sprite_y = graphics.oam[sprite_address]
    local sprite_x = graphics.oam[sprite_address + 1]
    local sprite_tile = graphics.oam[sprite_address + 2]
    if sprite_size == 16 then
      sprite_tile = bit32.band(sprite_tile, 0xFE)
    end
    local sprite_flags = graphics.oam[sprite_address + 3]

    local y_flipped = bit32.band(0x40, sprite_flags) ~= 0
    local x_flipped = bit32.band(0x20, sprite_flags) ~= 0

    local sub_y = 16 - (sprite_y - scanline)
    if y_flipped then
      sub_y = sprite_size - 1 - sub_y
    end

    local sprite_bg_priority = (bit32.band(0x80, sprite_flags) == 0)

    local sprite_palette = graphics.palette.obj0
    if bit32.band(sprite_flags, 0x10) ~= 0 then
      sprite_palette = graphics.palette.obj1
    end

    if sub_y >= 8 then
      sprite_tile = sprite_tile + 1
      sub_y = sub_y - 8
    end

    local tile = graphics.cache.tiles[sprite_tile]

    for x = 0, 7 do
      local display_x = sprite_x - 8 + x
      if display_x >= 0 and display_x < 160 then
        local sub_x = x
        if x_flipped then
          sub_x = 7 - x
        end
        local subpixel_index = tile[sub_x][sub_y]
        if subpixel_index > 0 then
          if sprite_bg_priority or bg_index[display_x] == 0 then
            local subpixel_color = sprite_palette[subpixel_index]
            plot_pixel(graphics.game_screen, display_x, scanline, unpack(subpixel_color))
          end
        end
      end
    end
  end
  if #active_sprites > 0 then
  end
end

graphics.draw_scanline = function(scanline)
  if scanline < 0 or scanline > 143 then
    print("Bad scanline: ", scanline)
    return
  end
  local bg_y = scanline + io.ram[ports.SCY]
  local bg_x = io.ram[ports.SCX]
  -- wrap the map in the Y direction
  if bg_y >= 256 then
    bg_y = bg_y - 256
  end

  local scanline_bg_index = {}

  -- Grab this stuff just once, rather than every iteration
  -- through the loop
  local tile_data = graphics.registers.LCD_Control.TileData()
  local window_tilemap_address = graphics.registers.LCD_Control.WindowTilemap()
  local background_tilemap_address = graphics.registers.LCD_Control.BackgroundTilemap()
  local window_enabled = graphics.registers.LCD_Control.WindowEnabled()
  local background_enabled = graphics.registers.LCD_Control.BackgroundEnabled()

  local window_tilemap = graphics.cache.map_0
  if window_tilemap_address == 0x9C00 then
    window_tilemap = graphics.cache.map_1
  end

  local background_tilemap = graphics.cache.map_0
  if background_tilemap_address == 0x9C00 then
    background_tilemap = graphics.cache.map_1
  end

  local w_x = io.ram[ports.WX] - 7
  local w_y = io.ram[ports.WY]

  for x = 0, 159 do
    scanline_bg_index[x] = 0
    if window_enabled and w_x <= x and w_y <= scanline then
      -- The Window is visible here, so draw that
      local window_index = graphics.getIndexFromTilemap(window_tilemap, tile_data, x - w_x, scanline - w_y)
      scanline_bg_index[x] = window_index
      plot_pixel(graphics.game_screen, x, scanline, unpack(graphics.palette.bg[window_index]))
    else
      -- The background is visible
      if background_enabled then
        local bg_index = graphics.getIndexFromTilemap(background_tilemap, tile_data, bg_x, bg_y)
        scanline_bg_index[x] = bg_index
        plot_pixel(graphics.game_screen, x, scanline, unpack(graphics.palette.bg[bg_index]))
      end
    end
    bg_x = bg_x + 1
    if bg_x >= 256 then
      bg_x = bg_x - 256
    end
  end

  draw_sprites_into_scanline(scanline, scanline_bg_index)
end

return graphics