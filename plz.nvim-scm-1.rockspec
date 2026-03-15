rockspec_format = "3.0"
package = "plz.nvim"
version = "scm-1"

source = {
  url = "git://github.com/justinlazarus/plz.nvim",
}

dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "nlua",
  "busted",
}

build = {
  type = "builtin",
}
