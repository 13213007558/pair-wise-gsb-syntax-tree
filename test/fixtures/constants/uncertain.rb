autoload :Loaded, "loaded"

if feature
  require "conditional"
  Conditional
end

Foo.const_set(:Dynamic, 1)
Dynamic

def const_missing(name)
end

Missing
