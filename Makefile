.PHONY: test

test:
	eval "$$(luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version 5.1 path --local)" && busted
