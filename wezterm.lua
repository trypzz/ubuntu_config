local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Colors
config.color_scheme = 'Catppuccin Mocha'

-- Font
config.font = wezterm.font('JetBrains Mono')
config.font_size = 13.0

-- Window
config.window_padding = { left = 10, right = 10, top = 10, bottom = 10 }
config.window_decorations = 'RESIZE'
config.window_background_opacity = 1.0
config.scrollback_lines = 20000

-- Tab bar
config.enable_tab_bar = true
config.tab_bar_at_bottom = true
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.tab_max_width = 40

-- Cursor
config.cursor_blink_rate = 500
config.default_cursor_style = 'BlinkingBar'

-- Kitty graphics / Sixel
config.enable_kitty_graphics = true

-- Закрити вікно без підтвердження якщо один таб
config.window_close_confirmation = 'NeverPrompt'

return config
