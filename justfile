test:
	nvim --headless -u NONE -c "luafile tests/clipboard_spec.lua" +qa
