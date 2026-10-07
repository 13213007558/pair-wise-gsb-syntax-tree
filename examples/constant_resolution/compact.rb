# frozen_string_literal: true

# With the compact definition style, the body of B has only A::B in its
# lexical scope (Module.nesting == [A::B]) -- A itself is NOT searched --
# so the very same VALUE reference resolves to the top-level ::VALUE.
class A::B
  def self.value
    VALUE
  end
end

