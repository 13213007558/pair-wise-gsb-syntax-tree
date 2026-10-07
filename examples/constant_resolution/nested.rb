# frozen_string_literal: true

# With the nested definition style, the body of B has both A::B and A
# in its lexical scope (Module.nesting == [A::B, A]), so VALUE resolves
# to A::VALUE.
class A
  class B
    def self.value
      VALUE
    end
  end
end

